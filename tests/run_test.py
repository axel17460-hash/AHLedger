"""Test hors jeu : simule 14 jours de marché, scanne 6 fois par soir, puis vérifie l'analyse et l'interface."""
import re, subprocess, sys
from pathlib import Path
import lupa.lua51 as lupa

ROOT = Path(__file__).resolve().parent.parent
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute((Path(__file__).parent / "harness.lua").read_text())

ns = lua.table()
toc = (ROOT / "AHLedger.toc").read_text()
for f in [l.strip() for l in toc.splitlines() if l.strip().endswith(".lua")]:
    res = lua.eval("function(src, name) return loadstring(src, name) end")((ROOT / f).read_text(), f)
    chunk, err = res if isinstance(res, tuple) else (res, None)
    if chunk is None:
        sys.exit(f"Erreur de syntaxe : {err}")
    chunk("AHLedger", ns)
lua.execute('fire("ADDON_LOADED", "AHLedger"); GetRealmName = function() return "" end; fire("AUCTION_HOUSE_SHOW"); runTimers()')

# 14 jours ; le joueur scanne chaque soir de 18 h à 23 h
lua.execute("""
for h = 1, 14 * 24 do
  simHour()
  local hr = clockHour()
  if hr >= 18 and hr <= 23 then
    buildAuctions()
    SlashCmdList.AHLEDGER("scan")
    runTimers()
  end
end
-- dernier scan avec des enchères bradées sous le prix PNJ
simHour(); buildAuctions()
table.insert(AUCTIONS, { id = 2592, count = 20, buyout = 400, owner = "Radin", tl = 4 })              -- 20c/u, PNJ 33c/u
table.insert(AUCTIONS, { id = 2592, count = 5, buyout = 0, minBid = 50, owner = "Pressé", tl = 1 })   -- enchère seule
table.insert(AUCTIONS, { id = 4338, count = 20, buyout = 30000, owner = "Normal", tl = 4 })           -- pas une affaire
SlashCmdList.AHLEDGER("scan"); runTimers()
fire("MERCHANT_SHOW")
SlashCmdList.AHLEDGER("farm start")
for i = 1, 20 do fire("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:4306::::|h[Silk Cloth]|h|rx2.") end
addMoney(15000)
advance(3600)
SlashCmdList.AHLEDGER("farm stop")
""")
log = list(lua.eval("LOG").values())
print(log[-3:], "\n")

strip = lambda s: re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", str(s))
def show_ui(mode):
    ns.UI.SetMode(mode)
    print(f"--- Onglet {mode} ---")
    for row in ns.UI.rows.values():
        if row.shown:
            cells = [strip(row.cells[i].text) for i in range(1, 9) if row.cells[i].text]
            print(" | ".join(cells))
    print(strip(ns.UI.footer.text), "\n")

lua.execute("SlashCmdList.AHLEDGER('')")  # ouvre la fenêtre
for mode in ("market", "vendor", "snipe", "farm"):
    show_ui(mode)

# Attendus : soie en hausse/pénurie, tisse-mage en baisse/afflux, fioles rentables chez le PNJ
stats = ns.Analysis.All().byId
silk, mage, linen = stats[4306], stats[4338], stats[2589]
print(f"Soie : tendance {silk.trend:+.3f}/j (simulé +0.05), signaux {list(silk.signals.values())}")
print(f"Tisse-mage : tendance {mage.trend:+.3f}/j (simulé -0.04), signaux {list(mage.signals.values())}")
print(f"Lin : {linen.perDay:.0f} vendus/j (simulé ~1200/j, ventes par piles de 20), tendance {linen.trend:+.3f}")
assert 0.03 < silk.trend < 0.07 and "hausse" in silk.signals.values()
assert -0.06 < mage.trend < -0.02 and "baisse" in mage.signals.values()
assert "pénurie" in silk.signals.values() and "afflux" in mage.signals.values()
assert 600 < linen.perDay < 1300

# Revente PNJ : scan complet
snipes = list(lua.eval("AHLedgerDB.realms['Forever-Horde'].snipes").values())
kinds = sorted((s.kind, s.profit) for s in snipes)
print("Opportunités revente PNJ :", kinds)
assert kinds == [("achat", 260), ("enchère", 115)], kinds

# Clic sur la 1re ligne de l'onglet -> recherche dans Parcourir
ns.UI.SetMode("snipe")
row = ns.UI.rows[1]
lua.execute("canQuery = true")
row.scripts.OnClick(row)
print(strip(list(lua.eval("LOG").values())[-1]))

