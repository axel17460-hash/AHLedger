"""Rejoue l'analyse d'AHLedger sur de vraies SavedVariables, hors jeu.

    python tests/replay.py "<...>/WTF/Account/<COMPTE>/SavedVariables/AHLedger.lua" [--perso Nom] [--ids 4306,2592]

Affiche le conseil donné pour chaque objet des sacs et de la banque (ou pour les objets
demandés), avec ses sources : de quoi vérifier une règle sur des données réelles avant
de la livrer. Rien n'est écrit dans le fichier.
"""
import argparse, re, sys
from pathlib import Path
for _s in (sys.stdout, sys.stderr):
    if hasattr(_s, "reconfigure"):
        _s.reconfigure(encoding="utf-8", errors="replace")
import lupa.lua51 as lupa

ROOT = Path(__file__).resolve().parent.parent
strip = lambda s: re.sub(r"\|c[0-9a-fA-F]{8}|\|r|\|T[^|]*\|t", "", str(s))


def load(sv_path, perso, faction):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute((Path(__file__).parent / "harness.lua").read_text(encoding="utf-8"))
    lua.execute(Path(sv_path).read_text(encoding="utf-8", errors="replace"))
    lua.execute(f"""
      GetRealmName = function() return "" end
      UnitFactionGroup = function() return "{faction}" end
      UnitName = function() return "{perso}" end
      AuctionHouseFrame.shown = false
    """)
    # l'horloge du rejeu = le dernier scan enregistré
    last = lua.eval(f"""(function()
      local best = 0
      for _, r in pairs(AHLedgerDB.realms or {{}}) do
        if r.lastScanTime and r.lastScanTime > best then best = r.lastScanTime end
      end
      return best end)()""")
    lua.execute(f"local t = {int(last) + 60}; time = function() return t end")
    ns = lua.table()
    toc = (ROOT / "AHLedger.toc").read_text(encoding="utf-8")
    for f in [l.strip() for l in toc.splitlines() if l.strip().endswith(".lua")]:
        res = lua.eval("function(src, name) return loadstring(src, name) end")((ROOT / f).read_text(encoding="utf-8"), f)
        chunk, err = res if isinstance(res, tuple) else (res, None)
        if chunk is None:
            sys.exit(f"Erreur de syntaxe : {err}")
        chunk("AHLedger", ns)
    lua.execute('fire("ADDON_LOADED", "AHLedger"); fire("PLAYER_LOGIN"); runTimers()')
    return lua, ns


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sv")
    ap.add_argument("--perso", default="Cyradil")
    ap.add_argument("--faction", default="Alliance")
    ap.add_argument("--ids", default="")
    a = ap.parse_args()
    lua, ns = load(a.sv, a.perso, a.faction)
    ids = [int(x) for x in a.ids.split(",") if x.strip()]
    show = lua.eval("""function(ns, ids)
      local out = {}
      local list = {}
      if ids and #ids > 0 then
        local c = ns.Prof.Char()
        for _, id in ipairs(ids) do
          list[#list + 1] = { id = id, n = ((c.bags or {})[id] or 0) + ((c.bank or {})[id] or 0) }
        end
      else
        local c = ns.Prof.Char()
        local all = {}
        for id, n in pairs(c.bags or {}) do all[id] = (all[id] or 0) + n end
        for id, n in pairs(c.bank or {}) do all[id] = (all[id] or 0) + n end
        for id, n in pairs(all) do list[#list + 1] = { id = id, n = n } end
      end
      for _, it in ipairs(list) do
        local meta = AHLedgerDB.items[it.id] or {}
        local line = ns.Replay and ns.Replay(it.id, math.max(it.n, 1)) or "?"
        out[#out + 1] = ("%s (#%d) x%d : %s"):format(meta.n or "?", it.id, it.n, line)
      end
      table.sort(out)
      return table.concat(out, "\\n")
    end""")
    lua.eval("""function(ns)
      ns.Replay = function(id, n)
        if ns.Decide then
          local d = ns.Decide.For(id, n)
          if not d then return "(rien)" end
          return ns.Decide.Line(d) .. "  ||  " .. ns.Decide.Why(d)
        end
        local e = ns.Bags.Advise(id, n)
        if not e then return "(rien)" end
        return ("%s %s · %s"):format(e.action, e.post and ns.money(e.post) or "", e.why or "")
      end
    end""")(ns)
    ids_t = lua.table(*ids)
    print(strip(show(ns, ids_t)))


if __name__ == "__main__":
    main()
