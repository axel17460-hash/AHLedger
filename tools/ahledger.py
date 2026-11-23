#!/usr/bin/env python3
"""AHLedger - import des SavedVariables dans SQLite + rapport de rentabilité.

Usage :
  python ahledger.py import "<WoW>/_forever_/WTF/Account/<COMPTE>/SavedVariables/AHLedger.lua"
  python ahledger.py report [--realm "Royaume-Horde"] [--days 7]
  python ahledger.py brief  "<...>/SavedVariables/AHLedger.lua" [--out rapport.md]
      (rapport pour Claude, enregistré par l'addon après chaque scan et à la déconnexion)
  python ahledger.py sync [--sv <AHLedger.lua>] [--to <dossier Google Drive>] [--once]
      (surveille les SavedVariables et copie le rapport dans Google Drive à chaque /reload ou déconnexion ;
       sans options, trouve tout seul le fichier de l'addon et le dossier « Mon Drive »)

Rien ici ne touche au jeu : le script lit uniquement le fichier écrit par le client
au /reload ou à la déconnexion (comme le font TSM ou les gestionnaires d'addons).
"""
import argparse
import glob
import os
import re
import sqlite3
import statistics
import sys
import time
# Console Windows (cp1252) : on force l'UTF-8 pour les accents et les flèches
for _s in (sys.stdout, sys.stderr):
    if hasattr(_s, "reconfigure"):
        _s.reconfigure(encoding="utf-8", errors="replace")
from datetime import datetime
from pathlib import Path

DB_PATH = Path(__file__).with_name("ahledger.sqlite")
AH_CUT = 0.05  # commission de l'HV (5 % en Classic, à vérifier sur Forever)


# --------------------------------------------------------------------------
# Mini-parseur Lua (le sous-ensemble utilisé par les SavedVariables)
# --------------------------------------------------------------------------
class LuaParser:
    TOKEN = re.compile(r"""
        \s+|--\[\[.*?\]\]|--[^\n]*        # espaces et commentaires
      | (?P<str>"(?:\\.|[^"\\])*")
      | (?P<num>-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)
      | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
      | (?P<sym>[{}\[\]=,;])
    """, re.S | re.X)

    def __init__(self, text):
        self.tokens = []
        for m in self.TOKEN.finditer(text):
            kind = m.lastgroup
            if kind:
                self.tokens.append((kind, m.group(kind)))
        self.i = 0

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else (None, None)

    def next(self):
        tok = self.peek()
        self.i += 1
        return tok

    def expect(self, value):
        kind, val = self.next()
        if val != value:
            raise ValueError(f"attendu {value!r}, trouvé {val!r} (token {self.i})")

    def parse_file(self):
        result = {}
        while self.peek()[0] is not None:
            _, name = self.next()
            self.expect("=")
            result[name] = self.value()
        return result

    def value(self):
        kind, val = self.next()
        if kind == "str":
            return bytes(val[1:-1], "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")
        if kind == "num":
            return float(val) if any(c in val for c in ".eE") else int(val)
        if kind == "name":
            return {"true": True, "false": False, "nil": None}[val]
        if val == "{":
            return self.table()
        raise ValueError(f"valeur inattendue {val!r}")

    def table(self):
        out, n = {}, 1
        while True:
            kind, val = self.peek()
            if val == "}":
                self.next()
                break
            if val == "[":
                self.next()
                key = self.value()
                self.expect("]")
                self.expect("=")
                out[key] = self.value()
            elif kind == "name" and self.tokens[self.i + 1][1] == "=":
                self.next()
                self.next()
                out[val] = self.value()
            else:
                out[n] = self.value()
                n += 1
            if self.peek()[1] in (",", ";"):
                self.next()
        return out


def as_list(t):
    """Tables Lua indexées 1..n -> liste Python."""
    if not t:
        return []
    return [t[k] for k in sorted(k for k in t if isinstance(k, int))]


# --------------------------------------------------------------------------
# SQLite
# --------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT, vendor_sell INTEGER, quality INTEGER);
CREATE TABLE IF NOT EXISTS scans (
  realm TEXT, t INTEGER, dur INTEGER, total INTEGER, missing INTEGER, gap INTEGER,
  PRIMARY KEY (realm, t));
CREATE TABLE IF NOT EXISTS item_scans (
  realm TEXT, t INTEGER, item INTEGER,
  n INTEGER, qty INTEGER, min INTEGER, p25 INTEGER, med INTEGER,
  sold INTEGER, expired INTEGER, ambiguous INTEGER, posted INTEGER, sold_value INTEGER,
  p75 INTEGER, sellers INTEGER, top_share INTEGER,
  PRIMARY KEY (realm, t, item));
