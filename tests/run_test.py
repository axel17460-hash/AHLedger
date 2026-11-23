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
for mode in ("market", "flip", "craft", "level", "vendor", "snipe", "farm"):
    show_ui(mode)

# Flip HV : la pile bradée de soie doit ressortir, achetée jusqu'à 5 pa/u
flips = {f.id: f for f in ns.Analysis.Flips().values()}
silkFlip = flips.get(4306)
print("Flip soie :", silkFlip and (silkFlip.qty, silkFlip.maxBuy, round(silkFlip.resale), round(silkFlip.profit)))
assert silkFlip and silkFlip.maxBuy >= 500 and silkFlip.qty >= 20 and silkFlip.resale > 900
assert 4338 not in flips  # tisse-mage en afflux, pas de pile sous le prix
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
assert any(x.startswith("Tendance 24 h = +") for x in tt), tt

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
assert adv[4306].action == "Garder"
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

# Artisanat : classé par or/jour possible (bénéfice × part du marché)
crafts = [e for e in ns.Analysis.Crafts().values() if e.profit is not None]
for e in crafts:
    assert e.daily is not None and e.vol is not None
    if e.sellTo == "HV":
        assert abs(e.vol - (e.perDay or 0) * 0.25) < 1e-6

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
assert any(x.startswith("Tu en as 30 (sacs 30, banque 0) : Vendre HV") for x in tt), tt
assert any(x.startswith("Toi, 30 j = 120 vendus") for x in tt), tt
assert any(x.startswith("Données : ") for x in tt), tt
print("OK : tests PNJ → HV et tooltip")
assert any(x.startswith("Vendre à l'HV") or x.startswith("HV ≈ PNJ") or x.startswith("Au PNJ") for x in tt[:4]), tt

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
  DaylightUI = nil; ns.Look.me = nil; A.Get = real; AHLedgerDB.items[999001] = nil
  return out[1], out[2], out[3], out[4], out[5], noPnj, started, painter[1], closed, openShown, g, red, hidden
end""")(ns)
print("HV/PNJ :", cmp)
assert cmp[:5] == ("ah", "same", "same", "vendor", "ah"), cmp
assert cmp[6] is True and cmp[7] == "bagslot", cmp
assert cmp[8] is False and cmp[9] is True and cmp[10] == 1 and cmp[11] is True and cmp[12] is True, cmp
print("OK : HV ou PNJ, pastilles des sacs")
