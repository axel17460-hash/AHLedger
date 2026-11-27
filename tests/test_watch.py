"""Test hors jeu de la liste de surveillance (Watch.lua) : parseur de prix, commandes, déclenchement, anti-spam, réarmement.

Les statistiques de marché sont simulées (le test porte sur Watch, pas sur l'analyse) ; un vrai scan
vérifie le branchement sur Scan.Finish. Usage : python tests/test_watch.py   (pip install lupa)
"""
import sys
from pathlib import Path
# Console Windows (cp1252) : on force l'UTF-8 pour les accents et les flèches
for _s in (sys.stdout, sys.stderr):
    if hasattr(_s, "reconfigure"):
        _s.reconfigure(encoding="utf-8", errors="replace")
import lupa.lua51 as lupa

ROOT = Path(__file__).resolve().parent.parent
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute((Path(__file__).parent / "harness.lua").read_text(encoding="utf-8"))

ns = lua.table()
toc = (ROOT / "AHLedger.toc").read_text(encoding="utf-8")
for f in [l.strip() for l in toc.splitlines() if l.strip().endswith(".lua")]:
    res = lua.eval("function(src, name) return loadstring(src, name) end")((ROOT / f).read_text(encoding="utf-8"), f)
    chunk, err = res if isinstance(res, tuple) else (res, None)
    if chunk is None:
        sys.exit(f"Erreur de syntaxe : {err}")
    chunk("AHLedger", ns)
lua.execute('fire("ADDON_LOADED", "AHLedger"); fire("AUCTION_HOUSE_SHOW"); runTimers()')

# Jamais d'achat ni de vente automatique : Watch.lua n'appelle aucune API d'achat, d'enchère ou de mise en vente
import re
_src = re.sub(r"--[^\n]*", "", (ROOT / "Watch.lua").read_text(encoding="utf-8"))
_bad = re.findall(r"PlaceAuctionBid|PlaceBid|Purchase|PostItem|PostCommodity|PostAuction|StartAuction|CancelAuction", _src)
if _bad:
    sys.exit(f"Watch.lua appelle une API d'achat ou de vente : {_bad}")

lua.globals().NS = ns
src = (Path(__file__).parent / "test_watch.lua").read_text(encoding="utf-8")
fails = lua.eval("function(src) return assert(loadstring(src, 'test_watch.lua'))() end")(src)
fails = [str(v) for v in fails.values()] if fails else []
if fails:
    print("ÉCHECS :")
    for f in fails:
        print(" -", f)
    sys.exit(1)
print("OK : surveillance (parseur de prix, commandes, déclenchement, anti-spam, réarmement, scan, infobulle, interface)")
