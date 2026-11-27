"""Test hors jeu : simule 14 jours de marché, scanne 6 fois par soir, puis vérifie l'analyse et l'interface."""
import re, subprocess, sys
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
lua.execute('fire("ADDON_LOADED", "AHLedger"); GetRealmName = function() return "" end; fire("AUCTION_HOUSE_SHOW"); runTimers()')

# 14 jours ; le joueur scanne chaque soir de 18 h à 23 h. Il a 1000 po : le budget (Analysis.Budget)
# ne limite pas les conseils de la simulation
lua.execute("""
addMoney(1000 * 10000)
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
table.insert(AUCTIONS, { id = 4306, count = 20, buyout = 10000, owner = "Bradeur", tl = 4 })          -- soie à 5 pa/u : à flipper
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
            cells = [strip(row.cells[i].text) for i in range(1, 10) if row.cells[i].text]
            print(" | ".join(cells))
    print(strip(ns.UI.footer.text), "\n")

# Métiers : niveaux (API Classic) et recette relevée à l'ouverture de la fenêtre de métier
lua.execute("""
local SKILLS = { { "Professions", true, true, 0, 0, 0, 0 }, { "Skinning", false, false, 253, 0, 0, 300 },
                 { "First Aid", false, false, 220, 0, 0, 225 } }
GetNumSkillLines = function() return #SKILLS end
GetSkillLineInfo = function(i) return unpack(SKILLS[i]) end
GetTradeSkillLine = function() return "First Aid", 220, 225 end
GetNumTradeSkills = function() return 2 end
GetTradeSkillInfo = function(i) if i == 1 then return "Potions", "header" end return "Healing Potion", "optimal" end
GetTradeSkillItemLink = function() return "|Hitem:929::::|h" end
GetTradeSkillNumMade = function() return 1, 1 end
GetTradeSkillNumReagents = function() return 2 end
GetTradeSkillReagentInfo = function(_, j) if j == 1 then return "Silk Cloth", nil, 2 end return "Empty Vial", nil, 1 end
GetTradeSkillReagentItemLink = function(_, j) return j == 1 and "|Hitem:4306::::|h" or "|Hitem:3371::::|h" end
fire("SKILL_LINES_CHANGED"); fire("TRADE_SKILL_SHOW"); fire("TRADE_SKILL_UPDATE"); runTimers()
""")
rel = ns.Prof.Related()
assert rel[4304] == "dépeçage" and rel[15417] is None, "dépeçage 253 : cuir épais oui, cuir de diablosaure non"
assert rel[929] == "artisanat" and rel[4306] == "composant"
assert ns.Prof.MaxSkinLevel(253) == 50

# Planificateur : sans base de recettes, plan partiel (couleur actuelle seulement)
partial = ns.Plan.Level("firstaid", 220, 225)
assert partial.partial and partial.reached == 225
# Base de recettes externe (adaptateur factice) : seuils et recette à acheter
lua.eval("""function(ns)
  ns.RecipeDB.Register("test", { Recipes = function(prof)
    if prof ~= "firstaid" then return {} end
    return {
      { out = 929, prof = prof, r = { [4306] = 2, [3371] = 1 }, levels = { 200, 215, 230, 245 } },
      { out = 2589, prof = prof, r = { [3371] = 1 }, made = 1, levels = { 210, 225, 240, 255 },
        source = { kind = "trainer", cost = 5000, where = "Maître" } },
    }
  end })
end""")(ns)
full = ns.Plan.Level("firstaid", 220, 240)
print("Plan secourisme 220 → 240 :", [strip(l) for l in ns.Plan.Describe(full).values()])
assert not full.partial and full.reached == 240 and full.crafts >= 20
lua.execute("SlashCmdList.AHLEDGER('monter secourisme 230')")
assert "Montée Secourisme 220 - 230" in strip(list(lua.eval("LOG").values())[-3]) or any(
    "Montée Secourisme 220 - 230" in strip(m) for m in list(lua.eval("LOG").values())[-6:])
# Diagnostic
lua.execute("SlashCmdList.AHLEDGER('diag')")
diag = [strip(l) for l in lua.eval("AHLedgerDB.diag.lines").values()]
print("\n".join(diag))
assert any(l.startswith("OK   Scan HV") for l in diag) and any("Sources de recettes : connues, test" in l for l in diag)

lua.execute("SlashCmdList.AHLEDGER('')")  # ouvre la fenêtre
for mode in ("market", "flip", "craft", "level", "vendor", "snipe", "farm", "track"):
    show_ui(mode)

# Flip HV : la pile bradée de soie doit ressortir, achetée jusqu'à 5 pa/u
flips = {f.id: f for f in ns.Analysis.Flips().values()}
silkFlip = flips.get(4306)
print("Flip soie :", silkFlip and (silkFlip.qty, silkFlip.maxBuy, round(silkFlip.resale), round(silkFlip.profit)))
assert silkFlip and silkFlip.maxBuy >= 500 and silkFlip.qty >= 20 and silkFlip.resale > 900
assert 4338 not in flips  # tisse-mage en afflux, pas de pile sous le prix

# Budget : un flip est plafonné à la moitié de ton or ; sans or, il est écarté et compté
bud = lua.eval("""function(ns)
  local c, A = ns.Prof.Char(), ns.Analysis
  local saved = c.money
  local full
  for _, x in ipairs(A.Flips()) do if x.id == 4306 then full = x end end
  c.money = full.cost                              -- budget = la moitié du flip complet
  local f
  for _, x in ipairs(A.Flips()) do if x.id == 4306 then f = x end end
  local r = { f and f.qty, f and f.cost, f and f.budgetCut, A.Budget(), 0, 0, full.qty }
  c.money = 0
  local n = #A.Flips()
  r[5], r[6] = n, A.flipsOverBudget
  c.money = saved
  return r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10]