CREATE TABLE IF NOT EXISTS vendor (
  realm TEXT, item INTEGER, price INTEGER, lim INTEGER, npc TEXT, zone TEXT, t INTEGER,
  PRIMARY KEY (realm, item));
CREATE TABLE IF NOT EXISTS farm_sessions (
  realm TEXT, start INTEGER, stop INTEGER, zone TEXT, level INTEGER, class TEXT, money INTEGER,
  PRIMARY KEY (realm, start));
CREATE TABLE IF NOT EXISTS farm_loot (
  realm TEXT, start INTEGER, item INTEGER, qty INTEGER,
  PRIMARY KEY (realm, start, item));
"""


def connect():
    con = sqlite3.connect(DB_PATH)
    con.executescript(SCHEMA)
    return con


def cmd_import(path):
    text = Path(path).read_text(encoding="utf-8")
    data = LuaParser(text).parse_file().get("AHLedgerDB") or {}
    con = connect()
    cur = con.cursor()

    for item_id, meta in (data.get("items") or {}).items():
        cur.execute("""INSERT INTO items VALUES (?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=coalesce(excluded.name,name),
              vendor_sell=coalesce(excluded.vendor_sell,vendor_sell), quality=coalesce(excluded.quality,quality)""",
                    (item_id, meta.get("n"), meta.get("s"), meta.get("q")))

    new_scans = 0
    for realm, r in (data.get("realms") or {}).items():
        for s in as_list(r.get("scans")):
            exists = cur.execute("SELECT 1 FROM scans WHERE realm=? AND t=?", (realm, s["t"])).fetchone()
            if exists:
                continue
            new_scans += 1
            cur.execute("INSERT INTO scans VALUES (?,?,?,?,?,?)",
                        (realm, s["t"], s.get("dur"), s.get("total"), s.get("missing"), s.get("gap")))
            rows = []
            items = s.get("items") or {}
            if isinstance(items, str):  # v2 : "id=champs;id=champs"
                items = dict(part.split("=", 1) for part in items.split(";") if part)
            for item_id, packed in items.items():
                vals = [int(v) for v in packed.split(",")]
                vals += [None] * (13 - len(vals))  # anciens formats : champs manquants
                rows.append((realm, s["t"], int(item_id), *vals[:13]))
            cur.executemany("INSERT INTO item_scans VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)

        for item_id, v in (r.get("vendor") or {}).items():
            cur.execute("INSERT OR REPLACE INTO vendor VALUES (?,?,?,?,?,?,?)",
                        (realm, item_id, v["p"], v.get("lim", -1), v.get("npc"), v.get("zone"), v.get("t")))

        for f in as_list(r.get("farm")):
            cur.execute("INSERT OR IGNORE INTO farm_sessions VALUES (?,?,?,?,?,?,?)",
                        (realm, f["start"], f["stop"], f.get("zone"), f.get("level"), f.get("class"), f.get("money", 0)))
            for item_id, qty in (f.get("loot") or {}).items():
                cur.execute("INSERT OR IGNORE INTO farm_loot VALUES (?,?,?,?)", (realm, f["start"], item_id, qty))

    con.commit()
    print(f"Import OK : {new_scans} nouveaux scans.")
    print("Tu peux faire /ahl prune 0 en jeu pour alléger le fichier (le dernier scan reste comparable).")


# --------------------------------------------------------------------------
# Rapport
# --------------------------------------------------------------------------
def gold(copper):
    if copper is None:
        return "-"
    g, rest = divmod(int(copper), 10000)
    s, c = divmod(rest, 100)
    return f"{g}g{s:02d}s{c:02d}c" if g else f"{s}s{c:02d}c"


def market_stats(con, realm, since):
    """Par objet : prix typique et volume vendu estimé par jour."""
    covered = con.execute("SELECT coalesce(sum(gap),0) FROM scans WHERE realm=? AND t>=? AND gap IS NOT NULL",
                          (realm, since)).fetchone()[0]
    stats = {}
    q = con.execute("""SELECT s.item, s.med, s.qty, s.sold, s.ambiguous, sc.gap
                       FROM item_scans s JOIN scans sc USING (realm, t)
                       WHERE s.realm=? AND s.t>=?""", (realm, since))
    for item, med, qty, sold, amb, gap in q:
        st = stats.setdefault(item, {"meds": [], "qtys": [], "sold": 0, "amb": 0})
        if med:
            st["meds"].append(med)
            st["qtys"].append(qty)
        if gap:
            st["sold"] += sold
            st["amb"] += amb
    hours = covered / 3600
    out = {}
    for item, st in stats.items():
        if not st["meds"]:
            continue
        # volume par jour : unités vendues pendant les intervalles observés, ramenées à 24 h.
        # Les cas ambigus comptent pour moitié (hypothèse à calibrer).
        per_day = (st["sold"] + 0.5 * st["amb"]) / hours * 24 if hours > 0 else None
        out[item] = {
            "price": statistics.median(st["meds"]),
            "listed": statistics.median(st["qtys"]),
            "per_day": per_day,
        }
    return out, hours


def cmd_report(realm, days, top):
    con = connect()
    realms = [r[0] for r in con.execute("SELECT DISTINCT realm FROM scans")]
    if not realms:
        sys.exit("Aucune donnée. Lance d'abord : ahledger.py import <fichier>")
    realm = realm or realms[0]
    last = con.execute("SELECT max(t) FROM scans WHERE realm=?", (realm,)).fetchone()[0]
    since = last - days * 86400
    names = dict(con.execute("SELECT id, coalesce(name, '#'||id) FROM items"))
    stats, hours = market_stats(con, realm, since)

    print(f"\n=== {realm} — {days} derniers jours, {hours:.1f} h de marché observées ===")

    print(f"\n-- Marchés les plus liquides (or échangé par jour, estimation) --")
    ranked = sorted(((st["price"] * st["per_day"], i, st) for i, st in stats.items() if st["per_day"]),
                    reverse=True)[:top]
    for value, item, st in ranked:
        print(f"{names.get(item, item):35} {gold(st['price']):>14}  ~{st['per_day']:7.1f}/j  "
              f"stock {st['listed']:>6.0f}  ⇒ {gold(value)}/j")

    print(f"\n-- Achat vendeur PNJ → revente HV --")
    rows = []
    for item, price, lim, npc, zone in con.execute(
            "SELECT item, price, lim, npc, zone FROM vendor WHERE realm=?", (realm,)):
        st = stats.get(item)
        if not st:
            continue
        margin = st["price"] * (1 - AH_CUT) - price
        if margin <= 0:
            continue
        daily = margin * min(st["per_day"] or 0, lim if lim and lim > 0 else 10**9)
        rows.append((daily, margin, item, price, st, npc, zone))
    for daily, margin, item, price, st, npc, zone in sorted(rows, reverse=True)[:top]:
        print(f"{names.get(item, item):35} achat {gold(price):>10}  HV {gold(st['price']):>10}  "
              f"marge {gold(margin):>10}  ~{(st['per_day'] or 0):5.1f}/j  ({npc}, {zone})")
    if not rows:
        print("(aucune marge positive trouvée — ouvre plus de marchands pour enrichir la base)")

    print(f"\n-- Sessions de farm (valeur au prix HV, net de commission) --")
    sessions = con.execute("SELECT start, stop, zone, money FROM farm_sessions WHERE realm=? ORDER BY start DESC",
                           (realm,)).fetchall()
    for start, stop, zone, money in sessions[:top]:
        hrs = max((stop - start) / 3600, 1 / 60)
        value, illiquid = 0, 0
        for item, qty in con.execute("SELECT item, qty FROM farm_loot WHERE realm=? AND start=?", (realm, start)):
            st = stats.get(item)
            if st:
                # on ne valorise que ce que le marché peut absorber en ~1 jour
                sellable = min(qty, st["per_day"] or qty)
                value += sellable * st["price"] * (1 - AH_CUT)
                illiquid += qty - sellable
        print(f"{zone:25} {hrs:4.1f} h  objets {gold(value / hrs)}/h  + or ramassé {gold(money / hrs)}/h"
              + (f"  ({illiquid:.0f} unités au-delà du volume journalier)" if illiquid else ""))
    if not sessions:
        print("(aucune session — /ahl farm start puis /ahl farm stop en jeu)")


def cmd_brief(path, out):
    data = LuaParser(Path(path).read_text(encoding="utf-8")).parse_file().get("AHLedgerDB") or {}
    brief = data.get("brief")
    if not brief or not brief.get("text"):
        sys.exit("Pas encore de rapport : fais un scan en jeu (ou /ahl claude), puis /reload.")
    text = brief["text"]
    if out:
        Path(out).write_text(text, encoding="utf-8")
        print(f"Rapport écrit dans {out} ({len(text)} caractères).")
    else:
        print(text)


# --------------------------------------------------------------------------
# Synchronisation vers Google Drive (via Google Drive pour ordinateur)
# --------------------------------------------------------------------------
WOW_ROOTS = [
    r"C:\Program Files (x86)\World of Warcraft", r"C:\Program Files\World of Warcraft",
    r"D:\World of Warcraft", r"D:\Games\World of Warcraft", r"E:\World of Warcraft",
    "/Applications/World of Warcraft",
]
DRIVE_NAMES = ["My Drive", "Mon Drive"]
HISTORY_KEEP = 30


def find_saved_variables():
    """Le fichier AHLedger.lua le plus récent parmi les installations de WoW courantes."""
    found = []
    for root in WOW_ROOTS:
        found += glob.glob(os.path.join(root, "_*_", "WTF", "Account", "*", "SavedVariables", "AHLedger.lua"))
    return max(found, key=os.path.getmtime) if found else None


def find_drive_folder(candidates=None):
    """Le dossier « Mon Drive » de Google Drive pour ordinateur (Windows : lecteur G: par défaut ; macOS : CloudStorage).
    Avec plusieurs comptes Google (un lecteur chacun), on prend celui qui a déjà un dossier AHLedger."""
    if candidates is None:
        candidates = drive_candidates()
    found = [c for c in candidates if os.path.isdir(c)]
    for c in found:
        if os.path.isdir(os.path.join(c, "AHLedger")):
            return c
    return found[0] if found else None


def drive_candidates():
    candidates = []
    if os.name == "nt":
        for letter in "GHIJKLMNOPQRSTUVWXYZDEF":
            candidates += [f"{letter}:\\{name}" for name in DRIVE_NAMES]
    home = Path.home()
    candidates += [str(p) for p in home.glob("Library/CloudStorage/GoogleDrive-*/*") if p.name in DRIVE_NAMES]
    candidates += [str(home / "Google Drive" / name) for name in DRIVE_NAMES] + [str(home / "Google Drive")]
    return candidates


def write_report(sv, dest):
    data = LuaParser(Path(sv).read_text(encoding="utf-8")).parse_file().get("AHLedgerDB") or {}
    brief = data.get("brief") or {}
    text = brief.get("text")
    if not text:
        return None
    dest = Path(dest)
    hist = dest / "historique"
    hist.mkdir(parents=True, exist_ok=True)
    stamp = datetime.fromtimestamp(brief.get("t") or time.time()).strftime("%Y-%m-%d_%Hh%M")
    # écriture atomique : Drive ne synchronise jamais un fichier à moitié écrit
    tmp = dest / "rapport.md.tmp"
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, dest / "rapport.md")
    (hist / f"rapport-{stamp}.md").write_text(text, encoding="utf-8")
    old = sorted(hist.glob("rapport-*.md"))
    for f in old[:-HISTORY_KEEP]:
        f.unlink()
    return stamp


def cmd_sync(sv, to, once, interval):
    sv = sv or find_saved_variables()
    if not sv or not os.path.isfile(sv):
        sys.exit("Fichier AHLedger.lua introuvable : indique-le avec --sv \".../WTF/Account/<COMPTE>/SavedVariables/AHLedger.lua\"")
    if not to:
        drive = find_drive_folder()
        if not drive:
            sys.exit("Dossier Google Drive introuvable : installe Google Drive pour ordinateur, ou indique le dossier avec --to")
        to = os.path.join(drive, "AHLedger")
    print(f"Source : {sv}\nDestination : {to}")
    last = None
    while True:
        try:
            mtime = os.path.getmtime(sv)
            if mtime != last:
                time.sleep(1)  # laisse le jeu finir d'écrire le fichier
                stamp = write_report(sv, to)
                last = mtime
                print(f"[{datetime.now():%H:%M}] " + (f"rapport du {stamp} copié dans Drive" if stamp
                      else "pas encore de rapport : fais un scan en jeu puis /reload"))
        except Exception as e:  # fichier en cours d'écriture par le jeu : on réessaie au tour suivant
            print(f"[{datetime.now():%H:%M}] lecture impossible ({e}), nouvel essai dans {interval} s")
        if once:
            return
        time.sleep(interval)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("import")
    p.add_argument("file")
    p = sub.add_parser("report")
    p.add_argument("--realm")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--top", type=int, default=15)
    p = sub.add_parser("brief")
    p.add_argument("file")
    p.add_argument("--out")
    p = sub.add_parser("sync")
    p.add_argument("--sv")
    p.add_argument("--to")
    p.add_argument("--once", action="store_true")
    p.add_argument("--interval", type=int, default=20)
    args = ap.parse_args()
    if args.cmd == "sync":
        cmd_sync(args.sv, args.to, args.once, args.interval)
    elif args.cmd == "brief":
        cmd_brief(args.file, args.out)
    elif args.cmd == "import":
        cmd_import(args.file)
    else:
        cmd_report(args.realm, args.days, args.top)


if __name__ == "__main__":
    main()
