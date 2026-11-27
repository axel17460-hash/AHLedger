"""Test hors jeu du module Vente (Sell.lua) : prix proposé, file, undercuts, mise en vente, commandes, interface.

Les statistiques de marché sont simulées (le test porte sur Sell, pas sur l'analyse) ; l'API de mise en
vente (C_AuctionHouse) est un faux qui note les appels. Usage : python tests/test_sell.py   (pip install lupa)
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

lua.globals().NS = ns
src = (Path(__file__).parent / "test_sell.lua").read_text(encoding="utf-8")
fails = lua.eval("function(src) return assert(loadstring(src, 'test_sell.lua'))() end")(src)
fails = [str(v) for v in fails.values()] if fails else []
if fails:
    print("ÉCHECS :")
    for f in fails:
        print(" -", f)
    sys.exit(1)
print("OK : module Vente (prix, anti-troll, plancher/plafond, file, undercuts, mise en vente, commandes, interface)")