end""")(ns)
print("Budget :", list(bud))
assert bud[0] and bud[0] < bud[6] and bud[1] <= bud[3] and bud[2] is True, bud
assert bud[4] == 0 and bud[5] >= 1, bud
print("OK : flips plafonnés par ton or")
# Artisanat : coût = 2 soies (HV) + 1 fiole (PNJ 20c)
craft = {c.id: c for c in ns.Analysis.Crafts().values()}[929]
silkMin = ns.Analysis.Get(4306).minNow
print("Artisanat potion : coût", craft.cost, "valeur", craft.value, "bénéfice", craft.profit)
assert craft.cost == 2 * silkMin + 20 and craft.diff == "optimal"
# Concurrence et écoulement exposés dans les stats
silk = ns.Analysis.Get(4306)
assert silk.sellers and silk.sellers >= 2 and silk.sellThrough and 0 < silk.sellThrough <= 1

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
assert ns.UI.embedded is not None and ns.UI.embedded is not False

# Tooltip : tendance 24 h issue des scans récents
lua.execute("""
TT = {}
GameTooltip.AddLine = function(_, t) TT[#TT + 1] = t end
GameTooltip.AddDoubleLine = function(_, a, b) TT[#TT + 1] = a .. " = " .. b end
GameTooltip.GetItem = function() return 'Silk', '|Hitem:4306::::|h' end
GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
""")
tt = [strip(re.sub(r"\|T[^|]*\|t", "", x)) for x in lua.eval("TT").values()]
print("\n".join(tt))
assert any(x.startswith("Tendance = 24 h +") for x in tt), tt

# Conseiller d'inventaire : soie en hausse -> garder ; tisse-mage en baisse -> vendre sous l'enchère la moins chère
lua.execute("""
BAGS = { [0] = { { 4306, 40 }, { 4338, 30 }, { 2589, 3 } } }
GetContainerNumSlots = function(b) return BAGS[b] and #BAGS[b] or 0 end
GetContainerItemInfo = function(b, s) local x = BAGS[b][s]; return nil, x[2], false, 1, false, false, nil, false, false, x[1] end
fire("BAG_UPDATE_DELAYED"); runTimers()
""")
adv = {e.id: e for e in ns.Bags.Advice().values()}
for e in adv.values():
    print("Conseil", strip(lua.eval("function(id) return AHLedgerDB.items[id].n end")(e.id)), e.count, e.action, e.post, e.postQty, strip(e.why))
# la soie vaut plus transformée (recette simulée) : « Fabriquer » l'emporte sur « Garder »
assert adv[4306].action == ("Fabriquer" if ns.Analysis.CraftUp(4306) else "Garder"), adv[4306].action
mage = ns.Analysis.Get(4338)
assert adv[4338].action == "Vendre HV" and adv[4338].post == (mage.minNow - 1 if mage.minNow else int(mage.price)) and adv[4338].postQty == 30
ns.UI.SetMode("bags"); assert ns.UI.rows[1].shown

# Bilan : courriers d'HV (6 ventes, 1 achat, 1 expiration), relus deux fois sans doublon, puis une
# troisième fois après avoir récupéré l'or (montant du courrier à 0) ; calibrage de la commission (7 %)
# et du dépôt (15 % du prix PNJ). Factures au format de Forever : quantité en 11e retour, et le champ
# « rachat » d'une pile contient la quantité, pas le prix.
lua.execute("""
AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
MAILS = {}
for i = 1, 6 do
  MAILS[#MAILS + 1] = { subject = "Auction successful: Mageweave Cloth (20)", money = 20000 - 1400 + 750,
    inv = { "seller", "Mageweave Cloth (20)", "Acheteur", 20000, 20, 750, 1400, 0, 0, 0, 20 } }
end
MAILS[#MAILS + 1] = { subject = "Auction won: Silk Cloth", money = 0, inv = { "buyer", "Silk Cloth (20)", "Bradeur", 10000, 20, 0, 0, 0, 0, 0, 20 } }
MAILS[#MAILS + 1] = { subject = "Auction expired: Healing Potion (5)", money = 0, item = 929 }
GetInboxNumItems = function() return #MAILS end
GetInboxHeaderInfo = function(i) local m = MAILS[i]; return nil, nil, "Hôtel des ventes", m.subject, m.money, 0, 29.5 end
GetInboxInvoiceInfo = function(i) local m = MAILS[i]; if m.inv then return unpack(m.inv) end end
GetInboxItemLink = function(i) local m = MAILS[i]; return m.item and ("|Hitem:" .. m.item .. "::::|h") end
GetInboxItem = function(i) return "Healing Potion", 929, nil, 5 end
fire("MAIL_INBOX_UPDATE"); advance(60); fire("MAIL_INBOX_UPDATE")
for _, m in ipairs(MAILS) do m.money = 0 end
advance(15); fire("MAIL_INBOX_UPDATE")
""")
rows = {(r.id or r.name): r for r in ns.Ledger.Summary()[0].values()}
print("Bilan tisse-mage :", rows[4338].sold, rows[4338].revenue, "| soie achetée :", rows[4306].bought, "| potions expirées :", rows[929].expired)
assert rows[4338].sold == 120 and rows[4338].revenue == 6 * (20000 - 1400)
assert rows[4306].bought == 20 and rows[4306].spent == 10000 and rows[929].expired == 5
assert abs(ns.Analysis.AH_CUT - 0.07) < 1e-9 and abs(ns.Analysis.DEPOSIT_RATE - 0.15) < 1e-9
ns.UI.SetMode("ledger"); print(strip(ns.UI.help.text))
lua.execute("SlashCmdList.AHLEDGER('bilan')")
print(strip(list(lua.eval("LOG").values())[-1]))

# Réparation des lignes relevées par la 0.8.0 (quantité 0, prix = quantité, doublons)
rep = lua.eval("""function(ns)
  local db = ns.Ledger.DB()
  local saved, savedFix = db.ledger, db.ledgerFix
  db.ledger = {
    { k = "sold", n = "Silk Cloth", c = 0, g = 40, cut = 394, dep = 1200, t = 1000 },
    { k = "sold", n = "Silk Cloth", c = 0, g = 40, cut = 394, dep = 1200, t = 1015 },
    { k = "sold", n = "Claymore", c = 0, g = 12343, cut = 617, dep = 1859, t = 1000 },
    { k = "bought", n = "Keen Raptor Tooth", c = 0, g = 1800, cut = 0, dep = 0, t = 1000 },
    { k = "expired", n = "Hulking Leggings", c = 1, t = 1000 },
  }
  db.ledgerFix = nil
  local fixed = ns.Ledger.Repair()
  local L = db.ledger
  local out = { fixed, #L, L[1].c, L[1].g, L[2].c, L[2].g, L[3].c, db.ledgerFix }
  db.ledger, db.ledgerFix = saved, savedFix
  ns.Ledger.Calibrate()
  return unpack(out)
end""")(ns)
print("Réparation du bilan :", rep)
assert rep == (5, 4, 40, 7880, 1, 12343, 1, 1), rep

# Conseil de sac : un objet qui ne se vend presque pas n'est pas conseillé à l'HV
slow = lua.eval("""function(ns)
  local A = ns.Analysis
  local real = A.Get
  local s = { id = 999002, price = 400, netExp = 380, perDay = 0.1, minNow = 390 }
  A.Get = function(id) if id == 999002 then return s end return real(id) end
  AHLedgerDB.items[999002] = { n = "Poison lent", s = 0 }
  local a = ns.Bags.Advise(999002, 8)
  AHLedgerDB.items[999002].s = 300
  local b = ns.Bags.Advise(999002, 8)
  A.Get = real; AHLedgerDB.items[999002] = nil
  return a.action, b.action
end""")(ns)
print("Objet qui se vend peu :", slow)
assert slow == ("Garder", "PNJ"), slow

# Artisanat : classé par or/jour possible (bénéfice × part des ventes sûres du marché)
crafts = [e for e in ns.Analysis.Crafts().values() if e.profit is not None]
for e in crafts:
    assert e.daily is not None and e.vol is not None
    if e.sellTo == "HV":
        assert not e.sale.slow and abs(e.vol - (e.sale.rate or 0) * 0.25 / e.made) < 1e-6

# Mes enchères en cours (API moderne simulée) : sous-cotée, vendue
mine = lua.eval("""function(ns)
  local mage = ns.Analysis.Get(4338)
  local OWNED = {
    { itemKey = { itemID = 4338 }, quantity = 20, buyoutAmount = math.floor((mage.minNow or mage.price) * 1.5), timeLeftSeconds = 40000, status = 0 },
    { itemKey = { itemID = 4338 }, quantity = 20, buyoutAmount = math.floor((mage.minNow or mage.price) * 1.5), timeLeftSeconds = 30000, status = 0 },
    { itemKey = { itemID = 4306 }, quantity = 10, buyoutAmount = 5000, status = 1 },
  }
  C_AuctionHouse = { GetNumOwnedAuctions = function() return #OWNED end, GetOwnedAuctionInfo = function(i) return OWNED[i] end }
  fire("OWNED_AUCTIONS_UPDATED")
  C_AuctionHouse = nil
  local groups = ns.Auctions.Summary()
  local by = {}
  for _, gr in ipairs(groups) do by[gr.id] = gr end
  return #groups, by[4338].qty, by[4338].auctions, by[4338].status, by[4338].left, by[4306].status, by[4306].unit
end""")(ns)
print("Mes enchères :", mine)
assert mine[:3] == (2, 40, 2) and mine[3] in ("sous-coté", "trop cher") and mine[4:] == (30000, "vendu", 500), mine

# Rapport pour Claude : /ahl claude ouvre la fenêtre de copie et enregistre le rapport
lua.execute("SlashCmdList.AHLEDGER('claude')")
report = strip(lua.eval("AHLedgerDB.brief.text"))
print("\n" + report + "\n")
for section in ("## Marché", "## Flips HV", "## Artisanat", "## Mes objets", "## Mes enchères en cours", "à récupérer au courrier",
                "## Bilan réel", "Métiers : Dépeçage 253/300"):
    assert section in report, section
assert "|c" not in report and len(report) < 20000

# Export + script Python
sv = Path(__file__).parent / "AHLedger.lua"
sv.write_text(lua.eval("serializeDB")(), encoding="utf-8")
tool = ROOT / "tools" / "ahledger.py"
db = tool.with_name("ahledger.sqlite")
db.unlink(missing_ok=True)
subprocess.run([sys.executable, str(tool), "import", str(sv)], check=True, stdout=subprocess.DEVNULL)
subprocess.run([sys.executable, str(tool), "report", "--top", "3"], check=True)
brief = subprocess.run([sys.executable, str(tool), "brief", str(sv)], check=True, capture_output=True, text=True, encoding="utf-8").stdout
assert "## Flips HV" in brief and "Mageweave Cloth" in brief
import tempfile
with tempfile.TemporaryDirectory() as d:
    subprocess.run([sys.executable, str(tool), "sync", "--sv", str(sv), "--to", d, "--once"], check=True, stdout=subprocess.DEVNULL)
    assert (Path(d) / "rapport.md").read_text(encoding="utf-8") == brief.rstrip("\n")
    assert len(list((Path(d) / "historique").glob("rapport-*.md"))) == 1
    # la méthode de lecture voyage avec le rapport, qui y renvoie avec sa version
    assert (Path(d) / "METHODE.md").read_text(encoding="utf-8") == (ROOT / "METHODE.md").read_text(encoding="utf-8")
    assert "METHODE.md v%d" % ns.Export.METHODE in brief
    # Plusieurs comptes Google : le lecteur qui a déjà un dossier AHLedger gagne, sinon le premier trouvé
    import importlib.util
    spec = importlib.util.spec_from_file_location("ahledger_tool", tool)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    a, b = Path(d) / "compteA" / "My Drive", Path(d) / "compteB" / "My Drive"
    a.mkdir(parents=True); b.mkdir(parents=True)
    assert mod.find_drive_folder([str(Path(d) / "absent"), str(a), str(b)]) == str(a)
    (b / "AHLedger").mkdir()
    assert mod.find_drive_folder([str(a), str(b)]) == str(b)
    assert mod.find_drive_folder([str(Path(d) / "absent")]) is None
db.unlink(); sv.unlink()

# Noms vides (API Retail, objet pas encore en cache) : jamais stockés, redemandés ensuite
names =lua.eval("""function(ns)
  local real = ns.GetItemInfo
  local cached = false
  ns.GetItemInfo = function(id) if id == 99001 and cached then return "Objet test", nil, 1, nil, nil, nil, nil, nil, nil, nil, 50, 7 end end
  ns.rememberItem(99001, "")
  local before = AHLedgerDB.items[99001].n
  AHLedgerDB.items[99002] = { n = "", s = 10 }          -- ancienne donnée abîmée
  cached = true
  local missing = ns.FillMissingNames()
  runTimers()
  ns.GetItemInfo = real
  return before, AHLedgerDB.items[99001].n, AHLedgerDB.items[99001].s, AHLedgerDB.items[99002].n, missing
end""")(ns)
assert names[0] is None and names[1] == "Objet test" and names[2] == 50, names
assert names[3] is None and names[4] >= 2, names  # "" effacé ; 99002 inconnu du mock, reste sans nom

# Vendeurs inconnus (Forever ne donne pas les noms) : structure du marché inconnue, pas « 1 vendeur à 100 % »
book = ns.Scan.UnpackBook("0,0|100:5;120:3")
assert book.sellers is None and book.top is None and len(list(book.levels.values())) == 2

# Tendance robuste : 2 points refusés, une enchère aberrante ne fait pas exploser la pente
rs = ns.Analysis.robustSlope
assert rs(lua.eval("{ {-1, 0}, {0, 5} }"), 2) is None
b = rs(lua.eval("{ {-6, 1.0}, {-5, 1.01}, {-4, 1.02}, {-3, 6.0}, {-2, 1.04}, {-1, 1.05}, {0, 1.06} }"), 2)
assert b is not None and abs(b - 0.01) < 0.005, b
assert rs(lua.eval("{ {-0.5, 1}, {-0.2, 1.1}, {0, 1.2} }"), 2) is None  # moins de 2 jours d'écart

# Prix réel de vente aberrant (enchère très chère disparue) : on garde le prix affiché
real = lua.eval("""function(ns, soldVal)
  local t = ns.History.today()
  local db = { days = { [t] = { scans = 1, obs = 36000 } }, hist = { [99010] = { [t] = "1000,1,10,10,0," .. soldVal .. ",0" } },
               book = {}, lastMin = {}, recent = {} }
  local s = ns.Analysis.ItemStats(db, 99010, t)
  return s.realPrice, s.price
end""")
assert real(ns, 9000) == (900, 900), real(ns, 9000)       # 90 % du prix affiché : prix réel retenu
assert real(ns, 35000) == (None, 1000), real(ns, 35000)   # 3,5 fois le prix affiché : écarté
# Daylight UI : fenêtres dressées par son API publique, onglet AHLedger dans sa fenêtre HV
dl = lua.eval("""function(ns)
  local calls = { skin = 0, close = 0 }
  local Main = { TABS = { { id = "buy" }, { id = "sell" }, { id = "auctions" } } }
  function Main.Build() Main.frame = { pages = { ahledger = CreateFrame() } }; Main.built = #Main.TABS end
  function Main.ShowTab(id) Main.tab = id end
  local me = {
    RegisterMover = function() return true end,
    Wrap = function(t, k, fn) local o = t[k]; t[k] = function(...) return fn(o, ...) end end,
    Hook = function(t, k, fn) local o = t[k]; t[k] = function(...) local r = o(...); fn(...); return r end end,
  }
  DaylightUI = {
    GetModule = function(_, name) if name == "AuctionHouse" then return { ns = { Window = Main } } end end,
    API = {
      major = 1, minor = 13,
      Skin = function() calls.skin = calls.skin + 1 end,
      Text = function() return mock() end,
      Button = function(_, label) local b = CreateFrame(); b.text = mock(); b.text:SetText(label); return b end,
      Close = function() calls.close = calls.close + 1; return mock() end,
      Colors = function() return { TEXT = { 1, 1, 1 }, LABEL = { 0.8, 0.7, 0.5 } } end,
      Accent = function() return 0.3, 0.6, 1 end,
      Font = function() return "Fonts\\\\FRIZQT__.TTF" end,
      For = function() return me end,
    },
  }
  C_AddOns = { IsAddOnLoaded = function(name) return name == "DaylightUI_AuctionHouse" end }
  ns.UI.frame, ns.UI.content, ns.Export.frame, ns.UI.embedded = nil, nil, nil, false
  ns.UI.dlTried, ns.UI.dlTab, ns.Look.me = nil, nil, nil
  local hooked = ns.UI.HookDaylightAH()
  Main.Build()                                   -- Daylight UI construit sa fenêtre (PLAYER_LOGIN)
  Main.ShowTab("ahledger")                       -- le joueur clique l'onglet AHLedger
  local docked = ns.UI.embedded == Main.frame.pages.ahledger
  Main.ShowTab("buy")
  ns.UI.Toggle()                                 -- /ahl : le contenu ressort dans sa fenêtre
  local alone = ns.UI.embedded == false and ns.UI.frame:IsShown()
  fire("AUCTION_HOUSE_SHOW")
  local noButton = ns.UI.ahButton == nil         -- l'onglet suffit, pas de bouton de repli
  ns.Export.Show()
  local label = ns.UI.modeButtons.market.text:GetText()
  DaylightUI, C_AddOns = nil, nil
  return hooked, Main.built, Main.TABS[4] and Main.TABS[4].id, docked, alone, noButton, calls.skin, calls.close, label
end""")(ns)
assert dl[0] is True and dl[1] == 4 and dl[2] == "ahledger", dl   # onglet ajouté avant la construction
assert dl[3] and dl[4] and dl[5], dl
assert dl[6] >= 3 and dl[7] == 2 and dl[8] == "Marché", dl         # 2 fenêtres + zone du rapport

# Daylight UI sans module HV accessible : repli sur le bouton déplaçable
fb = lua.eval("""function(ns)
  local mover
  DaylightUI = { API = { major = 1, Skin = function() end, Text = function() return mock() end,
    Button = function() local b = CreateFrame(); b.text = mock(); return b end, Close = function() return mock() end,
    Colors = function() return {} end, Accent = function() return 1, 1, 1 end,
    For = function() return { RegisterMover = function(_, key) mover = key end } end } }
  C_AddOns = { IsAddOnLoaded = function() return true end }
  ns.UI.dlTried, ns.UI.dlTab, ns.UI.ahButton, ns.Look.me = nil, nil, nil, nil
  local hooked = ns.UI.HookDaylightAH()
  fire("AUCTION_HOUSE_SHOW")
  local shown = ns.UI.ahButton and ns.UI.ahButton:IsShown()
  fire("AUCTION_HOUSE_CLOSED")
  local hidden = not ns.UI.ahButton:IsShown()
  DaylightUI, C_AddOns = nil, nil
  return hooked, shown, hidden, mover
end""")(ns)
assert fb[0] is False and fb[1] and fb[2] and fb[3] == "ahbutton", fb

# Adaptateur OneForAll : table globale factice au format de OneForAll, branchée quand l'addon se charge
ofa = lua.eval("""function(ns)
  OneForAll = {
    PROFESSION_RECIPES = { ["Leatherworking"] = {
      { s = 1, i = 2304, c = 1, n = "Kit d'office", req = 1, y = 30, g = 45, gr = 60, r = { { 4306, 1, "Soie" } }, start = true },
      { s = 2, i = 5957, n = "Gilet du maître", req = 10, y = 40, g = 55, gr = 70, r = { { 4306, 2, "Soie" }, { 3371, 1, "Fiole" } } },
      { s = 3, i = 4237, n = "Ceinture Horde", req = 20, y = 50, g = 60, gr = 70, r = { { 2592, 3, "Laine" } }, ri = 9001,
        src = { v = { { 10, "Marchande A", "Hurlevent", fac = "A" }, { 11, "Marchand H", "Orgrimmar", fac = "H" } } } },
      { s = 4, i = 4238, n = "Ceinture Alliance", req = 20, y = 50, g = 60, gr = 70, r = { { 2592, 2, "Laine" } }, ri = 9002,
        src = { v = { { 10, "Marchande A", "Hurlevent", fac = "A" } } } },
      { s = 5, i = 4239, n = "Butin vendu à l'HV", req = 30, y = 60, g = 70, gr = 80, r = { { 2592, 1, "Laine" } }, ri = 4306,
        src = { d = { { 12, "Ogre", "Les Paluns" } } } },
      { s = 6, i = 4240, n = "Récompense", req = 30, y = 60, g = 70, gr = 80, r = { { 2592, 1, "Laine" } }, ri = 9003,
        src = { qs = { { 769, "Sac en peau" } } } },
      { s = 7, i = 4241, n = "Sans composant", req = 1, y = 1, g = 1, gr = 1, r = {} },
    } },
    PROFESSION_FEES = { ["Leatherworking"] = { fees = { [2] = { 150, 10 } } } },
    VENDOR_PRICES = { [9001] = 1200, [9002] = 900 },
  }
  local before = ns.RecipeDB.providers.OneForAll ~= nil
  fire("ADDON_LOADED", "OneForAll")
  local by = {}
  for _, r in ipairs(ns.RecipesOneForAll.Recipes("leatherworking")) do by[r.out] = r end
  local plan = ns.Plan.Level("leatherworking", 1, 60)
  SlashCmdList.AHLEDGER("diag")
  local diagOk = false
  for _, l in ipairs(AHLedgerDB.diag.lines) do if l:find("Recettes OneForAll : 7", 1, true) then diagOk = true end end
  return before, ns.RecipeDB.providers.OneForAll ~= nil, by, plan.partial, plan.reached, diagOk,
         #ns.RecipesOneForAll.Recipes("cooking")
end""")(ns)
before, registered, by, ofaPartial, ofaReached, ofaDiag, cookingN = ofa
assert before is False and registered is True
assert by[2304].source.cost == 0 and list(by[2304].levels.values()) == [1, 30, 45, 60] and by[2304].r[4306] == 1
assert by[5957].source.kind == "trainer" and by[5957].source.cost == 150 and by[5957].r[3371] == 1
assert by[4237].source.cost == 1200 and "Orgrimmar" in by[4237].source.where   # marchand de ma faction (Horde)
assert by[4238].source.cost is None                                              # marchand Alliance seulement
assert by[4239].source.kind == "drop" and by[4239].source.cost and by[4239].source.where.startswith("HV")
assert by[4240].source.kind == "quest" and by[4240].source.cost is None
assert 4241 not in by and cookingN == 0
assert ofaPartial is False and ofaReached == 60 and ofaDiag, (ofaPartial, ofaReached)

# Planificateur : l'HV n'absorbe qu'environ 2 jours de ventes, le reste ne vaut que le prix PNJ
cap = lua.eval("""function(ns)
  ns.RecipeDB.Register("plafond", { Recipes = function(prof)
    if prof ~= "tailoring" then return {} end
    return { { out = 4306, prof = prof, r = { [2592] = 1 }, made = 20, levels = { 1, 1, 1, 400 }, learned = true } }
  end })
  local rec = ns.RecipeDB.All("tailoring")[1]
  local net, cost, value, vendor, cap = ns.Plan.CraftCost(rec)
  local p = ns.Plan.Level("tailoring", 1, 150)
  return net, cost, vendor, cap, p.crafts, p.total
end""")(ns)
cNet, cCost, cVendor, cCap, cCrafts, cTotal = cap
assert cCap >= 1 and cCrafts > cCap, cap
expected = cCap * cNet + (cCrafts - cCap) * (cCost - cVendor)
# le point qui franchit le plafond compte encore ses quelques fabrications au prix HV
assert 0 <= expected - cTotal <= 5 * abs(cNet - (cCost - cVendor)), (cTotal, expected)
assert cTotal > cCrafts * cNet, cap                                  # moins optimiste que sans plafond

# Clic sur une ligne : l'objet s'affiche à l'achat, dans la fenêtre HV de Daylight UI ou celle du jeu
show = lua.eval("""function(ns)
  local texts, started, mode = {}, 0, nil
  local box = { SetText = function(_, t) texts[#texts + 1] = t end }
  AuctionHouseFrame = { SearchBar = { SearchBox = box, StartSearch = function() started = started + 1 end },
    IsShown = function() return true end, SetDisplayMode = function(_, m) mode = m end }
  AuctionHouseFrameDisplayMode = { Buy = "achat" }
  local savedQuery = QueryAuctionItems
  QueryAuctionItems = nil
  fire("AUCTION_HOUSE_SHOW")
  ns.UI.dlMain = { frame = { IsShown = function() return true end } }
  local r1 = ns.UI.ShowItem(4306)
  local dlTexts, dlStarted = texts[#texts], started            -- Daylight lance lui-même la recherche
  ns.UI.dlMain = nil
  local r2 = ns.UI.ShowItem(4306)
  local row = ns.UI.rows[1]
  QueryAuctionItems = savedQuery
  AuctionHouseFrame, AuctionHouseFrameDisplayMode = nil, nil
  return r1, dlTexts, dlStarted, r2, started, mode, texts[#texts], AHLedgerDB.items[4306].n
end""")(ns)
assert show[0] == "daylight" and show[1] == show[7] and show[2] == 0, show
assert show[3] == "jeu" and show[4] == 1 and show[5] == "achat" and show[6] == show[7], show

print("\nOK : tous les tests passent.")

# Achat PNJ → HV : prix fractionnaire gardé, ancien relevé arrondi à 0c ignoré puis remplacé,
# revente à ×N le prix PNJ « à tester », confirmée par tes propres ventes
vf = lua.eval("""function(ns)
  local db = ns.realmDB()
  local s = ns.Analysis.Get(2589)
  db.vendor[2589] = { p = 0, npc = "Vieux", zone = "?" }
  local before = ns.Analysis.VendorFlip(2589, s, db.vendor[2589], {})
  MERCHANT = { { "Linen Cloth", 10, 200, -1, 2589 } }
  fire("MERCHANT_SHOW")
  local p = db.vendor[2589].p
  local e = ns.Analysis.VendorFlip(2589, s, db.vendor[2589], {})
  local ok = ns.Analysis.VendorFlip(2589, s, db.vendor[2589], { [2589] = { sold = 30, expired = 2, bought = 0, avgSale = 90 } })
  db.vendor[2589] = nil
  return before, p, e.reliable, e.why, e.testQty, ns.money(0.05), ok.reliable, ok.realSold
end""")(ns)
print("PNJ → HV lin :", vf)
assert vf[0] is None and abs(vf[1] - 0.05) < 1e-9, vf
assert vf[2] is False and "prix PNJ" in vf[3] and 1 <= vf[4] <= 20, vf
assert strip(vf[5]) == "0.05c" and vf[6] is True and vf[7] == 30, vf

# Tooltip complet : ton stock, ton conseil et tes ventes réelles apparaissent
lua.execute("""
advance(10)
TT = {}
GameTooltip.GetItem = function() return 'Mageweave', '|Hitem:4338::::|h' end
GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
""")
tt = [strip(re.sub(r"\|T[^|]*\|t", "", x)) for x in lua.eval("TT").values()]
print("\n".join(tt))
assert any(x.startswith("Tes 30 : Vendre HV") for x in tt), tt
assert any(x.startswith("Toi, 30 j = 120 vendus") for x in tt), tt
assert any(x.startswith("Données : ") for x in tt), tt
print("OK : tests PNJ → HV et tooltip")
assert any(x.startswith("Vendre à l'HV") or x.startswith("HV ≈ PNJ") or x.startswith("Au PNJ") for x in tt[:4]), tt

# Verdict du tooltip selon ton rôle : objet fabriqué avec bénéfice (vendeur) ou composant (acheteur)
verdicts = lua.eval("""function(ns)
  local A, P = ns.Analysis, ns.Prof
  local realGet, realCrafts, realRecipes = A.Get, A.Crafts, P.Recipes
  local function fake(id) return { id = id, netExp = 500, trend24 = -0.05, vsAvg = 0, signals = {} } end
  A.Get = function(id) if id == 999101 or id == 999102 then return fake(id) end return realGet(id) end
  P.Recipes = function() return { test = { [999101] = { n = "Lingot", r = { [999102] = 1 } } } } end
  A.Crafts = function() return { { id = 999101, prof = "test", cost = 240, profit = 314, sellTo = "HV" } } end
  local out = {}
  for i, id in ipairs({ 999101, 999102 }) do
    TT = {}
    GameTooltip.GetItem = function() return 'x', '|Hitem:' .. id .. '::::|h' end
    GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
    out[i] = table.concat(TT, "\\n")
  end
  A.Get, A.Crafts, P.Recipes = realGet, realCrafts, realRecipes
  return out[1], out[2]
end""")(ns)
crafted, reagent = (strip(v) for v in verdicts)
print("Verdict fabriqué :", [l for l in crafted.split("\n") if "baisse" in l])
print("Verdict composant :", [l for l in reagent.split("\n") if "baisse" in l])
assert "fabrique et vends tout de suite" in crafted and "ne pas stocker" not in crafted, crafted
assert "attends pour acheter" in reagent and "vendre vite" not in reagent, reagent

# HV ou PNJ : seuils ±10 %, et pastilles sur les cases de Daylight UI tant que l'HV est ouverte
cmp = lua.eval("""function(ns)
  local A = ns.Analysis
  local s = { id = 999001, netExp = 0 }
  local real = A.Get
  A.Get = function(id) if id == 999001 then return s end return real(id) end
  AHLedgerDB.items[999001] = { n = "Test", s = 100 }
  local out = {}
  for _, net in ipairs({ 150, 105, 95, 80 }) do s.netExp = net; out[#out + 1] = ns.Bags.Compare(999001).kind end
  AHLedgerDB.items[999001].s = 0; s.netExp = 50
  out[#out + 1] = ns.Bags.Compare(999001).kind
  local noPnj = ns.Bags.CompareText(ns.Bags.Compare(999001))
  -- pastille : Daylight UI simulé
  AHLedgerDB.items[999001].s = 100; s.netExp = 150
  local painter
  local holder = { CreateTexture = function()
    local t = mock(); t.shown = false
    t.Show = function(self) self.shown = true end; t.Hide = function(self) self.shown = false end
    t.SetColorTexture = function(self, r, g, b) self.rgb = { r, g, b } end
    return t end }
  DaylightUI = { API = { major = 1, Skin = function() end, Text = function() return mock() end, Button = function() return mock() end,
    Close = function() end, Colors = function() return {} end, Attach = function() return holder end,
    For = function() return { Paint = function(kind, fn) painter = { kind, fn } end } end } }
  ns.Look.me = nil
  ns.BagMarks.started = nil
  local started = ns.BagMarks.Start()
  local slot = {}
  local info = { bag = 0, slot = 1, itemID = 999001 }
  AHLedgerDB.opt = AHLedgerDB.opt or {}
  AHLedgerDB.opt.bagMarks = "ah"
  ns.ahOpen = false
  painter[2](slot, {}, info)
  local closed = ns.BagMarks.slots[slot] and ns.BagMarks.slots[slot].dot.shown or false
  ns.ahOpen = true
  ns.BagMarks.Refresh()
  local m = ns.BagMarks.slots[slot]
  local openShown, g = m.dot.shown, m.dot.rgb[2]
  s.netExp = 50; ns.BagMarks.Refresh()
  local red = m.dot.rgb[1] == 1 and m.dot.rgb[2] < 0.5
  ns.ahOpen = false; ns.BagMarks.Refresh()
  local hidden = not m.dot.shown
  AHLedgerDB.opt.bagMarks = nil; ns.BagMarks.Refresh()           -- par défaut : toujours, même HV fermée
  hidden = hidden and m.dot.shown
  DaylightUI = nil; ns.Look.me = nil; A.Get = real; AHLedgerDB.items[999001] = nil
  return out[1], out[2], out[3], out[4], out[5], noPnj, started, painter[1], closed, openShown, g, red, hidden
end""")(ns)
print("HV/PNJ :", cmp)
assert cmp[:5] == ("ah", "same", "same", "vendor", "ah"), cmp
assert cmp[6] is True and cmp[7] == "bagslot", cmp
assert cmp[8] is False and cmp[9] is True and cmp[10] == 1 and cmp[11] is True and cmp[12] is True, cmp
print("OK : HV ou PNJ, pastilles des sacs")

# Flip HV : revendre tout de suite ou stocker ? Creux et rebonds appris de l'historique,
# reventes réelles rapprochées des achats (courriers d'HV)
rb = lua.eval("""function(ns)
  local R, A = ns.Rebound, ns.Analysis
  -- série : prix habituel 100, creux à 80 le jour 11, remonté à 97 le jour 13 ;
  -- puis creux à 70 le jour 20 qui ne remonte jamais (jours 20 à 40)
  local series = {}
  for d = 1, 19 do series[d] = 100 end
  series[11], series[12], series[13] = 80, 85, 97
  for d = 20, 40 do series[d] = 70 end
  local ev, open = R.Events(series, 40)
  local e1, e2 = ev[1], ev[2]
  -- comptage persistant : une seule fois, même si on recalcule le lendemain
  local db = { hist = { [999002] = {} }, days = {} }
  local saved = R.Series
  R.Series = function() return series end
  R.Update(db, 41); R.Update(db, 41); R.Update(db, 42)
  R.Series = saved
  local g = R.Get(db, 999002)
  -- flips : carnet entièrement sous le prix habituel (marché bas) ; rebonds inconnus puis connus
  local s = { id = 999002, name = "Test", realPrice = 1000, avg7 = 1000, perDay = 40, deposit = 0, sellThrough = 0.9 }
  local low = { levels = { { 500, 30 }, { 520, 200 } } }
  local unknown = { ref = 1000, n = 0, ok = 0, rate = 0.5, known = false }
  local known = { ref = 1000, n = 6, ok = 5, rate = 6 / 8, wait = 3, slow = 5, known = true }
  local now0 = A.FlipFor(s, low, false)
  local fU = A.FlipFor(s, low, unknown)
  local fK = A.FlipFor(s, low, known)
  s.trend = -0.05
  local fDown = A.FlipFor(s, low, unknown)
  local fDownK = A.FlipFor(s, low, known)
  s.trend = nil
  -- un seul vendeur brade, le reste du carnet est au prix habituel : tout de suite
  local fNow = A.FlipFor(s, { levels = { { 500, 30 }, { 1000, 200 } } }, known)
  -- reventes réelles : 10 achetés à 50 le jour 0, 4 + 6 revendus 2 et 4 jours plus tard
  local ldb = ns.Ledger.DB()
  local savedL = ldb.ledger
  local t0 = 1000000
  ldb.ledger = {
    { k = "bought", id = 999002, c = 10, g = 500, t = t0 },
    { k = "sold", id = 999002, c = 4, g = 400, cut = 20, t = t0 + 2 * 86400 },
    { k = "sold", id = 999002, c = 6, g = 600, cut = 30, t = t0 + 4 * 86400 },
    { k = "sold", id = 999003, c = 3, g = 300, t = t0 },
  }
  local h = ns.Ledger.Holds()
  ldb.ledger = savedL
  return e1.ok, e1.wait, e1.start, e2.ok, e2.start, open, g.n, g.ok, g.wait, g.known,
         now0, fU.kind, fU.qty, fU.resale, fK.qty, A.FlipWhen(fK), fK.profit < fK.ifUp, fK.profit > fK.ifDown,
         fDown, fDownK and fDownK.kind, fNow.kind, A.FlipWhen(fNow),
         h[999002].units, h[999002].days, h[999002].profit, h[999003]
end""")(ns)
print("Rebonds / flips à stocker :", rb)
assert rb[0] is True and rb[1] == 2 and rb[2] == 11, rb          # creux du jour 11 remonté en 2 j
assert rb[3] is False and rb[4] == 20 and rb[5] is None, rb      # creux du jour 20 raté après 14 j
assert rb[6] == 2 and rb[7] == 1 and rb[8] == 2 and rb[9] is False, rb  # compté une seule fois
assert rb[10] is None, rb                                        # rien à revendre tout de suite
assert rb[11] == "stock" and rb[12] == 20 and abs(rb[13] - 950) < 1e-6, rb  # inconnu : demi-journée de ventes
assert rb[14] == 80 and rb[15] == "stocker ~3 j (75%)" and rb[16] and rb[17], rb
assert rb[18] is None and rb[19] == "stock", rb                  # marché en baisse : seulement si l'objet remonte
assert rb[20] == "now" and rb[21] == "tout de suite", rb
assert rb[22] == 10 and abs(rb[23] - 3.2) < 1e-9 and abs(rb[24] - 45) < 1e-9 and rb[25] is None, rb

# Faux creux : marché qui s'effondre (cas réel du Tissu runique sur Forever, 68 pa → 6 pa en 2 semaines).
# Ni « à stocker » au prix d'avant la chute, ni achat de tout le carnet pour « tester ».
rc = lua.eval("""function(ns)
  local R, A = ns.Rebound, ns.Analysis
  local saved = R.Series
  local db = { hist = {}, rebound = {} }
  local s = { id = 14047, name = "Runecloth", realPrice = 634, avg7 = 625, perDay = 11000, deposit = 60, sellThrough = 0.99 }
  local book = { levels = { { 599, 298 }, { 600, 102 }, { 628, 476 }, { 634, 556 }, { 699, 66 }, { 900, 2 } } }
  -- 1) creux de 10 jours sans remonter : nouveau prix habituel
  local old = { [100] = 7752, [101] = 3419, [102] = 2957, [103] = 1759, [105] = 757, [106] = 666,
                [109] = 644, [112] = 594, [113] = 655 }
  R.Series = function() return old end
  local o1 = R.Now(db, 14047, 113)
  local f1 = A.FlipFor(s, book, o1)
  -- 2) creux de 2 jours qui continue de baisser
  local young = { [100] = 1000, [101] = 1000, [102] = 1000, [103] = 1000, [104] = 800, [105] = 650, [106] = 500 }
  R.Series = function() return young end
  local o2 = R.Now(db, 14047, 106)
  -- 3) creux de 2 jours qui se stabilise : reste à stocker, mais petit achat de test
  local flat = { [100] = 1000, [101] = 1000, [102] = 1000, [103] = 1000, [104] = 600, [105] = 610, [106] = 605 }
  R.Series = function() return flat end
  local o3 = R.Now(db, 14047, 106)
  R.Series = saved
  local s3 = { id = 14047, name = "Runecloth", realPrice = 605, avg7 = 605, perDay = 11000, deposit = 0, sellThrough = 0.9 }
  local f3 = A.FlipFor(s3, { levels = { { 500, 5000 } } }, o3)
  -- 4) objet cher : le plafond en or limite le test
  local s4 = { id = 1, name = "Cher", realPrice = 42000, avg7 = 42000, perDay = 100, deposit = 0, sellThrough = 0.9 }
  local f4 = A.FlipFor(s4, { levels = { { 40000, 100 } } }, { ref = 100000, n = 0, ok = 0, rate = 0.5, known = false })
  return o1 and o1.settled, o1 and o1.dipSince, o1 and o1.ref, f1,
         o2 and o2.dipSince, o2 and o2.dipTrend, A.FlipFor(s, book, o2),
         o3 and o3.settled, o3 and o3.dipTrend, f3 and f3.kind, f3 and f3.qty,
         f4 and f4.qty, f4 and f4.cost
end""")(ns)
print("Faux creux :", rc)
assert rc[0] is True and rc[1] is None and rc[2] < 800 and rc[3] is None, rc   # prix habituel = celui d'aujourd'hui
assert rc[4] == 2 and rc[5] < -0.03 and rc[6] is None, rc                      # chute en cours : rien à stocker
assert not rc[7] and rc[8] is not None and rc[8] > -0.03, rc
assert rc[9] == "stock" and rc[10] == 20, rc                                    # test : 20 unités, pas 5 500
assert rc[11] == 5 and rc[12] <= 200000, rc                                     # test : 20 po au plus
print("OK : faux creux (marché qui s'effondre), achats de test plafonnés")

# Meilleur jour de la semaine : prix +10 % un jour sur 7, sur 5 semaines
wd = lua.eval("""function(ns)
  local series, base = {}, 20000
  local target
  for d = base, base + 34 do
    local w = tonumber(date("%w", d * 86400 + 43200))
    target = target or w
    series[d] = (w == target) and 110 or 100
  end
  local r = ns.Rebound.Weekday(series)
  return r and r.day == target, r and r.name, r and r.gain > 0.05
end""")(ns)
print("Meilleur jour :", wd)
assert wd[0] is True and wd[2] is True, wd
print("OK : flips tout de suite / à stocker, rebonds, reventes réelles")

# Affichage d'un flip à stocker : infobulle et rapport
disp = lua.eval("""function(ns)
  local A = ns.Analysis
  local real = A.FlipFor
  A.FlipFor = function(s, book)
    if s.id ~= 4306 then return nil end
    return { kind = "stock", id = 4306, s = s, name = s.name, qty = 12, cost = 6000, maxBuy = 500, resale = 950,
             resaleNow = 520, ifUp = 5400, ifDown = -300, profit = 3900, roi = 0.65, rate = 0.75, wait = 3, slow = 5,
             events = 6, recovered = 5, known = true, weekday = { name = "mardi", gain = 0.08 }, days = 3.3 }
  end
  local db = ns.realmDB()
  db.book = db.book or {}
  local savedBook = db.book[4306]
  db.book[4306] = "2,500|500:12 950:40"
  advance(10)
  ns.ahOpen = true
  TT = {}
  GameTooltip.GetItem = function() return 'Silk', '|Hitem:4306::::|h' end
  GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
  ns.ahOpen = false
  local text = ns.Export.Build()
  db.book[4306] = savedBook
  A.FlipFor = real
  return text
end""")(ns)
tt = [strip(re.sub(r"\|T[^|]*\|t", "", x)) for x in lua.eval("TT").values()]
print("\n".join(x for x in tt if "stock" in x or "creux" in x or "jour" in x))
assert any(x.startswith("Flip à stocker : acheter 12") for x in tt), tt
assert any("5 creux sur 6 remontés, en ~3 j" in x for x in tt), tt
assert any("Meilleur jour pour vendre : mardi" in x for x in tt), tt
d = strip(disp)
assert "[à stocker]" in d and "5 creux sur 6 remontés" in d and "meilleur jour de vente : mardi" in d, d
print("OK : affichage des flips à stocker")

# Options : infobulle courte hors HV, complète avec Maj, rien si désactivée ; pastilles coupées
modes = lua.eval("""function(ns)
  local function tip()
    advance(10)
    TT = {}
    GameTooltip.GetItem = function() return 'Mageweave', '|Hitem:4338::::|h' end
    GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
    return table.concat(TT, "\\n")
  end
  ns.ahOpen = false
  local compact = tip()
  IsShiftKeyDown = function() return true end
  local shift = tip()
  IsShiftKeyDown = nil
  ns.ahOpen = true
  local atAH = tip()
  ns.Options.Set("ttAH", "compact")
  local ahCompact = tip()
  ns.ahOpen = false
  ns.Options.Set("ttAway", "off")
  local off = tip()
  ns.Options.Set("bagMarks", "off")
  ns.ahOpen = true
  local mark = ns.BagMarks.KindFor(4338)
  AHLedgerDB.opt = nil
  ns.ahOpen = false
  local markBack = ns.BagMarks.KindFor(4338)             -- par défaut : affichée même HV fermée
  AHLedgerDB.opt = { bagMarks = false }                 -- ancienne case décochée = jamais
  markBack = markBack and ns.BagMarks.KindFor(4338) == nil and markBack
  ns.Options.Show()
  return compact, shift, atAH, ahCompact, off, mark, markBack, ns.Options.window ~= nil
end""")(ns)
compact, shift, atAH, ahCompact, off = (strip(re.sub(r"\|T[^|]*\|t", "", m)) for m in modes[:5])
print("Infobulle courte :\n" + compact)
cl = compact.split("\n")
assert cl[0] == "AHLedger = Maj : détails" and len(cl) <= 3, cl
assert any(x.startswith("HV /u = ") for x in cl) and not any(x.startswith("Données") for x in cl), cl
assert "Données : " in shift and "Tes 30 : " in shift, shift
assert "Données : " in atAH and "Données : " not in ahCompact and "HV /u = " in ahCompact, ahCompact
assert off == "", off
assert modes[5] is None and modes[6] is not None and modes[7], modes
print("OK : options d'infobulle et de pastilles")

# Fabriquer plutôt que vendre brut : un composant qui vaut plus transformé
up = lua.eval("""function(ns)
  local A, P = ns.Analysis, ns.Prof
  local realGet, realRecipes = A.Get, P.Recipes
  local stats = {
    [999201] = { id = 999201, netExp = 100, perDay = 20, realPrice = 110, price = 110, minNow = 110, signals = {} },  -- composant : 1 pa brut
    [999202] = { id = 999202, netExp = 1000, perDay = 8, surePerDay = 8, realPrice = 1050, price = 1050,
                 deposit = 0, sellThrough = 1, signals = {} }, -- objet fabriqué : 10 pa net (1050 − 5 %)
    [999203] = { id = 999203, netExp = 30, minNow = 30, perDay = 50, signals = {} },       -- autre composant : 30c
  }
  A.Get = function(id) return stats[id] or realGet(id) end
  P.Recipes = function() return { test = { [999202] = { n = "Bracelet", r = { [999201] = 3, [999203] = 2 } } } } end
  AHLedgerDB.items[999201] = { n = "Cuir", s = 20 }
  AHLedgerDB.items[999202] = { n = "Bracelet", s = 200 }
  local best = A.CraftUp(999201)
  local adv = ns.Bags.Advise(999201, 9)
  advance(10)
  TT = {}
  GameTooltip.GetItem = function() return 'x', '|Hitem:999201::::|h' end
  GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
  local tip = table.concat(TT, "\\n")
  -- objet fabriqué qui ne vaut presque rien : pas d'alerte
  stats[999202].netExp, stats[999202].price = 300, 316
  local none, weak = A.CraftUp(999201)
  A.Get, P.Recipes = realGet, realRecipes
  AHLedgerDB.items[999201], AHLedgerDB.items[999202] = nil, nil
  return best.perUnit, best.raw, best.out, adv.action, tip, none, weak and weak.gain, A.AH_CUT
end""")(ns)
perUnit, raw, out, action, tip, none, weakGain, upCut = up
tip = strip(re.sub(r"\|T[^|]*\|t", "", tip))
print("Fabriquer plutôt :", perUnit, raw, action, [l for l in tip.split("\n") if "plutôt" in l])
assert abs(perUnit - (1050 * (1 - upCut) - 60) / 3) < 0.01 and raw == 100 and out == 999202, up
assert action == "Fabriquer", action
assert "Fabrique-le plutôt : Bracelet" in tip, tip
assert none is None and weakGain < 0, up
print("OK : fabriquer plutôt que vendre le composant")

# Fenêtre : position dans la liste au pied de page, tableau vide expliqué, flèche de tri
ui = lua.eval("""function(ns)
  local UI = ns.UI
  UI.liquidOnly, UI.cat = false, 1
  UI.content.GetHeight = function() return 78 + 36 + 5 * 20 end -- 4 lignes visibles
  UI.SetMode("market")
  local footer, emptyHidden = UI.footer.text, not UI.empty.shown
  local realFlips = ns.Analysis.Flips
  ns.Analysis.Flips = function() return {} end
  UI.SetMode("flip")
  local empty, emptyShown = UI.empty.text, UI.empty.shown
  ns.Analysis.Flips = realFlips
  UI.content.GetHeight = nil
  UI.liquidOnly = true
  UI.SetMode("market")
  return footer, emptyHidden, empty, emptyShown, UI.headers[10].arrow.shown, UI.helpText ~= nil
end""")(ns)
footer, emptyHidden, empty, emptyShown, sortArrow, hasHelp = ui
print("Pied de page :", strip(footer)); print("Vide :", empty)
assert "lignes 1–4 sur" in str(footer), footer
assert emptyHidden and emptyShown and "flip" in str(empty), ui
assert sortArrow and hasHelp, ui
print("OK : fenêtre (défilement, tableau vide, tri)")

# Bouton de la minicarte : affiché par défaut, au bord de la carte (carrée ou ronde), masquable
mm = lua.eval("""function(ns)
  Minimap = mock()
  Minimap.GetWidth = function() return 140 end
  Minimap.GetHeight = function() return 140 end
  Minimap.GetFrameLevel = function() return 2 end
  local MM = ns.MinimapButton
  MM.button = nil
  fire("PLAYER_LOGIN")
  local b = MM.button
  local pos = {}
  b.SetPoint = function(_, _, _, _, x, y) pos.x, pos.y = x, y end
  b.GetWidth = function() return 31 end
  GetMinimapShape = function() return "SQUARE" end
  MM.Place(180)
  local sx, sy = pos.x, pos.y
  GetMinimapShape = nil
  MM.Place(90)
  local rx, ry = pos.x, pos.y
  local shown = b.shown
  ns.Options.Set("minimap", false)
  local hidden = not b.shown
  ns.Options.Set("minimap", true)
  local back = b.shown
  AHLedgerDB.opt.minimap = nil
  Minimap, MM.button = nil, nil
  return shown, hidden, back, sx, sy, rx, ry
end""")(ns)
shown, hidden, back, sx, sy, rx, ry = mm
print("Minicarte :", mm)
assert shown and hidden and back, mm
assert abs(sx + (70 - 17.5)) < 0.01 and abs(sy) < 0.01, mm   # carrée : bord gauche, à l'intérieur
assert abs(rx) < 0.01 and abs(ry - 80) < 0.01, mm           # ronde : sur l'anneau, en haut
print("OK : bouton de la minicarte")

# Fiabilité des conseils : la simulation de 14 jours a noté et vérifié des conseils
sim = lua.eval("""function(ns)
  local rows = ns.Track.Summary()
  local checked, open = 0, 0
  for _, s in ipairs(rows) do checked, open = checked + s.checked, open + s.open end
  return checked, open, #ns.Track.Lines()
end""")(ns)
print("Fiabilité (simulation) :", sim)
assert sim[0] > 0 and sim[2] > 0, sim

# Fiabilité : scénarios contrôlés (un flip qui tient, un qui s'effondre, un à stocker qui remonte, un suivi réel)
tr = lua.eval("""function(ns)
  local T, A = ns.Track, ns.Analysis
  local db = { book = {} }
  local savedF, savedV = A.Flips, A.VendorFlips
  local flips = {
    { id = 1, kind = "now", qty = 10, maxBuy = 500, cost = 5000, resale = 999, profit = 4000 },
    { id = 2, kind = "now", qty = 10, maxBuy = 500, cost = 5000, resale = 999, profit = 4000 },
    { id = 3, kind = "stock", known = false, qty = 5, maxBuy = 400, cost = 2000, resale = 950, profit = 1000 },
  }
  A.Flips = function() return flips end
  A.VendorFlips = function() return {} end
  local t0 = 2000000
  local function book(id, str) db.book[id] = str end
  -- scan 0 : les conseils sont notés
  book(1, "0,0|500:10;1000:20"); book(2, "0,0|500:10;1000:20"); book(3, "0,0|400:5;600:50")
  T.OnScan(db, t0, nil)
  flips = {}
  local sold = function(price, units) return { lv = { { price, units } } } end
  -- scans suivants : objet 1 tient à 1000 et part à ce prix ; objet 2 bradé à 700 ; objet 3 remonte à 1000 au jour 4
  for d = 1, 4 do
    book(1, "0,0|1000:20"); book(2, "0,0|700:40")
    book(3, d < 4 and "0,0|600:50" or "0,0|1000:30")
    T.OnScan(db, t0 + d * 86400 - 3600, { [1] = sold(1000, 4), [2] = sold(700, 20), [3] = d == 4 and sold(1000, 6) or nil })
  end
  -- objet 1 : tu as suivi (10 achetés à 50 pa juste après le conseil, 10 revendus à 1000)
  local ldb = ns.Ledger.DB()
  local savedL = ldb.ledger
  ldb.ledger = {
    { k = "bought", id = 1, c = 10, g = 5000, t = t0 + 600 },
    { k = "sold", id = 1, c = 10, g = 10000, cut = 500, t = t0 + 2 * 86400 },
    { k = "bought", id = 2, c = 5, g = 2500, t = t0 + 3 * 86400 },  -- trop tard : pas un suivi
  }
  local rows = T.Summary(db)
  ldb.ledger = savedL
  A.Flips, A.VendorFlips = savedF, savedV
  local by = {}
  for _, s in ipairs(rows) do by[s.key] = s end
  local done = {}
  for _, r in ipairs(db.track.done) do done[r.id] = r end
  return by.now.checked, by.now.ok, by.now.priceOk, by.now.followed, by.now.realGain,
         done[1].status, done[2].status, done[2].gain, done[3] and done[3].status, by.stockTest.ok,
         T.Achievable({ k = "now", qty = 10, buy = 500 }, { levels = { { 500, 4 }, { 520, 10 }, { 900, 3 } } })
end""")(ns)
print("Fiabilité (scénarios) :", tr)
assert tr[0] == 2 and tr[1] == 1 and tr[2] == 1, tr       # 2 flips vérifiés : 1 réussi
assert tr[3] == 1 and abs(tr[4] - 4500) < 1e-6, tr        # suivi réel : 10 × (950 − 500)
assert tr[5] == "ok" and tr[6] == "ko" and tr[7] < 4000, tr
assert tr[8] == "ok" and tr[9] == 1, tr                   # à stocker : remonté et écoulé, clos tôt
assert tr[10] == 520, tr                                  # 10 unités achetées : 4 à 500, 6 à 520 → reste 520
print("OK : fiabilité des conseils")

# --- Relistes et annulations : pas des ventes (Scan.Diff) ---
rl = lua.eval("""function(ns)
  local S, H = ns.Scan, ns.History
  local function sig(id, count, buyout, tl) return id .. ":" .. count .. ":" .. buyout .. ":?", tl end
  local function set(list)
    local t = {}
    for _, e in ipairs(list) do
      local k = e[1] .. ":" .. e[2] .. ":" .. e[3] .. ":?"
      local s = t[k]
      if s then s.c = s.c + 1 else t[k] = { c = 1, tl = e[4] or 4 } end
    end
    return t
  end
  -- Tissu (piles de 20) : 2 piles à 10 c/u, 1 à 12 c/u, 1 à 15 c/u.
  -- Une pile à 10 part (achetée), celle à 15 part alors qu'une pile à 10 reste : annulée.
  local prev = set({ { 1, 20, 200 }, { 1, 20, 200 }, { 1, 20, 240 }, { 1, 20, 300 } })
  local cur  = set({ { 1, 20, 200 }, { 1, 20, 240 }, { 1, 20, 190 } })   -- 190 = remise en vente
  local d = S.Diff(prev, cur, 3600)[1]
  -- Équipement (pièces uniques) : la pièce chère part alors qu'une moins chère reste.
  -- L'acheteur choisit ses statistiques : c'est une vente.
  local gp = set({ { 2, 1, 5000 }, { 2, 1, 9000 } })
  local gc = set({ { 2, 1, 5000 } })
  local g = S.Diff(gp, gc, 3600)[2]
  -- Tout le bas du marché acheté d'un coup : rien d'annulé
  local bp = set({ { 3, 20, 200 }, { 3, 20, 220 }, { 3, 20, 400 } })
  local bc = set({ { 3, 20, 400 } })
  local b = S.Diff(bp, bc, 3600)[3]
  -- Historique : les anciens formats (6 et 7 champs) se lisent encore, le nouveau garde « annulé »
  local h6, h7 = H.parse("1,2,3,4,5,6"), H.parse("1,2,3,4,5,6,7")
  local h8 = H.parse("1,2,3,4,5,6,7,8")
  return d.sold, d.can, d.soldVal, #d.lv, d.posted, g.sold, g.can, b.sold, b.can,
         h6.can, h7.exp, h7.can, h8.exp, h8.can
end""")(ns)
print("Relistes :", rl)
assert rl[0] == 20 and rl[1] == 20 and rl[2] == 200 and rl[3] == 1 and rl[4] == 20, rl
assert rl[5] == 1 and rl[6] == 0, rl          # équipement : vendu, pas annulé
assert rl[7] == 40 and rl[8] == 0, rl         # bas du marché acheté : vendu
assert rl[9] == 0 and rl[10] == 7 and rl[11] == 0 and rl[12] == 7 and rl[13] == 8, rl
print("OK : relistes et annulations écartées des ventes")

# --- Fiabilité : artisanat et conseils des sacs ---
tc = lua.eval("""function(ns)
  local T, A, B = ns.Track, ns.Analysis, ns.Bags
  local db = { book = {} }
  local saved = { A.Flips, A.VendorFlips, A.Crafts, B.Advice }
  A.Flips = function() return {} end
  A.VendorFlips = function() return {} end
  -- 11 : potion rentable (coût 600 par fabrication, revente 1000) ; 12 : potion qui s'effondre
  local crafts = {
    { id = 11, made = 1, cost = 600, profit = 350, sellTo = "HV", vol = 4, s = { price = 1000 } },
    { id = 12, made = 1, cost = 600, profit = 350, sellTo = "HV", vol = 4, s = { price = 1000 } },
    { id = 13, made = 1, cost = 600, profit = -50, sellTo = "HV", vol = 4, s = { price = 600 } }, -- pas rentable : ignorée
  }
  -- 21 : à vendre à l'HV à 800 (PNJ 100) ; 22 : PNJ conseillé à 300, l'HV part à 900 ; 23 : PNJ à 300, l'HV reste à 280
  local bags = {
    { id = 21, action = "Vendre HV", post = 800, unit = 760, postQty = 5, count = 5, vendor = 100 },
    { id = 22, action = "PNJ", unit = 300, count = 10, vendor = 300, s = {} },
    { id = 23, action = "PNJ", unit = 300, count = 10, vendor = 300, s = {} },
    { id = 24, action = "Garder", unit = 500, count = 3, vendor = 50, s = {} },                  -- pas suivi
  }
  A.Crafts = function() return crafts end
  B.Advice = function() return bags end
  local t0 = 3000000
  local function book(id, str) db.book[id] = str end
  T.OnScan(db, t0, nil)
  crafts, bags = {}, {}
  local function sold(price, units) return { lv = { { price, units } } } end
  for d = 1, 3 do
    book(11, "0,0|1000:30"); book(12, "0,0|500:40")
    book(21, "0,0|820:20"); book(22, "0,0|900:20"); book(23, "0,0|280:50")
    T.OnScan(db, t0 + d * 86400, { [11] = sold(1000, 5), [12] = sold(500, 10), [21] = sold(820, 1),
                                   [22] = sold(900, 10), [23] = sold(280, 20) })
  end
  A.Flips, A.VendorFlips, A.Crafts, B.Advice = saved[1], saved[2], saved[3], saved[4]
  local done = {}
  for _, r in ipairs(db.track.done) do done[r.id] = r end
  local by = {}
  for _, s in ipairs(T.Summary(db)) do by[s.key] = s end
  return done[11].status, done[11].qty, done[12].status, done[13] == nil, done[21].status, done[21].gain,
         done[22].status, done[22].gain, done[23].status, done[23].gain, done[24] == nil,
         by.craft.checked, by.bagAH.ok, by.bagNPC.checked, by.bagNPC.ok, A.AH_CUT
end""")(ns)
print("Fiabilité artisanat et sacs :", tc)
assert tc[0] == "ok" and tc[1] == 4 and tc[2] == "ko" and tc[3], tc   # 4 = vol 4/j × 1 jour
cut = tc[15]
assert tc[4] == "ko", tc                                               # 3 écoulés sur 5 : pas écoulé
assert abs(tc[5] - (5 * 800 * (1 - cut) - 500)) < 1e-6, tc             # gain vs PNJ : 5 × net(800) − 5 × 100
assert tc[6] == "ko" and abs(tc[7] - (10 * 300 - 10 * 899 * (1 - cut))) < 1e-6, tc  # PNJ à tort : or manqué
assert tc[8] == "ok" and tc[9] == 0 and tc[10], tc                     # PNJ juste ; « Garder » pas suivi
assert tc[11] == 2 and tc[12] == 0 and tc[13] == 2 and tc[14] == 1, tc
print("OK : fiabilité de l'artisanat et des conseils des sacs")

# Opportunités : recettes rentables (apprises ou non) et marchés où sous-coter
opp = lua.eval("""function(ns)
  local A = ns.Analysis
  -- recette fictive très rentable, non apprise, dans un métier que le personnage n'a pas
  local pick
  for _, s in ipairs(A.All().list) do
    if s.perDay and s.perDay >= 1 and s.realPrice and s.trust ~= "bad" and s.ev.maxSold and s.ev.maxSold >= 1.2 * s.price
       and (not pick or s.price > pick.price) then pick = s end
  end
  local cheap
  for _, s in ipairs(A.All().list) do
    if s.id ~= pick.id and (s.minNow or s.price) * 4 < pick.netExp and (not cheap or s.price < cheap.price) then cheap = s end
  end
  ns.RecipeDB.Register("opp", { Recipes = function(prof)
    if prof ~= "alchemy" then return {} end
    return { { out = pick.id, prof = prof, r = { [cheap.id] = 1 }, levels = { 50, 60, 70, 80 },
               source = { kind = "trainer", cost = 1000, where = "Maître" } } }
  end })
  local rec
  for _, e in ipairs(ns.Opp.Recipes()) do if e.id == pick.id and e.prof == "alchemy" then rec = e end end
  -- sous-coter : l'enchère la moins chère à 1,5 × le prix habituel
  local db = ns.realmDB()
  local saved = db.book[pick.id]
  local low = math.floor(pick.ev.maxSold)
  db.book[pick.id] = ns.Scan.PackBook({ { low, 3 }, { low * 2, 10 } }, 3, 400)
  ns.dataVersion = ns.dataVersion + 1
  local found
  for _, e in ipairs(ns.Opp.Undercuts()) do if e.id == pick.id then found = e end end
  -- ma propre enchère est déjà la moins chère : rien à sous-coter
  local c = ns.Prof.Char()
  local savedAuc = c.auctions
  c.auctions = { t = 0, list = { { id = pick.id, qty = 1, unit = low - 5 } } }
  ns.dataVersion = ns.dataVersion + 1
  local mineSkipped = true
  for _, e in ipairs(ns.Opp.Undercuts()) do if e.id == pick.id then mineSkipped = false end end
  c.auctions = savedAuc
  ns.UI.SetMode("recipes"); local r1 = ns.UI.rows[1].shown
  ns.UI.SetMode("undercut")
  db.book[pick.id] = saved
  ns.RecipeDB.providers.opp = nil
  for i, n in ipairs(ns.RecipeDB.order) do if n == "opp" then table.remove(ns.RecipeDB.order, i) end end
  ns.dataVersion = ns.dataVersion + 1
  return rec and rec.access or false, rec and rec.accessOrder, rec and rec.profit, rec and rec.learnCost,
         found and found.post == math.floor((low - 100) / 100) * 100, found and found.premium, found and found.qty, mineSkipped, r1
end""")(ns)
print("Opportunités :", [strip(v) for v in opp])
assert opp[0] and "métier non appris" in strip(opp[0]) and opp[1] == 4 and opp[2] > 0 and opp[3] == 1000, opp
assert opp[4] is True and opp[5] > 0.1 and opp[6] >= 1 and opp[7] is True and opp[8], opp
show_ui("recipes"); show_ui("undercut")
print("OK : onglets Rentables et Sous-coter")

# Fiabilité d'un prix (cas réel du Heavy Shortbow) : 3 vendus à ~7 pa, puis des annonces à 22 pa qui
# restent sans acheteur et une de mes enchères expirée. Le prix affiché (18 pa) ne doit pas servir.
tr = lua.eval("""function(ns)
  local db, T, A = ns.realmDB(), ns.Trust, ns.Analysis
  local day = ns.History.today()
  local id = 3036
  AHLedgerDB.items[id] = { n = "Heavy Shortbow", s = 515, q = 2, c = 2 }
  db.hist[id] = { [day - 1] = "1450,2,18,3,2,2150", [day] = "11070,6,19,0,2,0,0" }
  db.days[day - 1] = db.days[day - 1] or { obs = 4.7 * 3600, scans = 2 }
  -- annonces à 22 pa restées 12 h : notées « l » par Trust.Record
  local t0 = time()
  local prev = { ["3036:1:2290:?"] = { c = 1, tl = 4, f = t0 - 13 * 3600 } }
  local cur = { ["3036:1:2290:?"] = { c = 1, tl = 4 } }
  T.Record(db, t0, {}, prev, cur)
  local lingered = db.outcomes[id] ~= nil and cur["3036:1:2290:?"].r == 1
  ns.dataVersion = ns.dataVersion + 1
  local s = A.Get(id)
  local r1 = { s.capped, s.price, s.listedPrice, s.ev.maxSold, s.trust }
  local l2, why2 = T.Check(s, 1600)                -- poster à 16 pa : non tenu
  -- ma propre enchère expirée, jamais vendue
  table.insert(ns.Ledger.DB().ledger, { k = "expired", id = id, t = time(), c = 1, n = "Heavy Shortbow" })
  ns.dataVersion = ns.dataVersion + 1
  local one = ns.Bags.Advise(id, 1)                -- 1 expiré, mais 3 ventes vues à ~7 pa : vendre, pas plus cher
  table.insert(ns.Ledger.DB().ledger, { k = "expired", id = id, t = time(), c = 1, n = "Heavy Shortbow" })
  ns.dataVersion = ns.dataVersion + 1
  local s2 = A.Get(id)
  local adv = ns.Bags.Advise(id, 1)
  table.remove(ns.Ledger.DB().ledger); table.remove(ns.Ledger.DB().ledger)
  db.hist[id], db.outcomes[id] = nil, nil
  ns.dataVersion = ns.dataVersion + 1
  return lingered, r1[1], r1[2], r1[3], r1[4], r1[5], l2, why2, s2.trust, s2.trustWhy, adv.action, adv.why,
         one.action, one.post
end""")(ns)
print("Fiabilité du prix (Heavy Shortbow) :", tr)
assert tr[0] is True and tr[1] is True and abs(tr[2] - 2150 / 3) < 1 and tr[3] > 1800, tr   # plafonné à 7 pa 17
assert tr[6] == "bad" and "au-dessus" in tr[7], tr
assert tr[8] == "bad" and "expiré chez toi ×2" in tr[9] and tr[10] == "PNJ", tr
assert tr[12] == "Vendre HV" and tr[13] <= 717, tr
print("OK : fiabilité d'un prix (prix affiché non tenu, expiré chez toi)")

# Pic de prix (cas réel des Pilferer's Gloves, 24/11/2026) : ~50 pa d'habitude, 1 po 66 aujourd'hui avec
# 9 « ventes » à 1 po 66. Vendre ce qu'on a : prix du jour. Fabriquer / acheter : prix habituel.
pk = lua.eval("""function(ns)
  local db, A = ns.realmDB(), ns.Analysis
  local day = ns.History.today()
  local id = 7358
  AHLedgerDB.items[id] = { n = "Pilferer's Gloves", s = 885, q = 2, c = 4 }
  local h = { [day] = "99590,6,106,9,2,149400,0" }
  for k = 1, 4 do h[day - k] = "10000,2,17,1,0,5000"; db.days[day - k] = db.days[day - k] or { obs = 6 * 3600, scans = 2 } end
  db.hist[id] = h
  ns.dataVersion = ns.dataVersion + 1
  local s = A.Get(id)
  local r = { s.spike, s.usual, s.netExp, A.SafeNet(s), table.concat(s.signals, ","), s.price }
  -- le pic tient depuis 5 jours : c'est le nouveau prix
  for k = 1, 4 do h[day - k] = "33200,2,17,1,0,16600" end
  for k = 5, 8 do h[day - k] = "10000,2,17,1,0,5000"; db.days[day - k] = db.days[day - k] or { obs = 6 * 3600, scans = 2 } end
  ns.dataVersion = ns.dataVersion + 1
  local s2 = A.Get(id)
  local settled = { s2.spike, A.SafeNet(s2) }
  -- AHLedger n'a qu'un jour d'avant : l'historique Auctionator complète
  db.hist[id] = { [day] = "99590,6,106,9,2,149400,0", [day - 1] = "14000,2,17,0,7,0" }
  local saved = ns.Bridge.History
  ns.Bridge.History = function() return { { -6, 4500 }, { -4, 5000 }, { -3, 5200 }, { -1, 9900 }, { 0, 16600 } } end
  ns.dataVersion = ns.dataVersion + 1
  local s3 = A.Get(id)
  local ah = { s3.spike, s3.usual }
  ns.Bridge.History = saved
  db.hist[id] = nil
  ns.dataVersion = ns.dataVersion + 1
  return r[1], r[2], r[3], r[4], r[5], r[6], settled[1], settled[2], ah[1], ah[2]
end""")(ns)
print("Pic de prix (Pilferer's Gloves) :", list(pk))
assert pk[0] is True and abs(pk[1] - 5000) < 1 and pk[2] > 12000 and pk[3] < 5000 and "pic" in pk[4], pk
assert pk[6] is None and pk[7] > 13000, pk            # 5 jours au-dessus : plus un pic
assert pk[8] is True and abs(pk[9] - 5100) < 1, pk    # médiane de 4500, 5000, 5200 et 7000 (la veille, AHLedger d'abord)
print("OK : pic de prix (valeur d'investissement au prix habituel)")

# Sacs de Daylight UI 2.2.5 restés invisibles (fondu bloqué à 0) : AHLedger remet l'opacité à 1
us = lua.eval("""function(ns)
  local function win(a)
    local items = { a = a }
    function items:GetAlpha() return self.a end
    function items:SetAlpha(v) self.a = v end
    return { items = items, IsVisible = function() return true end, HookScript = function() end }
  end
  local stuck, moving, fine = win(0), win(0.4), win(1)
  local saved = DaylightUI
  DaylightUI = { GetModule = function() return { ns = { windows = { stuck, moving, fine } } } end }
  ns.BagMarks.HookShow()
  ns.BagMarks.Unstick({ [stuck] = 0, [moving] = 0.2 })   -- deuxième relevé : moving a bougé
  local a1, a2 = stuck.items.a, moving.items.a
  moving.items.a = 0.4
  ns.BagMarks.UnstickSoon(); runTimers()                 -- chemin complet : 1 s puis 0,5 s
  local a3 = moving.items.a
  DaylightUI = saved
  return a1, a2, a3, fine.items.a
end""")(ns)
print("Sacs invisibles :", list(us))
assert us[0] == 1 and abs(us[1] - 0.4) < 1e-9 and us[2] == 1 and us[3] == 1, us
print("OK : sacs invisibles (fondu de Daylight UI bloqué)")

# Fabriquer pour l'HV (cas réel du 24/11/2026) : 2 Lucky Charm + 10 Medium Leather + 2 Fine Thread → Pilferer's
# Gloves. Les gants « valaient » 1 po 66 (pic, ventes surtout des relistes), 33 en rayon, aucune vente sûre le
# dernier jour : ils ne sont pas partis, les Lucky Charm se vendaient dans la journée. Vendre les composants.
pg = lua.eval("""function(ns)
  local db, A, P, T = ns.realmDB(), ns.Analysis, ns.Prof, ns.Track
  local day = ns.History.today()
  local GL, LC, ML, FT = 7358, 5373, 2319, 2321
  local saved = { get = A.Get, rec = P.Recipes, days = {}, flips = A.Flips, vflips = A.VendorFlips, bags = ns.Bags.Advice,
                  min = db.lastMin[GL], book = db.book and db.book[GL], track = db.track }
  for k = 0, 2 do saved.days[k] = db.days[day - k] end
  db.days[day - 2] = { obs = 9 * 3600, scans = 2 }
  db.days[day - 1] = { obs = 9 * 3600, scans = 6 }
  db.days[day] = { obs = 9 * 3600, scans = 3 }
  db.hist[GL] = { [day - 2] = "13938,2,17,0,7,0", [day - 1] = "99590,6,106,9,2,149400,0", [day] = "41999,3,71,0,11,0,0,0" }
  db.book = db.book or {}
  db.book[GL] = "0,0|9799:1;9800:15;9999:2;15000:4;16000:3;16590:2;16600:6"
  db.lastMin[GL] = 9799
  AHLedgerDB.items[GL] = { n = "Pilferer's Gloves", s = 885, q = 2, c = 4 }
  AHLedgerDB.items[LC] = { n = "Lucky Charm", s = 72, q = 1, c = 15 }
  local mats = {
    [LC] = { id = LC, price = 1346, minNow = 1346, realPrice = 1300, netExp = 1240, perDay = 30, surePerDay = 20, signals = {} },
    [ML] = { id = ML, price = 99, minNow = 99, netExp = 90, perDay = 300, signals = {} },
    [FT] = { id = FT, price = 40, minNow = 40, netExp = 35, perDay = 300, signals = {} },
  }
  A.Get = function(id) return mats[id] or saved.get(id) end
  P.Recipes = function() return { leatherworking = { [GL] = { n = "Pilferer's Gloves", m = 1, d = "trivial",
                                   r = { [ML] = 10, [LC] = 2, [FT] = 2 } } } } end
  ns.dataVersion = ns.dataVersion + 1
  local s = A.Get(GL)
  local sale = A.CraftSale(s)
  local craft
  for _, e in ipairs(A.Crafts()) do if e.id == GL then craft = e end end
  local up, upWeak = A.CraftUp(LC)
  -- suivi des conseils : les gants ne sont pas un « Artisanat → HV » à vérifier
  A.Flips, A.VendorFlips, ns.Bags.Advice = function() return {} end, function() return {} end, function() return {} end
  local tdb = { book = {} }
  T.OnScan(tdb, 3000000, nil)
  local tracked = tdb.track and tdb.track.open[GL .. ":craft"] ~= nil
  -- même recette sur un marché sain (20 ventes sûres/j, 4 en rayon, 1 po 20) : fabriquer
  db.hist[GL] = { [day - 2] = "24000,2,8,40,0,480000,0", [day - 1] = "72000,6,24,40,0,480000,0", [day] = "36000,3,12,40,0,480000,0,0" }
  db.book[GL] = "0,0|12000:4"
  db.lastMin[GL] = 12000
  ns.dataVersion = ns.dataVersion + 1
  local healthy = A.CraftSale(A.Get(GL))
  local upOk = A.CraftUp(LC)
  local tdb2 = { book = {} }
  local craft2
  for _, e in ipairs(A.Crafts()) do if e.id == GL then craft2 = e end end
  T.OnScan(tdb2, 3000000, nil)
  local rec2 = tdb2.track and tdb2.track.open[GL .. ":craft"]
  -- remise en état
  A.Get, P.Recipes, A.Flips, A.VendorFlips, ns.Bags.Advice = saved.get, saved.rec, saved.flips, saved.vflips, saved.bags
  for k = 0, 2 do db.days[day - k] = saved.days[k] end
  db.hist[GL], db.book[GL], db.lastMin[GL] = nil, saved.book, saved.min
  AHLedgerDB.items[GL], AHLedgerDB.items[LC] = nil, nil
  ns.dataVersion = ns.dataVersion + 1
  return sale.slow, sale.gross, sale.why, sale.rate, craft.sellTo, craft.slow, craft.daily, up == nil,
         upWeak and upWeak.sellTo, tracked, healthy.slow, upOk and upOk.out, rec2 and rec2.resale, s.price
end""")(ns)
print("Pilferer's Gloves vs Lucky Charm :", list(pg))
assert pg[0] is True and pg[1] <= 9798 and pg[3] == 0, pg       # aucune vente sûre le dernier jour, sous les 97s 99c
assert "se vend peu" in pg[2], pg
assert pg[4] == "PNJ" and pg[5] is True and pg[6] == 0, pg       # l'HV est écartée : rien à gagner par jour
assert pg[7] is True and pg[8] == "PNJ", pg                       # pas de « Fabriquer » pour les Lucky Charm
assert pg[9] is False, pg                                        # pas suivi comme conseil d'artisanat
assert pg[13] > 15000, pg                                        # le prix du jour reste le pic (vendre ce qu'on a)
assert pg[10] is False and pg[11] == 7358, pg                    # marché sain : fabriquer
assert pg[12] is not None and pg[12] <= 11999, pg                # suivi au prix où l'on vend, sous l'enchère la moins chère
print("OK : fabriquer pour l'HV seulement si l'objet partira (ventes sûres, rayon pas saturé)")

# Correction par tes ventes réelles : 4 ventes de soie à 60 % du prix prévu, 2 de tisse-mage au prix prévu
bias = lua.eval("""function(ns)
  local db, A, L = ns.realmDB(), ns.Analysis, ns.Ledger
  local saved = db.ledger
  ns.dataVersion = ns.dataVersion + 1
  local silk0 = A.Get(4306)
  local net0, price0 = silk0.net, silk0.price
  local now = time()
  db.ledger = {}
  for i = 1, 4 do db.ledger[#db.ledger + 1] = { k = "sold", id = 4306, n = "Silk Cloth", c = 10, g = 6000, cut = 300, dep = 0, t = now, pp = 1000 } end
  for i = 1, 2 do db.ledger[#db.ledger + 1] = { k = "sold", id = 4338, n = "Mageweave Cloth", c = 1, g = 500, cut = 25, dep = 0, t = now, pp = 500 } end
  -- un courrier sans prix noté : prix prévu repris de l'historique du jour
  db.ledger[#db.ledger + 1] = { k = "sold", id = 4306, n = "Silk Cloth", c = 1, g = 1, cut = 0, dep = 0, t = now - 99 * 86400 }
  local t = L.BiasTable(db)
  ns.dataVersion = ns.dataVersion + 1
  local s = A.Get(4306)
  local rows = {}
  for _, r in ipairs((L.Summary())) do rows[r.id or r.name] = r end
  local r = { t.n, t.global, t.items[4306].f, t.items[4338].f, s.bias, s.biasSrc, s.net / net0, s.price == price0,
              rows[4306].predicted, rows[4306].gap }
  db.ledger = saved
  ns.dataVersion = ns.dataVersion + 1
  return r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10]
end""")(ns)
print("Correction par tes ventes :", [round(x, 3) if isinstance(x, float) else x for x in bias])
assert bias[0] == 6, bias                                   # la vente sans historique ce jour-là est ignorée
assert 0.75 < bias[1] < 0.95, bias                          # moyenne globale rapprochée de 1
assert 0.6 < bias[2] < 0.8 and bias[3] <= 1.0, bias         # soie corrigée, tisse-mage plafonné à 1
assert abs(bias[4] - bias[2]) < 1e-9 and bias[5] == "objet", bias
assert abs(bias[6] - bias[4]) < 1e-6 and bias[7] is True, bias  # le net baisse, le prix du marché ne bouge pas
assert abs(bias[8] - 1000) < 1e-6 and abs(bias[9] + 0.4) < 1e-6, bias  # bilan : écart vs prix noté à la vente
print("OK : correction par tes ventes réelles")

# --- « Se vend vraiment ? » (Analysis.Sells) ---
sv = lua.eval("""function(ns)
  local A = ns.Analysis
  local function L(s, real) local l, w = A.Sells(s, real); return l end
  return {
    L({ obsHours = 40, surePerDay = 5, recentSurePerDay = 4, sellThrough = 0.8, perDay = 6 }),       -- oui
    L({ obsHours = 40, surePerDay = 0.5, sellThrough = 0.3, perDay = 30 }),                          -- lent
    L({ obsHours = 40, surePerDay = 0, sellThrough = 0.1, perDay = 40 }),                            -- non : que des relistes
    L({ obsHours = 10, surePerDay = 0, perDay = 0 }),                                                -- ? trop tôt
    L({ obsHours = 40, surePerDay = 0, perDay = 0 }, { sold = 4, expired = 1, bought = 0 }),         -- oui : tes ventes
    L({ obsHours = 40, surePerDay = 5, sellThrough = 0.8 }, { sold = 0, expired = 3, bought = 0 }),  -- non : tes expirations
    L({ obsHours = 40, surePerDay = 5, sellThrough = 0.8, stockDays = 12 }),                         -- lent : rayon saturé
    L(nil, nil),                                                                                     -- ? jamais vu
    select(2, A.Sells({ obsHours = 40, surePerDay = 0.4, sellThrough = 0.5, perDay = 40 })),
  }
end""")(ns)
sv = [sv[i] for i in range(1, 10)]
print("Se vend :", sv)
assert sv[:8] == ["yes", "slow", "no", "unknown", "yes", "no", "slow", "unknown"], sv
assert "relistes" in sv[8], sv
print("OK : verdict « se vend » sur ventes sûres, courriers d'abord")

# Infobulle : pas de doublon avec ce que le jeu / Auctionator / Daylight Bags affichent déjà
dup = lua.eval("""function(ns)
  local function tip(short)
    advance(10)
    TT = {}
    IsShiftKeyDown = function() return not short end
    GameTooltip.GetItem = function() return 'Mageweave', '|Hitem:4338::::|h' end
    GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
    IsShiftKeyDown = nil
    return table.concat(TT, "\\n")
  end
  local plain = tip()
  Auctionator.Config = { Options = { AUCTION_TOOLTIPS = "auction_tooltips" }, Get = function() return true end }
  ns.dataVersion = (ns.dataVersion or 0) + 1
  local withAuct = tip()
  local short = tip(true)
  Auctionator.Config = nil
  ns.dataVersion = (ns.dataVersion or 0) + 1
  return plain, withAuct, short
end""")(ns)
plain, withAuct, short = (strip(re.sub(r"\|T[^|]*\|t", "", m)) for m in dup)
print("Courte avec Auctionator :", short)
assert "HV réel /u = 9s 68c" in short and "HV /u = " not in short, short
print("Prix sans Auctionator :", [l for l in plain.split("\n") if l.startswith("Prix /u")])
print("Prix avec Auctionator :", [l for l in withAuct.split("\n") if l.startswith("Prix /u")])
assert "PNJ rachète" not in plain and "sacs 30" not in plain and "banque 0" not in plain, plain
pl = [l for l in withAuct.split("\n") if l.startswith("Prix /u")][0]
assert pl.startswith("Prix /u = le - cher ") or pl.startswith("Prix /u = réel "), pl
print("OK : infobulle sans doublons (PNJ, stock, prix Auctionator)")

# --- Meilleur jour et meilleure heure pour vendre (Timing.lua) ---
tm = lua.eval("""function(ns)
  local T = ns.Timing
  local WEEK = T.WEEK
  -- dimanche 00:00 en heure locale (celle de date(), comme en jeu)
  local t0 = 19700 * 86400
  while true do
    local d = date("*t", t0)
    if d.wday == 1 and d.hour == 0 and d.min == 0 then break end
    t0 = t0 + 3600 - (d.min * 60 + d.sec)
  end
  local function hourOf(t) local d = date("*t", t); return d.wday - 1, d.hour end
  -- Scanne aux instants donnés ; rate(wd, h) = enchères vendues par heure (par objet), sans hasard
  local function simulate(times, rates)
    local db = { scans = {} }
    local last
    for _, t in ipairs(times) do
      local gap = last and t - last
      local diff = {}
      if gap then
        for id, rate in pairs(rates) do
          local n, x = 0, last
          while x < t do local wd, h = hourOf(x); n = n + rate(wd, h) * math.min(3600, t - x) / 3600; x = x + 3600 end
          diff[id] = { sold = n, ns = n }
        end
      end
      T.Record(db, t, gap and diff, gap)
      last = t
    end
    return db
  end
  local r = {}
  -- 1) Pic connu : scans toutes les heures pendant 8 semaines (il faut 4 dates par jour, et le test
  --    d'homogénéité sur 28 cases demande du volume) ; l'objet 1 se vend 2 fois plus le dimanche soir
  local hourly = {}
  for h = 0, 8 * 7 * 24 do hourly[#hourly + 1] = t0 + h * 3600 end
  local db1 = simulate(hourly, {
    [1] = function(wd, h) return (wd == 0 and h >= 18) and 4 or 2 end,
    [2] = function() return 2 end })
  local p1, p2 = T.Profile(db1, 1), T.Profile(db1, 2)
  r.peakStatus, r.peakCell, r.peakText, r.peakGain = p1.status, p1.bestCell and p1.bestCell.cell, p1.text, p1.gain
  r.peakCellGain, r.peakMarked = p1.cells[3].gain, p1.marked
  r.flatStatus, r.flatText, r.flatMarked = p2.status, p2.text, p2.marked
  r.describe = T.Describe(p1)
  -- 2) Biais de scan : le joueur scanne toutes les heures le dimanche soir, une seule heure (20-21 h) les
  --    autres soirs. Ventes en réalité régulières : les comptes bruts désignent le dimanche, pas le profil.
  local biased = {}
  for w = 0, 7 do
    for wd = 0, 6 do
      local base = t0 + (w * 7 + wd) * 86400
      if wd == 0 then for h = 18, 24 do biased[#biased + 1] = base + h * 3600 end
      else biased[#biased + 1] = base + 20 * 3600; biased[#biased + 1] = base + 21 * 3600 end
    end
  end
  local db2 = simulate(biased, { [1] = function() return 2 end,
    [3] = function(wd, h) return (wd == 3 and h == 20) and 5 or 2 end })  -- 3 : vrai pic le mercredi soir
  local raw = {}
  for c, n in pairs(T.parseSparse(db2.timing.it[1])) do local wd = math.floor(c / 4); raw[wd] = (raw[wd] or 0) + n end
  local rawBest, rawMax = nil, 0
  for wd, n in pairs(raw) do if n > rawMax then rawBest, rawMax = wd, n end end
  r.rawBest, r.rawRatio = rawBest, rawMax / (raw[1] or 1)
  local pb, pw = T.Profile(db2, 1), T.Profile(db2, 3)
  r.biasStatus, r.biasDayGain = pb.status, pb.days[0].gain
  r.wedStatus, r.wedCell, r.wedText = pw.status, pw.bestCell and pw.bestCell.cell, pw.text
  -- 3) Pas assez de données
  local db3 = simulate({ t0, t0 + 3600, t0 + 7200 }, { [1] = function() return 1 end })
  local p3 = T.Profile(db3, 1)
  r.lowStatus, r.lowText = p3.status, T.Describe(p3)
  -- 4) Découpage à minuit : samedi 22 h → dimanche 2 h
  local cuts = {}
  T.Split(t0 + 6 * 86400 + 22 * 3600, t0 + 7 * 86400 + 2 * 3600, function(c, s) cuts[#cuts + 1] = c .. "=" .. s end)
  r.cuts = table.concat(cuts, ",")
  -- 5) Snapshots bruts déjà stockés : ignorés (unités, pas enchères) ; pas de double compte d'un scan
  local db5 = { scans = {
    { v = 2, t = t0 + 3600, gap = 3600, items = "7=1,20,5,5,5,0,0,0,0,0,5,0,0" },
    { v = 2, t = t0 + 7200, gap = 3600, items = "7=1,20,5,5,5,40,0,0,0,200,5,0,0;8=1,1,5,5,5,0,0,0,0,0,5,0,0" } } }
  T.Record(db5, t0 + 7200, { [7] = { sold = 40, ns = 2 } }, 3600)
  T.Record(db5, t0 + 7200, { [7] = { sold = 40, ns = 2 } }, 3600)  -- même scan : ignoré
  local tm5 = db5.timing
  local obs5 = 0
  for _, s in pairs(T.parseDense(tm5.obs)) do obs5 = obs5 + s end
  r.bfObs, r.bfItem, r.bfN, r.bf8 = obs5, tm5.it[7], tm5.backfilled, tm5.it[8]
  T.Record(db5, t0 + 10800, { [7] = { sold = 40, ns = 2 } }, 3600)
  r.bfAfter = tm5.it[7]
  -- 6) Dates comptées : un jour n'est vu à une date que s'il y a été observé 1 h
  local db6, ev6 = {}, {}
  for w = 0, 9 do
    local base = t0 + w * WEEK
    ev6[#ev6 + 1] = { base + 1, 3601 }                              -- sam. 23 h → dim. 0 h 00 min 01 s
    if w < 4 then                                                     -- lundi : 2 × 30 min la même date
      ev6[#ev6 + 1] = { base + 86400 + 10 * 3600 + 1800, 1800 }
      ev6[#ev6 + 1] = { base + 86400 + 11 * 3600, 1800 }
    end
    if w < 6 then ev6[#ev6 + 1] = { base + 2 * 86400 + 10 * 3600 + 1800, 1800 } end  -- mardi : 30 min
  end
  for _, e in ipairs(ev6) do T.Record(db6, e[1], { [1] = { ns = 1 } }, e[2]) end
  r.dn = {}
  for wd = 0, 6 do r.dn[wd] = db6.timing.dn[wd] or 0 end
  -- 7) Décroissance : demi-vie de 5 semaines, appliquée au changement de semaine, purge des zéros
  local db7 = {}
  T.Record(db7, t0 + 3600, { [5] = { ns = 10 } }, 3600)
  r.dec0 = db7.timing.it[5]
  db7.timing.it[9] = "0:1"
  T.Record(db7, t0 + 5 * WEEK + 7200, { [6] = { ns = 1 } }, 3600)
  local o7 = T.parseDense(db7.timing.obs)
  r.dec5, r.decObs, r.dec9, r.decAll = db7.timing.it[5], o7[0], db7.timing.it[9], db7.timing.all
  T.Record(db7, t0 + 70 * WEEK + 3600, { [6] = { ns = 1 } }, 3600)
  r.decLate5, r.decLate6 = db7.timing.it[5], db7.timing.it[6]
  -- 8) Migration v1 → v2 (dixièmes → centièmes, dates vues plafonnées par les heures observées)
  local o8 = {}
  for c = 0, 27 do o8[c + 1] = 0 end
  o8[1], o8[5] = 7200, 1800
  local db8 = { timing = { v = 1, upto = t0, obs = table.concat(o8, ","), all = "0:20;4:5", it = { [3] = "0:20;4:5" },
                           dn = { [0] = 5, 3 }, dl = { [0] = 123, 456 }, backfilled = 2 } }
  local tm8 = T.Store(db8)
  r.migV, r.migIt, r.migAll, r.migDn0, r.migDn1, r.migDh0 = tm8.v, tm8.it[3], tm8.all, tm8.dn[0], tm8.dn[1], tm8.dh[0]
  -- 9) Hasard : 200 objets sans aucun pic (moitié Poisson pur, moitié ventes en grappes de 1 à 3
  --    enchères), 12 semaines, scans le soir en semaine et toute la journée le week-end ; 20 objets avec
  --    un vrai pic (×2 le dimanche soir). 12 semaines : avec la décroissance, ~6,4 semaines « pleines »
  -- générateur local (Park-Miller, comme le harnais) : ne décale pas le hasard des tests suivants
  local seed = TIMING_SEED or 20261127
  local function rnd(a, b)
    seed = (seed * 16807) % 2147483647
    local x = (seed - 1) / 2147483646
    if not a then return x end
    return a + math.floor(x * (b - a + 1))
  end
  local function poisson(m)
    local L, k, p = math.exp(-m), 0, 1
    repeat k = k + 1; p = p * rnd() until p <= L
    return k - 1
  end
  local times = {}
  for w = 0, 11 do
    for wd = 0, 6 do
      local h0 = (wd == 0 or wd == 6) and 10 or 18
      for h = h0, 24 do times[#times + 1] = t0 + (w * 7 + wd) * 86400 + h * 3600 end
    end
  end
  local rates, peak = {}, {}
  for id = 1, 200 do rates[id] = 0.1 + 2.9 * rnd() end
  for id = 301, 320 do peak[id] = 1.5 end
  local db9, last, total = {}, nil, 0
  for _, t in ipairs(times) do
    local gap = last and t - last
    local diff = {}
    if gap and gap <= T.MAX_GAP then
      for id, rt in pairs(rates) do
        local n = 0
        if id % 2 == 0 then
          for _ = 1, poisson(rt / 2 * gap / 3600) do n = n + rnd(1, 3) end
        else n = poisson(rt * gap / 3600) end
        if n > 0 then diff[id] = { ns = n, sold = n }; total = total + n end
      end
      for id, rt in pairs(peak) do           -- vrai pic : 2 fois plus le dimanche soir
        local wd, h = hourOf(t - 1)
        local n = poisson(rt * ((wd == 0 and h >= 18) and 2 or 1) * gap / 3600)
        if n > 0 then diff[id] = { ns = n, sold = n }; total = total + n end
      end
    end
    T.Record(db9, t, gap and diff, gap)
    last = t
  end
  r.rndSure, r.rndHint, r.rndFlat, r.rndLow = 0, 0, 0, 0
  local maxPhi = 0
  for id = 1, 200 do
    local p = T.Profile(db9, id)
    if p.status == "sure" then r.rndSure = r.rndSure + 1
    elseif p.status == "hint" then r.rndHint = r.rndHint + 1
    elseif p.status == "flat" then r.rndFlat = r.rndFlat + 1
    else r.rndLow = r.rndLow + 1 end
    if id % 2 == 0 and p.phi then maxPhi = math.max(maxPhi, p.phi) end
  end
  r.rndPhi = maxPhi
  r.peakFound = 0
  for id = 301, 320 do
    local p = T.Profile(db9, id)
    if p.status == "sure" and p.text and p.text:find("dimanche soir", 1, true) then r.peakFound = r.peakFound + 1 end
  end
  -- arrondi : la masse est conservée (décroissance mise à part, d'où un contrôle sans elle)
  local db10, tot10 = {}, 0
  for i = 1, 50 do
    local n = (i % 7) + 1
    tot10 = tot10 + n
    T.Record(db10, t0 + i * 5000, { [1] = { ns = n }, [2] = { ns = 1 } }, 5000)
  end
  local s10, s10b = 0, 0
  for _, n in pairs(T.parseSparse(db10.timing.it[1])) do s10 = s10 + n end
  for _, n in pairs(T.parseSparse(db10.timing.all)) do s10b = s10b + n end
  r.mass, r.massWant, r.massAll = s10, tot10 * 100, s10b
  -- Diff : nombre d'enchères vendues à côté des unités
  local prev = { ["9:20:200:?"] = { c = 3, tl = 4 } }
  local cur = { ["9:20:200:?"] = { c = 1, tl = 4 } }
  local d = ns.Scan.Diff(prev, cur, 3600)[9]
  r.diffNs, r.diffSold = d.ns, d.sold
  return r
end""")(ns)
tmr = {k: tm[k] for k in tm.keys()}
for k in ("dn",):
    tmr[k] = dict(tm[k])
print("Moment de vente :", tmr)
assert tmr["peakStatus"] == "sure" and tmr["peakCell"] == 3 and tmr["peakMarked"], tmr   # dimanche (0) × soir (3)
assert tmr["peakText"].startswith("+") and "dimanche soir" in tmr["peakText"], tmr
assert tmr["peakGain"] >= 0.15 and tmr["peakCellGain"] > 0.5, tmr
assert "fiable" in tmr["describe"], tmr
assert tmr["flatStatus"] == "flat" and tmr.get("flatText") is None and not tmr["flatMarked"], tmr  # régulier : rien
assert tmr["rawBest"] == 0 and tmr["rawRatio"] > 4, tmr                              # le biais existe en brut…
assert tmr["biasStatus"] == "flat" and abs(tmr["biasDayGain"]) < 0.05, tmr           # … et il est corrigé
assert tmr["wedStatus"] == "sure" and tmr["wedCell"] == 3 * 4 + 3 and "mercredi soir" in tmr["wedText"], tmr
assert tmr["lowStatus"] == "low" and tmr["lowText"].startswith("pas assez de données"), tmr
assert tmr["cuts"] == "27=7200,0=7200", tmr
assert tmr.get("bfN") is None and tmr["bfObs"] == 3600 and tmr["bfItem"] == "0:200" and tmr.get("bf8") is None, tmr
assert tmr["bfAfter"] == "0:400", tmr                                                # scan suivant : +2 enchères
# dates : 1 s du dimanche ×10 → 0 date ; lundi 2 × 30 min ×4 → 4 ; mardi 30 min ×6 → 0 ; samedi 1 h ×10 → 10
assert tmr["dn"] == {0: 0, 1: 4, 2: 0, 3: 0, 4: 0, 5: 0, 6: 10}, tmr["dn"]
assert tmr["dec0"] == "0:1000" and tmr["dec5"] == "0:500" and tmr["decObs"] == 1800 + 3600, tmr  # demi-vie 5 sem.
assert tmr.get("dec9") is None and tmr["decAll"] == "0:600", tmr                     # 1 centième : purgé
assert tmr.get("decLate5") is None and tmr["decLate6"] == "0:100", tmr               # 65 semaines plus tard
assert tmr["migV"] == 2 and tmr["migIt"] == "0:200;4:50" and tmr["migAll"] == "0:200;4:50", tmr
assert tmr["migDn0"] == 2 and tmr["migDn1"] == 0 and tmr["migDh0"] == 3600, tmr
print(f"Marché sans pic, 200 objets : {tmr['rndSure']} fiables, {tmr['rndHint']} indicatifs, {tmr['rndFlat']} plats, "
      f"{tmr['rndLow']} sans données ; φ max (grappes) {tmr['rndPhi']:.2f} ; vrai pic retrouvé {tmr['peakFound']}/20")
assert tmr["rndSure"] <= 10, tmr                                                     # ≤ 5 % de fausses alertes
assert tmr["peakFound"] == 20, tmr
assert tmr["mass"] == tmr["massWant"] and tmr["massAll"] == tmr["massWant"] + 5000, tmr  # arrondi sans perte
assert tmr["diffNs"] == 2 and tmr["diffSold"] == 40, tmr

# Branchements : infobulle (seulement si fiable), rapport, /ahl moment
br = lua.eval("""function(ns)
  local T, db = ns.Timing, ns.realmDB()
  local saved = db.timing
  local function tip()
    advance(10); ns.dataVersion = (ns.dataVersion or 0) + 1
    TT = {}
    IsShiftKeyDown = function() return true end
    GameTooltip.GetItem = function() return 'Mageweave', '|Hitem:4338::::|h' end
    GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
    IsShiftKeyDown = nil
    return table.concat(TT, "\\n")
  end
  -- profil synthétique (v2, centièmes) : 6 semaines observées en entier, le tisse-mage part 2× plus le dimanche soir
  local obs, it, all = {}, {}, {}
  for c = 0, 27 do obs[c] = 6 * 6 * 3600; it[c] = 6 * 6 * 2 * 100; all[c] = it[c] * 5 end
  it[3] = it[3] * 2
  db.timing = { v = 2, upto = time(), obs = "", all = T.packSparse(all), it = { [4338] = T.packSparse(it) },
                dn = { [0] = 6, 6, 6, 6, 6, 6, 6 }, dl = {}, dh = {} }
  local parts = {}
  for c = 0, 27 do parts[c + 1] = obs[c] end
  db.timing.obs = table.concat(parts, ",")
  local withLine = tip()
  local report = ns.Export.Build()
  local n0 = #LOG
  SlashCmdList.AHLEDGER("moment mageweave")
  SlashCmdList.AHLEDGER("moment")
  local said = {}
  for i = n0 + 1, #LOG do said[#said + 1] = LOG[i] end
  -- profil plat : pas de ligne
  it[3] = it[2]; db.timing.it[4338] = T.packSparse(it)
  local without = tip()
  db.timing = saved
  return withLine, report, table.concat(said, "\\n"), without
end""")(ns)
withLine, report, said, without = (strip(x) for x in br)
print("\n".join(l for l in withLine.split("\n") if "moment" in l.lower()))
print(report[report.find("## Meilleur moment"):][:600])
print(said)
assert "Meilleur moment = +" in withLine and "dimanche soir" in withLine, withLine
assert "Meilleur moment" not in without, without
assert "## Meilleur moment pour vendre" in report and "Mageweave Cloth : +" in report, report
assert "Meilleur moment pour vendre Mageweave Cloth : +" in said and "fiable" in said and "Par jour : dim ×" in said, said
print("OK : meilleur jour / heure pour vendre (pic retrouvé, biais de scan corrigé, branchements)")
# Aujourd'hui (Today.lua) : plan de séance sur le marché simulé, sacs remplis à la main
# Cache du plan : même clé → même résultat sans recalcul ; TTL 0 pour les tests qui remplacent des fonctions
cache = lua.eval("""function(ns)
  local T = ns.Today
  local n, saved = 0, T.PlanUncached
  T.PlanUncached = function(...) n = n + 1; return saved(...) end
  T.PLAN_TTL = 5
  T.Plan(30, 1000); T.Plan(30, 1000)
  local same = n
  T.Plan(60, 1000)
  local other = n
  ns.dataVersion = ns.dataVersion + 1
  T.Plan(60, 1000)
  local bumped = n
  T.PlanUncached = saved
  T.PLAN_TTL = 0
  return same, other, bumped
end""")(ns)
assert tuple(cache) == (1, 2, 3), tuple(cache)
print("OK : cache du plan Aujourd'hui (même clé : pas de recalcul ; durée ou données changées : recalcul)")

today = lua.eval("""function(ns)
  local T, A = ns.Today, ns.Analysis
  local c = ns.Prof.Char()
  local savedBags = c.bags
  c.bags = { [4306] = 60, [2589] = 80, [929] = 6, [2592] = 30 }
  ns.dataVersion = ns.dataVersion + 1
  local r = {}
  local plan, sum = T.Plan(60, 1000 * 10000)
  r.n, r.kinds = #plan, {}
  for _, a in ipairs(plan) do r.kinds[a.kind] = true end
  -- temps et or respectés, quels que soient la durée et l'or disponibles
  r.limits = true
  for _, m in ipairs({ 15, 30, 60, 120 }) do
    for _, gold in ipairs({ 0, 500, 5000, 10000000 }) do
      local p, s = T.Plan(m, gold)
      local tm, tg = 0, 0
      for _, a in ipairs(p) do
        tm, tg = tm + a.minutes, tg + a.gold
        if a.trust == "bad" then r.limits = false end
      end
      if tm > m + 1e-6 or tg > gold or math.abs(tm - s.minutes) > 1e-6 or s.gold > gold then r.limits = false end
    end
  end
  local p0 = T.Plan(30, 0)
  r.noGold = true
  for _, a in ipairs(p0) do if a.gold > 0 then r.noGold = false end end
  -- tri : score (gain × fiabilité ÷ (minutes/T + or/G)) décroissant, rang = ordre du plan
  r.sorted = true
  for i, a in ipairs(plan) do
    if a.order ~= i or (i > 1 and a.score > plan[i - 1].score + 1e-9) then r.sorted = false end
  end
  -- exclusion : flip au prix jamais vu vendu (Trust « bad »), flips d'un type qui échoue (Track)
  local savedF, savedTS = A.Flips, ns.Track.Summary
  local function fakeS(id, maxSold)
    return { id = id, name = "Faux" .. id, price = 1000, ev = { list = { { maxSold, 10, "s", 10 } }, maxSold = maxSold, soldUnits = 10 } }
  end
  A.Flips = function()
    return {
      { kind = "now", id = 90001, s = fakeS(90001, 5000), qty = 10, cost = 1000, maxBuy = 100, resale = 1000, profit = 900000, roi = 9, days = 1 },
      { kind = "now", id = 90002, s = fakeS(90002, 200), qty = 10, cost = 1000, maxBuy = 100, resale = 1000, profit = 800000, roi = 8, days = 1 },
    }
  end
  local p1, s1 = T.Plan(60, 10000000)
  r.goodIn, r.badOut = false, true
  for _, a in ipairs(p1) do
    if a.id == 90001 then r.goodIn = a.order == 1 end
    if a.id == 90002 then r.badOut = false end
  end
  r.excl1 = s1.excluded
  ns.Track.Summary = function() return { { key = "now", label = "Flip HV tout de suite", checked = 10, rate = 0.1 } } end
  local p2, s2 = T.Plan(60, 10000000)
  r.trackOut = true
  for _, a in ipairs(p2) do if a.kind == "flip" then r.trackOut = false end end
  r.excl2 = s2.excluded
  -- type à moitié fiable : le conseil reste, « à tester », gain compté pour moitié dans le classement
  ns.Track.Summary = function() return { { key = "now", label = "Flip HV tout de suite", checked = 10, rate = 0.5 } } end
  local p3 = T.Plan(60, 10000000)
  for _, a in ipairs(p3) do if a.id == 90001 then r.halfTrust, r.halfW = a.trust, a.weight end end
  A.Flips, ns.Track.Summary = savedF, savedTS
  -- commande, onglet et rapport
  SlashCmdList.AHLEDGER("aujourdhui 30")
  for i = #LOG, 1, -1 do if LOG[i]:find("Plan de séance", 1, true) then r.cmd = LOG[i]; break end end
  ns.UI.Build()
  ns.UI.todayMinutes = 30
  ns.UI.SetMode("today")
  r.uiRows = 0
  for _, row in ipairs(ns.UI.rows) do if row.shown then r.uiRows = r.uiRows + 1 end end
  r.footer = ns.UI.footer.text
  r.btn30 = ns.UI.todayButtons[30]:IsShown()
  ns.UI.SetMode("market")
  r.btnHidden = not ns.UI.todayButtons[30]:IsShown()
  r.report = ns.Export.Build():find("## Aujourd'hui", 1, true) ~= nil
  c.bags = savedBags
  ns.dataVersion = ns.dataVersion + 1
  return r
end""")(ns)
print("Aujourd'hui :", today.n, "actions,", sorted(today.kinds.keys()), "·", strip(today.cmd), "·", strip(today.footer))
assert today.n >= 3 and today.kinds["sell"] and today.kinds["farm"], dict(today.kinds)
assert today.limits and today.noGold, "le plan dépasse le temps ou l'or disponibles"
assert today.sorted, "plan non trié par gain/minute pondéré"
assert today.goodIn and today.badOut and today.excl1 >= 1, (today.goodIn, today.badOut, today.excl1)
assert today.trackOut and today.excl2 >= 2, (today.trackOut, today.excl2)
assert today.halfTrust == "test" and today.halfW == 0.5, (today.halfTrust, today.halfW)
assert "Plan de séance (30 min)" in strip(today.cmd), strip(today.cmd)
assert today.uiRows == today.n or today.uiRows >= 3, today.uiRows
assert "action" in strip(today.footer) and today.btn30 and today.btnHidden and today.report
print("OK : Aujourd'hui (plan non vide, or et temps respectés, tri par gain/min, conseils non fiables écartés, onglet, commande, rapport)")
# Aujourd'hui : gain homogène, une action par objet, vente PNJ jamais écartée, repost non repondéré, l'or compte
today2 = lua.eval("""function(ns)
  local T, A = ns.Today, ns.Analysis
  local c = ns.Prof.Char()
  local savedBags, savedF, savedTS, savedU, savedOpp = c.bags, A.Flips, ns.Track.Summary, ns.Sell.Undercuts, ns.Opp.Undercuts
  AHLedgerDB.items[90100] = { n = "Ferraille", s = 500 }   -- pas de marché HV : conseil « PNJ »
  c.bags = { [4306] = 60, [2589] = 80, [929] = 6, [2592] = 30, [90100] = 4 }
  ns.dataVersion = ns.dataVersion + 1
  ns.Track.Summary = function() return {} end
  local r = {}
  local function fakeS(id, maxSold, n)
    return { id = id, name = "Faux" .. id, price = 1000, perDay = 5,
             ev = { list = { { maxSold, n or 10, "s", n or 10 } }, maxSold = maxSold, soldUnits = n or 10 } }
  end
  local function ids(plan)
    local seen, ok = {}, true
    for _, a in ipairs(plan) do
      if a.id then if seen[a.id] then ok = false end; seen[a.id] = true end
    end
    return ok
  end
  -- 1. gain d'une vente : p × (net − PNJ) − (1 − p) × dépôt ; p selon vendus/j et durée, « à tester » : p × 0,5
  local s1 = { perDay = 10 }
  r.p24, r.p12 = T.SellProb(s1, 10, 24, 0), T.SellProb(s1, 10, 12, 0)
  r.pAhead = T.SellProb(s1, 10, 24, 10)
  local g1, p1 = T.SaleGain(90100, s1, 10, 1000, 24, 0, "ok")
  local g2, p2, dep2 = T.SaleGain(90100, s1, 10, 1000, 12, 0, "test")
  local net = 1000 * (1 - A.AH_CUT)
  r.g1ok, r.p1, r.p2 = math.abs(g1 - 10 * (net - 500)) < 1e-6, p1, p2
  r.g2ok = dep2 > 0 and math.abs(g2 - 10 * (0.25 * (net - 500) - 0.75 * dep2)) < 1e-6
  -- 2. une seule action par objet : un flip sur un objet de la file de vente ne s'ajoute pas à la vente
  A.Flips = function()
    return { { kind = "now", id = 2589, s = fakeS(2589, 5000), qty = 10, cost = 100, maxBuy = 10, resale = 99,
               profit = 50000, roi = 5, days = 1 } }
  end
  local cands = T.Candidates(60, 10000000)
  local nSell, nFlip = 0, 0
  for _, a in ipairs(cands) do
    if a.id == 2589 and a.kind == "sell" then nSell = nSell + 1 end
    if a.id == 2589 and a.kind == "flip" then nFlip = nFlip + 1 end
  end
  r.bothCands = nSell == 1 and nFlip == 1
  local pd, sd = T.Plan(60, 10000000)
  local n2589 = 0
  for _, a in ipairs(pd) do if a.id == 2589 then n2589 = n2589 + 1 end end
  r.oneId, r.dup = n2589 == 1, sd.dup
  r.unique = true
  for _, m in ipairs({ 15, 30, 60, 120 }) do
    for _, gold in ipairs({ 0, 500, 5000, 10000000 }) do
      local p, s = T.Plan(m, gold)
      if not ids(p) then r.unique = false end
      local tm, tg = 0, 0
      for _, a in ipairs(p) do tm, tg = tm + a.minutes, tg + a.gold end
      if tm > m + 1e-6 or tg > gold then r.unique = false end
    end
  end
  A.Flips = savedF
  -- objet des sacs conseillé « PNJ » ou « Fabriquer » : jamais proposé à l'HV (Sous-coter)
  local adv = {}
  for _, e in ipairs(ns.Bags.Advice()) do adv[e.id] = e.action end
  r.advNPC, r.advCraft = adv[90100], adv[4306]
  ns.Opp.Undercuts = function()
    return { { id = 90100, s = fakeS(90100, 5000), have = 4, qty = 4, post = 900, premium = 0.3, notes = "" },
             { id = 4306, s = fakeS(4306, 5000), have = 60, qty = 10, post = 900, premium = 0.3, notes = "" } }
  end
  r.noPremium = true
  for _, a in ipairs(T.Candidates(60, 10000000)) do if a.kind == "premium" then r.noPremium = false end end
  ns.Opp.Undercuts = savedOpp
  -- 3. vente au PNJ : jamais écartée, même si Track juge mal « Sacs : vendre au PNJ »
  ns.Track.Summary = function() return { { key = "bagNPC", label = "Sacs : vendre au PNJ", checked = 20, rate = 0.05 } } end
  local pn = T.Plan(60, 10000000)
  for _, a in ipairs(pn) do if a.kind == "npc" then r.npcIn, r.npcTrust = true, a.trust end end
  ns.Track.Summary = function() return {} end
  -- 4. repost « à tester » : gain déjà pondéré par les chances de vendre, pas remultiplié par 0,5
  ns.Sell.Undercuts = function()
    return { { id = 90200, s = fakeS(90200, 1000, 1), worth = true, gain = 5000, newPrice = 1000, n = 1, qty = 2, gap = 0.1 } }
  end
  for _, a in ipairs(T.Candidates(60, 10000000)) do
    if a.kind == "repost" then
      r.rpTrust, r.rpW, r.rpGain = a.trust, a.weight, a.gain
      r.rpScore = math.abs(a.score - 5000 / (T.REPOST_MIN / 60 + a.gold / 10000000)) < 1e-6
    end
  end
  ns.Sell.Undercuts = savedU
  -- 5. peu d'or : un flip qui bloque presque tout l'or passe derrière un flip peu coûteux de meilleur rendement
  A.Flips = function()
    return { { kind = "now", id = 90011, s = fakeS(90011, 5000), qty = 10, cost = 9500, maxBuy = 950, resale = 1000,
               profit = 20000, roi = 2.1, days = 1 },
             { kind = "now", id = 90012, s = fakeS(90012, 5000), qty = 10, cost = 10, maxBuy = 1, resale = 1000,
               profit = 3000, roi = 300, days = 1 } }
  end
  local function orders(gold)
    local oa, ob
    for _, a in ipairs((T.Plan(60, gold))) do
      if a.id == 90011 then oa = a.order end
      if a.id == 90012 then ob = a.order end
    end
    return oa, ob
  end
  local oaPoor, obPoor = orders(10000)
  local oaRich, obRich = orders(10000000)
  r.poorOk = obPoor ~= nil and (oaPoor == nil or obPoor < oaPoor)
  r.richOk = oaRich ~= nil and obRich ~= nil and oaRich < obRich
  -- 5 bis : dépôt dans l'or immobilisé (flip) et temps de mise en vente (achat PNJ, artisanat vendu à l'HV)
  r.postTime = true
  for _, a in ipairs(T.Candidates(60, 10000000)) do
    if a.kind == "vendor" and a.minutes < T.VENDOR_TRAVEL_MIN + T.POST_MIN - 1e-9 then r.postTime = false end
    if a.kind == "craft" and a.group == "craft" and a.minutes < T.CRAFT_SETUP_MIN + T.POST_MIN - 1e-9 then r.postTime = false end
  end
  A.Flips, ns.Track.Summary = savedF, savedTS
  c.bags = savedBags
  AHLedgerDB.items[90100] = nil
  ns.dataVersion = ns.dataVersion + 1
  return r
end""")(ns)
print("Aujourd'hui (classement) :", dict(today2))
assert abs(today2.p24 - 1) < 1e-9 and abs(today2.p12 - 0.5) < 1e-9 and abs(today2.pAhead - 0.5) < 1e-9, dict(today2)
assert today2.g1ok and today2.p1 == 1 and abs(today2.p2 - 0.25) < 1e-9 and today2.g2ok, dict(today2)
assert today2.bothCands and today2.oneId and today2.dup >= 1, "même objet compté deux fois dans le plan"
assert today2.unique, "un plan contient deux actions pour le même objet, ou dépasse le temps ou l'or"
assert today2.advNPC == "PNJ" and today2.advCraft == "Fabriquer" and today2.noPremium, (today2.advNPC, today2.advCraft, today2.noPremium)
assert today2.npcIn and today2.npcTrust == "ok", "vente au PNJ écartée"
assert today2.rpTrust == "test" and today2.rpW == 1 and today2.rpGain == 5000 and today2.rpScore, "repost pondéré deux fois"
assert today2.poorOk and today2.richOk, "l'or disponible ne change pas le classement"
assert today2.postTime, "temps de mise en vente oublié pour un achat PNJ ou un craft revendu à l'HV"
print("OK : Aujourd'hui (gain incrémental, une action par objet, vente PNJ jamais écartée, repost non repondéré, score temps + or)")