# Navigation normale : une page de résultats avec une affaire -> alerte chat
lua.execute('''
AUCTIONS = { { id = 2592, count = 10, buyout = 150, owner = "X", tl = 3 }, { id = 2589, count = 20, buyout = 2000, owner = "Y", tl = 4 } }
fire("AUCTION_ITEM_LIST_UPDATE"); fire("AUCTION_ITEM_LIST_UPDATE")
''')
alerts = [strip(m) for m in lua.eval("LOG").values() if "Revente PNJ|r" in m]
print(alerts)
assert sum("x10" in a for a in alerts) == 1  # une seule alerte malgré deux événements

# Le cadre Parcourir de Blizzard, coupé pendant les scans, doit être rétabli
assert lua.eval('BlizzBrowse.events["AUCTION_ITEM_LIST_UPDATE"]') == True

# Pont Auctionator : scan moderne (replicateInfo + timeLeft 0-3) reçu via son EventBus
lua.execute('''
Auctionator = { State = {}, Constants = { SCAN_DAY_0 = 0 }, FullScan = { Events = { ScanComplete = "replicate_scan_complete" } } }
Auctionator.EventBus = { Register = function(self, l, evs) self.l = l end }
Auctionator.Database = { db = { ["4306"] = { h = {}, l = {}, a = {} } } }
local today = math.floor(time() / 86400)
for d = 0, 6 do Auctionator.Database.db["4306"].h[tostring(today - 6 + d)] = math.floor(1000 * 1.1 ^ d) end
fire("AUCTION_HOUSE_SHOW")
advance(1800)
local raw = {}
for _, a in ipairs(AUCTIONS) do
  raw[#raw + 1] = { replicateInfo = { ITEMS[a.id][1], nil, a.count, 1, true, 1, nil, a.buyout, 1, a.buyout, 0, nil, nil, a.owner, a.owner, 0, a.id, true }, timeLeft = a.tl - 1 }
end
table.insert(raw, { replicateInfo = { "Wool Cloth", nil, 10, 1, true, 1, nil, 100, 1, 100, 0, nil, nil, "Z", "Z", 0, 2592, true }, timeLeft = 3 })
Auctionator.EventBus.l:ReceiveEvent("replicate_scan_complete", raw)
''')
print(strip(list(lua.eval("LOG").values())[-2]), "|", strip(list(lua.eval("LOG").values())[-1]))
assert "Scan Auctionator terminé" in "".join(strip(m) for m in lua.eval("LOG").values())
# Tendance issue de l'historique Auctionator pour un objet sans historique AHLedger suffisant
st = lua.eval("function(ns) local db = ns.realmDB(); db.hist[99999] = nil; return ns.Bridge.History(4306, 14) end")(ns)
print("Historique Auctionator lu :", len(st), "jours")
assert len(st) == 7

# Lecture directe d'un scan complet "Retail" (REPLICATE_ITEM_LIST_UPDATE) + onglet HV via LibAHTab
lua.execute('''
advance(3600)
local list = {}
for _, a in ipairs(AUCTIONS) do list[#list + 1] = a end
C_AuctionHouse = {
  GetNumReplicateItems = function() return #list end,
  GetReplicateItemInfo = function(i) local a = list[i + 1]; return ITEMS[a.id][1], nil, a.count, 1, true, 1, nil, a.buyout, 1, a.buyout, 0, nil, nil, a.owner, a.owner, 0, a.id, true end,
  GetReplicateItemTimeLeft = function(i) return list[i + 1].tl - 1 end,
}
tabs = {}
LibStub = function() return { DoesIDExist = function() return false end, CreateTab = function(_, id, frame, text) tabs[id] = frame end } end
fire("AUCTION_HOUSE_SHOW")
fire("REPLICATE_ITEM_LIST_UPDATE")
runTimers()
fire("REPLICATE_ITEM_LIST_UPDATE") -- doublon ignoré
runTimers()
tabs.AHLedger.scripts.OnShow(tabs.AHLedger)
''')
logs = [strip(m) for m in lua.eval("LOG").values()]
print(logs[-1])
assert sum("Scan Auctionator terminé" in m for m in logs) == 2, logs[-5:]
assert ns.UI.embedded == True

# Tooltip : ne doit pas planter
lua.execute("GameTooltip.GetItem = function() return 'Silk', '|Hitem:4306::::|h' end; GameTooltip.scripts.OnTooltipSetItem(GameTooltip)")

# Export + script Python
sv = Path(__file__).parent / "AHLedger.lua"
sv.write_text(lua.eval("serializeDB")())
tool = ROOT / "tools" / "ahledger.py"
db = tool.with_name("ahledger.sqlite")
db.unlink(missing_ok=True)
subprocess.run([sys.executable, str(tool), "import", str(sv)], check=True, stdout=subprocess.DEVNULL)
subprocess.run([sys.executable, str(tool), "report", "--top", "3"], check=True)
db.unlink(); sv.unlink()
print("\nOK : tous les tests passent.")
