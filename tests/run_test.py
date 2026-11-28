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
lua.globals().NS = ns
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
NS.Vendor.Record()                -- relevé marchand : plus automatique (hors HV)
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
buildAuctions() -- marché complet : un scan de 3 enchères serait refusé comme incomplet
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

# Infobulle : la décision en tête, puis les chiffres qui la justifient (pas de tendance ni de signaux)
lua.execute("""
TT = {}
GameTooltip.AddLine = function(_, t) TT[#TT + 1] = t end
GameTooltip.AddDoubleLine = function(_, a, b) TT[#TT + 1] = a .. " = " .. b end
GameTooltip.GetItem = function() return 'Silk', '|Hitem:4306::::|h' end
GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
""")
tt = [strip(re.sub(r"\|T[^|]*\|t", "", x)) for x in lua.eval("TT").values()]
print("\n".join(tt))
assert tt[1] == "AHLedger" and tt[2].startswith(("Vendre", "Tester", "Attendre", "Garder", "Fabriquer")), tt
assert any(x.startswith("Ventes sûres /j (scans 0.9, ") for x in tt) and not any("Tendance" in x for x in tt), tt
# pas de doublon avec les preuves de la décision (plus bas habituel, rachat PNJ)
assert not any(x.startswith(("Plus bas habituel", "Rachat par le PNJ")) for x in tt), tt

# Mes objets : chaque objet reçoit la décision de Decide (action, prix, quantité, preuves sourcées)
lua.execute("""
BAGS = { [0] = { { 4306, 40 }, { 4338, 30 }, { 2589, 3 } } }
GetContainerNumSlots = function(b) return BAGS[b] and #BAGS[b] or 0 end
GetContainerItemInfo = function(b, s) local x = BAGS[b] and BAGS[b][s]; if not x then return nil end; return nil, x[2], false, 1, false, false, nil, false, false, x[1] end
fire("BAG_UPDATE_DELAYED"); runTimers()
""")
adv = {e.id: e for e in ns.Bags.Advice().values()}
for e in adv.values():
    print("Conseil", strip(lua.eval("function(id) return AHLedgerDB.items[id].n end")(e.id)), e.count, e.action, e.post, e.postQty, strip(e.why))
for e in adv.values():
    assert e.action in ("HV", "PNJ", "Tester", "Attendre", "Garder", "Fabriquer"), e.action
    assert " : " in strip(e.why), e.why  # raison · source : preuve
    if e.action == "Fabriquer":
        assert e.craftUp and e.craftUp.crafts >= 1
mage = ns.Analysis.Get(4338)
if adv[4338].action == "HV" and mage.minNow:
    assert adv[4338].post < mage.minNow and 1 <= adv[4338].postQty <= 30, (adv[4338].post, mage.minNow)
ns.UI.SetMode("bags"); assert ns.UI.rows[1].shown

# Sac de composants (sac 5 sur Forever) : compté dans tes sacs, et retiré une seule fois de l'ancienne
# photo de la banque, qui le lisait comme un sac de banque avant la 0.9
rb = lua.eval("""function(ns)
  local c = ns.Prof.Char()
  local savedBags, savedBank, savedLayout = BAGS, c.bank, c.bankLayout
  NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5
  BAGS = { [0] = { { 4306, 40 } }, [5] = { { 4306, 4 }, { 2996, 2 } } }
  c.bank, c.bankLayout = { [4306] = 83, [2996] = 2 }, nil
  ns.Bags.ScanBags()
  local silkBags, boltBags, silkBank, boltBank = c.bags[4306], c.bags[2996], c.bank[4306], c.bank[2996]
  local boltCount, bankList = ns.Bags.Count(2996), table.concat(ns.Bags.BankList(), ",")
  ns.Bags.ScanBags()
  local silkBank2 = c.bank[4306]
  NUM_TOTAL_EQUIPPED_BAG_SLOTS = nil
  BAGS, c.bank, c.bankLayout = savedBags, savedBank, savedLayout
  ns.Bags.ScanBags()
  return silkBags, boltBags, silkBank, boltBank, boltCount, bankList, silkBank2
end""")(ns)
print("Sac de composants :", rb)
assert rb == (44, 2, 79, None, 2, "-1,6,7,8,9,10,11,12", 79), rb
row = lua.eval("""function(ns)
  local d = { qty = 83, post = 188, sells = { v = "yes" }, reason = "se vend", facts = {}, warn = {} }
  local e = ns.UI.BagRow({ id = 4306, count = 83, action = "HV", vendor = 150, d = d, where = "sacs+banque", bags = 4, bank = 79 })
  return e.plain
end""")(ns)
assert row.startswith("prends-en 79 en banque"), row  # 4 dans les sacs, 83 à vendre
print("OK : sac de composants compté dans tes sacs, le reste à prendre en banque")

# Mes objets : le gain latent de ce que tu as acheté vaut le stock du Bilan (Decide.RawValue), au prix
# habituel si le prix du jour est douteux, et le dit
gain = lua.eval("""function(ns)
  local D, out = ns.Decide, {}
  local raw = D.RawValue
  D.RawValue = function() return 300 end
  -- prix de revient (Decide.UnitCost) : 10 achetés 100c/u
  local basis = { n = 10, bought = 10, boughtUnit = 100, crafted = 0, farmed = 0, farmUnit = 300, known = 10,
                  knownUnit = 100, unit = 100 }
  local d = { qty = 1, post = 5000, unit = 4800, suspect = true, sells = { v = "yes" }, reason = "prix douteux", facts = {}, warn = {},
              basis = basis }
  local e = ns.UI.BagRow({ id = 4306, count = 10, action = "Tester", vendor = 50, d = d, where = "sacs", bags = 10, bank = 0 })
  out.gain, out.plain = e.gain, e.plain
  d.suspect = nil
  e = ns.UI.BagRow({ id = 4306, count = 10, action = "HV", vendor = 50, d = d, where = "sacs", bags = 10, bank = 0 })
  out.plain2 = e.plain
  D.RawValue = raw
  return out
end""")(ns)
gd = dict(gain)
assert gd["gain"] == (300 - 100) * 10 and "au prix habituel" in strip(gd["plain"]) and "au prix habituel" not in strip(gd["plain2"]), gd
assert "prix de revient 1s 00c/u : 10 achetés 1s 00c : +20s 00c" in strip(gd["plain"]), strip(gd["plain"])
print("OK : gain latent de Mes objets = valeur du stock du Bilan")

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

# Conseil de sac : un objet qui se vend peu va au PNJ si le marchand paie au moins la moitié ;
# sans rachat PNJ, on en met un seul à la fois à l'HV
slow = lua.eval("""function(ns)
  local A = ns.Analysis
  local real = A.Get
  local s = { id = 999002, price = 400, netExp = 380, perDay = 0.1, surePerDay = 0.1, soldSure = 1, salesDays = 1,
              obsHours = 48, obs9Hours = 48, minNow = 390, deposit = 0 }
  A.Get = function(id) if id == 999002 then return s end return real(id) end
  AHLedgerDB.items[999002] = { n = "Poison lent", s = 0 }
  local a = ns.Bags.Advise(999002, 8)
  AHLedgerDB.items[999002].s = 300
  ns.dataVersion = ns.dataVersion + 1
  local b = ns.Bags.Advise(999002, 8)
  A.Get = real; AHLedgerDB.items[999002] = nil
  ns.dataVersion = ns.dataVersion + 1
  return a.action, a.postQty, a.d.sells.v, b.action
end""")(ns)
print("Objet qui se vend peu :", slow)
assert slow == ("HV", 1, "slow", "PNJ"), slow

# Artisanat : classé par or/jour possible (bénéfice × part du marché)
crafts = [e for e in ns.Analysis.Crafts().values() if e.profit is not None]
for e in crafts:
    assert e.daily is not None and e.vol is not None
    if e.sellTo == "HV":
        assert abs(e.vol - ((e.perDay or 0) * 0.25 if e.sells == "yes" else 0)) < 1e-6, (e.sells, e.vol)

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
    -- comme Daylight UI : une poignée si l'accroche est prise, false si elle est refusée
    Wrap = function(t, k, fn) local o = t[k]; t[k] = function(...) return fn(o, ...) end; return { hook = true } end,
    Hook = function(t, k, fn) local o = t[k]; t[k] = function(...) local r = o(...); fn(...); return r end; return { hook = true } end,
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
  ns.Vendor.Record()
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
assert any(x.startswith("Tu en as = 30 (sacs 30, banque 0)") for x in tt), tt
assert any(x.startswith("Toi, 30 j (courrier) = 120 vendus") for x in tt), tt
assert any(x.startswith(("Vendre", "Tester", "Attendre", "Garder", "Fabriquer")) for x in tt[:4]), tt
assert any("courrier : tes ventes 30 j : 120 vendus" in x for x in tt[:4]), tt  # tes ventes priment, avec leur source
print("OK : tests PNJ → HV et tooltip")

# Plus de verdict spéculatif (tendance 24 h, « bon moment pour acheter ») dans l'infobulle
assert not any(w in " ".join(tt) for w in ("bon moment", "attends pour acheter", "Tendance", "pénurie", "afflux")), tt

# Pastilles des sacs : couleur de la décision (vert HV, rouge PNJ), sur les cases de Daylight UI
cmp = lua.eval("""function(ns)
  local A = ns.Analysis
  local s = { id = 999001, netExp = 0, surePerDay = 10, soldSure = 70, salesDays = 7, obsHours = 48, obs9Hours = 48,
              minNow = 151, deposit = 0 }
  local real = A.Get
  A.Get = function(id) if id == 999001 then return s end return real(id) end
  AHLedgerDB.items[999001] = { n = "Test", s = 100 }
  local out = {}
  local function kind() ns.dataVersion = ns.dataVersion + 1; local c = ns.Bags.Compare(999001); return c and c.kind end
  for _, m in ipairs({ 151, 110 }) do s.minNow = m; out[#out + 1] = kind() end
  AHLedgerDB.items[999001].s = 0; s.minNow = 50
  out[#out + 1] = kind()
  -- pastille : Daylight UI simulé
  AHLedgerDB.items[999001].s = 100; s.minNow = 151; ns.dataVersion = ns.dataVersion + 1
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
  ns.BagMarks.Refresh(); runTimers()                -- calculs par morceaux, puis repeint
  local m = ns.BagMarks.slots[slot]
  local openShown, g = m.dot.shown, m.dot.rgb[2]
  s.minNow = 60; ns.dataVersion = ns.dataVersion + 1; ns.BagMarks.Refresh(); runTimers()
  local red = m.dot.rgb[1] == 1 and m.dot.rgb[2] < 0.5
  ns.ahOpen = false; ns.BagMarks.Refresh(); runTimers()
  local hidden = not m.dot.shown
  AHLedgerDB.opt.bagMarks = nil; ns.BagMarks.Refresh(); runTimers()           -- même « toujours » : rien hors de l'HV
  hidden = hidden and not m.dot.shown
  DaylightUI = nil; ns.Look.me = nil; A.Get = real; AHLedgerDB.items[999001] = nil
  ns.dataVersion = ns.dataVersion + 1
  return out[1], out[2], out[3], started, painter[1], closed, openShown, g, red, hidden
end""")(ns)
print("Pastilles :", cmp)
assert cmp[:3] == ("HV", "PNJ", "HV"), cmp
assert cmp[3] is True and cmp[4] == "bagslot", cmp
assert cmp[5] is False and cmp[6] is True and cmp[7] == 1 and cmp[8] is True and cmp[9] is True, cmp
print("OK : pastilles des sacs")

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
  local s = { id = 999002, name = "Test", realPrice = 1000, avg7 = 1000, perDay = 40, surePerDay = 40, salesDays = 7,
              deposit = 0, sellThrough = 0.9, stReliable = true }
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
         now0, fU == nil, 0, 0, fK.qty, A.FlipWhen(fK), fK.profit < fK.ifUp, fK.profit > fK.ifDown,
         fDown, fDownK and fDownK.kind, fNow.kind, A.FlipWhen(fNow),
         h[999002].units, h[999002].days, h[999002].profit, h[999003]
end""")(ns)
print("Rebonds / flips à stocker :", rb)
assert rb[0] is True and rb[1] == 2 and rb[2] == 11, rb          # creux du jour 11 remonté en 2 j
assert rb[3] is False and rb[4] == 20 and rb[5] is None, rb      # creux du jour 20 raté après 14 j
assert rb[6] == 2 and rb[7] == 1 and rb[8] == 2 and rb[9] is False, rb  # compté une seule fois
assert rb[10] is None, rb                                        # rien à revendre tout de suite
assert rb[11] is True, rb                                         # rebonds inconnus : pas de conseil d'achat
assert rb[14] == 80 and rb[15] == "stocker ~3 j (75%)" and rb[16] and rb[17], rb
assert rb[18] is None and rb[19] == "stock", rb                  # marché en baisse : seulement si l'objet remonte
assert rb[20] == "now" and rb[21] == "tout de suite", rb
assert rb[22] == 10 and abs(rb[23] - 3.2) < 1e-9 and abs(rb[24] - 45) < 1e-9 and rb[25] is None, rb

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
assert any("5 creux sur 6 remontés, ~3 j" in x for x in tt), tt
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
  local away = tip()                                      -- hors de l'HV : AHLedger ne fait rien
  IsShiftKeyDown = function() return true end
  local awayShift = tip()
  IsShiftKeyDown = nil
  ns.ahOpen = true
  local atAH = tip()
  ns.Options.Set("ttAH", "compact")
  local compact = tip()
  IsShiftKeyDown = function() return true end
  local shift = tip()
  IsShiftKeyDown = nil
  local ahCompact = compact
  ns.Options.Set("ttAH", "off")
  local off = tip()
  ns.ahOpen = false
  off = off .. away .. awayShift
  ns.Options.Set("bagMarks", "off")
  ns.ahOpen = true
  -- on teste les options, pas la décision : 4338 reçoit une pastille quoi que dise le marché
  local realCompare = ns.Bags.Compare
  ns.Bags.Compare = function() return { kind = "ah" } end
  local mark = ns.BagMarks.KindFor(4338)
  AHLedgerDB.opt = nil
  local markBack = ns.BagMarks.KindFor(4338)             -- par défaut : affichée à l'HV
  ns.ahOpen = false
  markBack = markBack and ns.BagMarks.KindFor(4338) == nil and markBack   -- jamais hors de l'HV
  ns.ahOpen = true
  AHLedgerDB.opt = { bagMarks = false }                 -- ancienne case décochée = jamais
  markBack = markBack and ns.BagMarks.KindFor(4338) == nil and markBack
  ns.Bags.Compare = realCompare
  ns.ahOpen = false
  ns.Options.Show()
  return compact, shift, atAH, ahCompact, off, mark, markBack, ns.Options.window ~= nil
end""")(ns)
compact, shift, atAH, ahCompact, off = (strip(re.sub(r"\|T[^|]*\|t", "", m)) for m in modes[:5])
print("Infobulle courte :\n" + compact)
cl = compact.split("\n")
assert cl[0] == "AHLedger = Maj : détails" and len(cl) <= 3, cl
assert cl[1].startswith(("Vendre", "Tester", "Attendre", "Garder", "Fabriquer")) and not any(x.startswith("Ventes sûres") for x in cl), cl
assert "Ventes sûres /j" in shift and "Tu en as = 30" in shift, shift
assert "Ventes sûres /j" in atAH and "Ventes sûres /j" not in ahCompact, ahCompact
assert ahCompact.split("\n")[1].startswith(("Vendre", "Tester", "Attendre", "Garder", "Fabriquer")), ahCompact
assert off == "", off
assert modes[5] is None and modes[6] is not None and modes[7], modes
print("OK : options d'infobulle et de pastilles")

# Fabriquer plutôt que vendre brut : seulement si l'objet fabriqué se vend vraiment (ventes sûres
# plusieurs jours, ou tes ventes) ; sinon il est compté au prix du marchand et la vente brute l'emporte
up = lua.eval("""function(ns)
  local A, P = ns.Analysis, ns.Prof
  local realGet, realRecipes, realCount = A.Get, P.Recipes, ns.Bags.Count
  ns.Bags.Count = function(id) if id == 999201 then return 9 end return realCount(id) end
  local function sells(t)
    t.surePerDay, t.soldSure, t.salesDays, t.obsHours, t.obs9Hours, t.perDay = t.rate, t.rate * 7, 7, 48, 48, t.rate
    return t
  end
  local stats = {
    [999201] = sells({ id = 999201, rate = 20, price = 110, minNow = 110, deposit = 0 }),   -- composant : ~1 pa brut
    [999202] = sells({ id = 999202, rate = 8, price = 1050, minNow = 1050, deposit = 0 }),  -- objet fabriqué : ~10 pa
    [999203] = { id = 999203, minNow = 30, obsHours = 0 },                                  -- autre composant : 30c
  }
  A.Get = function(id) return stats[id] or realGet(id) end
  P.Recipes = function() return { test = { [999202] = { n = "Bracelet", r = { [999201] = 3, [999203] = 2 } } } } end
  AHLedgerDB.items[999201] = { n = "Cuir", s = 20 }
  AHLedgerDB.items[999202] = { n = "Bracelet", s = 200 }
  ns.dataVersion = ns.dataVersion + 1
  local d = ns.Decide.For(999201, 9)
  advance(10)
  TT = {}
  GameTooltip.GetItem = function() return 'x', '|Hitem:999201::::|h' end
  ns.ahOpen = true                                       -- infobulles : seulement à l'HV
  GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
  ns.ahOpen = false
  local tip = table.concat(TT, "\\n")
  local action, crafts, perUnit, raw, altAction = d.action, d.craft and d.craft.crafts, d.craft and d.craft.perUnit,
    d.craft and d.craft.raw, d.alt and d.alt.action
  -- le bracelet ne se vend pas (aucune vente en 48 h) : vendre le cuir tel quel
  stats[999202] = { id = 999202, surePerDay = 0, soldSure = 0, salesDays = 0, perDay = 0, obsHours = 48, obs9Hours = 48,
                    price = 1050, minNow = 1050, deposit = 0 }
  ns.dataVersion = ns.dataVersion + 1
  local noSale = ns.Decide.For(999201, 9)
  -- équipement que personne n'a prouvé vendre pour toi : pas de fabrication non plus
  stats[999202] = sells({ id = 999202, rate = 8, price = 1050, minNow = 1050, deposit = 0, class = 4 })
  ns.dataVersion = ns.dataVersion + 1
  local gear = ns.Decide.For(999201, 9)
  A.Get, P.Recipes, ns.Bags.Count = realGet, realRecipes, realCount
  AHLedgerDB.items[999201], AHLedgerDB.items[999202] = nil, nil
  ns.dataVersion = ns.dataVersion + 1
  return action, crafts, perUnit, raw, altAction, tip, noSale.action, noSale.craft == nil, gear.action, ns.Decide.Line(d)
end""")(ns)
action, crafts, perUnit, raw, altAction, tip, noSaleAction, noCraft, gearAction, line = up
tip = strip(re.sub(r"\|T[^|]*\|t", "", tip))
print("Fabriquer :", action, crafts, perUnit, raw, altAction, "|", strip(line), "| sans ventes :", noSaleAction, "| équipement :", gearAction)
assert action == "Fabriquer" and crafts == 3 and altAction == "HV", up
assert perUnit > 2 * raw and strip(line).startswith("Fabriquer 3 × Bracelet"), up
assert "Fabriquer 3 × Bracelet" in tip and "Bracelet rapporte" in tip, tip
assert noSaleAction == "HV" and noCraft, up
assert gearAction == "HV", up
print("OK : fabriquer seulement vers un objet qui se vend")

# Fenêtre : position dans la liste au pied de page, tableau vide expliqué, flèche de tri
ui = lua.eval("""function(ns)
  local UI = ns.UI
  UI.liquidOnly, UI.cat = false, 1
  UI.content.GetHeight = function() return 78 + 36 + 80 + 5 * 20 end -- 4 lignes visibles (80 = panneau de détail)
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
  return footer, emptyHidden, empty, emptyShown, UI.headers[7].arrow.shown, UI.helpText ~= nil
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

# Mes flips : un achat conseillé par « Flip HV » est suivi, un autre non ; conseil de vente, alerte, vente
pf = lua.eval("""function(ns)
  local Pos = ns.Positions
  simHour(); buildAuctions()
  table.insert(AUCTIONS, { id = 4306, count = 20, buyout = 10000, owner = "Bradeur", tl = 4 })
  fire("AUCTION_HOUSE_SHOW"); SlashCmdList.AHLEDGER("scan"); runTimers()
  local oldAH, oldHook = C_AuctionHouse, hooksecurefunc
  hooksecurefunc = function(t, k, fn)
    local orig = t[k]
    t[k] = function(...) orig(...); fn(...) end
  end
  C_AuctionHouse = { StartCommoditiesPurchase = function() end, ConfirmCommoditiesPurchase = function() end }
  Pos.hooked = nil
  Pos.HookAH()
  local db = ns.realmDB()
  db.positions, db.recos = {}, {}
  ns.UI.SetMode("flip")                        -- le joueur voit les conseils
  local f
  for _, x in ipairs(ns.Analysis.Flips()) do if x.kind == "now" and (not f or x.profit > f.profit) then f = x end end
  if not f then
    local s4 = ns.Analysis.Get(4306)
    return "aucun flip", s4 and s4.realPrice, s4 and s4.perDay, s4 and s4.avg7, db.book and db.book[4306], #ns.Analysis.Flips(), db.lastScanTime, time()
  end
  local other = f.id == 4338 and 2592 or 4338
  local function buy(id, qty, total)
    C_AuctionHouse.StartCommoditiesPurchase(id, qty)
    fire("COMMODITY_PRICE_UPDATED", total / qty, total)
    C_AuctionHouse.ConfirmCommoditiesPurchase(id, qty)
    fire("COMMODITY_PURCHASE_SUCCEEDED")
  end
  buy(f.id, f.qty, f.cost)
  buy(other, 3, 3000)                           -- pas conseillé : ignoré
  local n = #db.positions
  local c = ns.Prof.Char()
  c.bags = c.bags or {}
  c.bags[f.id] = f.qty
  local before = #LOG
  local alerts = Pos.Check(true)
  local alertLine = LOG[#LOG]
  local e = Pos.Rows()[1]
  local verdict, sellAt, gainU = e.verdict, e.sellAt, e.gainU
  ns.UI.SetMode("positions")
  local shown = ns.UI.rows[1].shown and ns.UI.rows[1].cells[6].text
  -- ventes lues au courrier : le flip se referme
  advance(3600)
  table.insert(db.ledger, { k = "sold", id = f.id, n = f.name, c = f.qty, g = math.floor(sellAt * f.qty),
                            cut = math.floor(sellAt * f.qty * 0.05), dep = 0, t = time() })
  local done = Pos.Rows()[1]
  C_AuctionHouse, hooksecurefunc = oldAH, oldHook
  return n, f.kind, f.qty, verdict, sellAt, f.resale, gainU, alerts, alertLine, shown, done.verdict, done.gain, #LOG - before
end""")(ns)
assert pf[0] != "aucun flip", pf
n, kind, qty, verdict, sellAt, resale, gainU, alerts, alertLine, shown, doneV, doneGain, logs = pf
print("Mes flips :", n, kind, qty, verdict, sellAt, resale, gainU, alerts, strip(alertLine), strip(shown), doneV, doneGain)
assert n == 1, "seul l'achat conseillé est suivi"
assert verdict in ("sell", "high") and gainU > 0 and alerts == 1, pf
assert "Vends maintenant" in strip(alertLine) and "Vends" in strip(shown), pf
assert doneV == "done" and doneGain > 0, pf
print("OK : mes flips (achat conseillé suivi, conseil de vente, alerte, vente)")

# Suivi achats / ventes (Bilan) : tous les achats relevés, gain FIFO à la vente, courrier d'achat ancien estimé
tr = lua.eval("""function(ns)
  local db = ns.realmDB()
  -- courrier d'achat d'avant le relevé : 1 « unité » à 50 po, quantité fausse
  table.insert(db.ledger, { k = "bought", id = 4306, n = "Silk Cloth", c = 1, g = 20000, cut = 0, dep = 0, t = time() - 40 * 86400 })
  local journal, list, tot = ns.Tracker.Compute()
  local kinds, reco, outside, est = {}, 0, 0, false
  for _, r in ipairs(journal) do
    kinds[r.kind] = (kinds[r.kind] or 0) + 1
    if r.kind == "buy" and r.reco then reco = reco + 1 end
    if r.kind == "buy" and not r.reco and r.src == "live" then outside = outside + 1 end
  end
  local journal60 = ns.Tracker.Compute(60)
  for _, r in ipairs(journal60) do if r.est then est = r.c end end
  ns.UI.SetMode("ledger")
  local help = ns.UI.helpText
  local row1 = ns.UI.rows[1].shown and ns.UI.rows[1].cells[7].text
  ns.UI.SetMode("journal")
  -- tri par date : la ligne du haut est le bilan du jour, puis la ligne la plus récente
  local day = ns.UI.rows[1].shown and ns.UI.rows[1].entry and ns.UI.rows[1].entry.kind
  local jrow = ns.UI.rows[2].shown and ns.UI.rows[2].cells[3].text
  local band = ns.UI.band.shown and ns.UI.bandBoxes[5].value.text
  -- bilan réel = farm + reventes − dépôts ; le cumul du journal finit sur ce total
  local okReal = math.abs(tot.real - (tot.farm + tot.gain - tot.lostDep)) < 0.01
    and math.abs(journal[#journal].running - tot.real) < 0.01
  -- regroupement : deux expirations du même objet dans la même minute = une ligne
  local t0 = 60 * math.floor(time() / 60)
  local merged = ns.Tracker.Journal({
    { t = t0, kind = "exp", id = 4306, c = 1, total = 0, effect = -10, running = -10, seq = 1 },
    { t = t0 + 5, kind = "exp", id = 4306, c = 2, total = 0, effect = -20, running = -30, seq = 2 },
    { t = t0 + 6, kind = "buy", id = 4306, c = 1, total = 100, running = -30, seq = 3 } })
  local okMerge = #merged == 2 and merged[1].lines == 2 and merged[1].c == 3 and merged[1].effect == -30
    and merged[1].running == -30
  ns.UI.SetMode("ledger")
  local band2 = ns.UI.band.shown
  ns.UI.SetMode("advice")
  local noBand = not ns.UI.band.shown
  ns.UI.SetMode("ledger")
  return kinds.buy or 0, kinds.sell or 0, reco, outside, tot.gain, tot.result, est, help, row1, jrow, #list,
         day, band, okReal, okMerge, band2 and noBand
end""")(ns)
buys, sells, reco, outside, gain, result, est, help, row1, jrow, nitems, day, band, okReal, okMerge, bandShown = tr
print("Suivi :", buys, sells, reco, outside, gain, result, est, strip(help)[:160], strip(row1), strip(jrow), nitems, day, strip(band or ""))
assert day == "day" and band and okReal and okMerge and bandShown, tr
assert buys >= 2 and sells >= 1 and reco == 1 and outside == 1, tr   # + les courriers des tests précédents
assert gain > 0, tr
assert est and est > 1, "quantité d'un courrier d'achat estimée"
assert ("Plus grosse perte" in strip(help) or "Meilleur gain" in strip(help)) and row1 and ("Vente" in strip(jrow) or "Achat" in strip(jrow)), tr
print("OK : suivi des achats et ventes (Bilan par objet, journal)")

# Diff de scans : annulation (une enchère plus chère retirée alors qu'une moins chère reste), achat
# partiel d'une pile de commodité (le reste revient avec une quantité plus petite), expiration
diff = lua.eval("""function(ns)
  local S = ns.Scan
  local gap = 1800
  -- objet 1 : 2 enchères de 20 à 10c et 15c ; celle à 15c disparaît, celle à 10c reste (annulée ou expirée)
  -- objet 2 : pile de 20 à 10c, il en reste 12 au même prix (8 achetés)
  -- objet 3 : enchère unique (>12 h restantes) disparue en 30 min : vendue
  -- objet 4 : enchère < 30 min restantes disparue : expirée
  local prev = {
    ["1:20:200:?"] = { c = 1, tl = 4 }, ["1:20:300:?"] = { c = 1, tl = 4 },
    ["2:20:200:?"] = { c = 1, tl = 4 },
    ["3:1:5000:?"] = { c = 1, tl = 4 },
    ["4:1:5000:?"] = { c = 1, tl = 1 },
  }
  local cur = {
    ["1:20:200:?"] = { c = 1, tl = 4 },
    ["2:12:120:?"] = { c = 1, tl = 4 },
  }
  local d = S.Diff(prev, cur, gap)
  return d[1].sold, d[1].can + d[1].exp, d[2].sold, d[2].posted, d[3].sold, d[4].exp, d[4].sold
end""")(ns)
print("Diff :", diff)
assert diff[0] == 0 and diff[1] == 20, diff          # pas une vente : une moins chère restait
assert diff[2] == 8 and diff[3] == 0, diff           # achat partiel : 8 vendus, rien de « posté »
assert diff[4] == 1 and diff[5] == 1 and diff[6] == 0, diff
print("OK : diff de scans (annulations, achats partiels, expirations)")

# Tes courriers priment : 0 vendu sur 3 mises en vente expirées -> PNJ quand le marché ne prouve rien ;
# une seule pile expirée ne suffit pas ; si l'HV vend clairement, « lent » (vends au plancher), pas « non »
own = lua.eval("""function(ns)
  local A = ns.Analysis
  local realGet, realSales = A.Get, A.RealSales
  local s = { id = 999301, surePerDay = 0.3, soldSure = 2, salesDays = 1, obsHours = 48, obs9Hours = 48, minNow = 500,
              deposit = 0 }
  local sales = { [999301] = { sold = 0, expired = 6, bought = 0, soldN = 0, expiredN = 3 } }
  A.Get = function(id) if id == 999301 then return s end return realGet(id) end
  A.RealSales = function() return sales end
  AHLedgerDB.items[999301] = { n = "Croc", s = 40 }
  local function decide() ns.dataVersion = ns.dataVersion + 1; return ns.Decide.For(999301, 20) end
  local d = decide()
  local out = { d.action, d.sells.v, d.sells.src, ns.Decide.Why(d) }
  sales[999301].expiredN = 1
  out[#out + 1] = decide().sells.v
  sales[999301].expiredN = 3
  s.surePerDay, s.soldSure, s.salesDays = 30, 210, 7
  d = decide()
  out[#out + 1] = d.sells.v
  out[#out + 1] = d.action
  A.Get, A.RealSales = realGet, realSales
  AHLedgerDB.items[999301] = nil
  ns.dataVersion = ns.dataVersion + 1
  return unpack(out)
end""")(ns)
print("Courrier d'abord :", own[:3], strip(own[3]), own[4:])
assert own[:3] == ("PNJ", "no", "courrier") and "0 vendus, 6 expirés" in own[3], own
assert own[4] == "slow" and own[5] == "slow" and own[6] == "HV", own
print("OK : tes ventes réelles passent avant les scans")

# Prix plancher : une petite enchère bradée qui partira vite ne fixe pas ton prix
pp = lua.eval("""function(ns)
  local db = ns.realmDB()
  db.book = db.book or {}
  local saved = db.book[999401]
  db.book[999401] = "3,400|100:2;500:40;520:60"
  local p1, why1 = ns.Decide.PostPrice(999401, nil, 20)   -- 2 à 1 pa partent en < 1/4 de journée (20 ventes/j)
  local p2 = ns.Decide.PostPrice(999401, nil, 2)          -- 2 ventes/j : le plancher compte
  db.book[999401] = saved
  return p1, why1, p2
end""")(ns)
print("Prix plancher :", pp[0], strip(pp[1]), pp[2])
assert pp[0] == 499 and pp[2] == 99, pp
print("OK : prix de mise en vente")

# Débit : dès 12 h de jours entièrement 0.9, les anciens jours (retraits comptés comme ventes) et le
# jour mixte sont écartés ; avant, le chiffre reste celui des anciens scans, signalé comme tel
st = lua.eval("""function(ns)
  local t = ns.History.today()
  local function mk(pureDays)
    local db = { days = {}, hist = { [99020] = {} }, book = {}, lastMin = {}, recent = {} }
    for d = t - 6, t - 4 do -- anciens jours : 1000 « ventes »/j, retraits compris
      db.days[d] = { obs = 86400, scans = 24 }
      db.hist[99020][d] = "2400,24,2400,1000,0,100000,0"
    end
    db.days[t - 3] = { obs = 86400, o9 = 43200, scans = 24 } -- jour commencé avant la 0.9
    db.hist[99020][t - 3] = "100,1,100,500,500,50000,0,0,100"
    for i = 1, pureDays do -- jours 0.9 : 10 ventes sûres en 12 h
      local d = t - 3 + i
      db.days[d] = { obs = 43200, o9 = 43200, scans = 12 }
      db.hist[99020][d] = "1200,12,1200,10,0,1000,2,3,1200"
    end
    return ns.Analysis.ItemStats(db, 99020, t)
  end
  AHLedgerDB.items[99020] = { n = "Tissu test", s = 10 }
  local old, new = mk(0), mk(2)
  AHLedgerDB.items[99020] = nil
  return old.measured, old.surePerDay, new.measured, new.surePerDay, new.salesDays, new.stReliable
end""")(ns)
print("Débit anciens scans / 0.9 :", st)
assert st[0] is False and st[1] > 100, st                          # ancien chiffre gonflé, non mesuré
assert st[2] is True and abs(st[3] - 20) < 0.01 and st[4] == 2, st  # 20 ventes en 24 h de scans 0.9
print("OK : débit mesuré sur les seuls scans 0.9")

# ---- 0.10 : le conseiller ----
# Mes enchères : reprendre (sous-cotée), laisser (la moins chère), récupérer l'or (vendue), laisser
# expirer pour le PNJ (ne se vend pas), remettre à son retour (sous-cotée mais expire dans 1 h)
auc = lua.eval("""function(ns)
  local A = ns.Analysis
  local realGet, realSales = A.Get, A.RealSales
  local db, c = ns.realmDB(), ns.Prof.Char()
  db.book = db.book or {}
  local savedAuc, savedBook, S = c.auctions, {}, {}
  for id = 999601, 999605 do
    S[id] = { id = id, surePerDay = 10, soldSure = 70, salesDays = 7, obsHours = 48, obs9Hours = 48, measured = true,
              minNow = 500, price = 520, deposit = 0, perDay = 10 }
    AHLedgerDB.items[id] = { n = "Test" .. id, s = 100 }
    savedBook[id] = db.book[id]
  end
  local no = S[999604]
  no.surePerDay, no.soldSure, no.salesDays, no.perDay = 0, 0, 0, 0
  A.Get = function(id) return S[id] or realGet(id) end
  A.RealSales = function() return {} end
  db.book[999601] = "0,0|500:20;600:5"   -- tes 5 à 6 pa, d'autres à 5 pa
  db.book[999602] = "0,0|450:5;500:20"   -- tes 5 à 4 pa 50 : la moins chère
  db.book[999604] = "0,0|500:20;600:5"
  db.book[999605] = "0,0|500:20;600:5"
  c.auctions = { t = time(), list = {
    { id = 999601, qty = 5, unit = 600, bid = 0, left = 40000 },
    { id = 999602, qty = 5, unit = 450, bid = 0, left = 40000 },
    { id = 999603, qty = 2, unit = 700, bid = 0, sold = true },
    { id = 999604, qty = 5, unit = 600, bid = 0, left = 40000 },
    { id = 999605, qty = 5, unit = 600, bid = 0, left = 3600 },
  } }
  ns.dataVersion = ns.dataVersion + 1
  local v = {}
  for _, e in ipairs(ns.Advisor.Auctions()) do v[e.id] = e end
  local acts, relistFirst = ns.Advisor.Actions(), nil
  for _, e in ipairs(acts) do if e.kind == "relist" and e.id == 999601 then relistFirst = e.gold end end
  local mailRow = false
  for _, e in ipairs(acts) do if e.kind == "mail" then mailRow = true end end
  A.Get, A.RealSales = realGet, realSales
  c.auctions = savedAuc
  for id = 999601, 999605 do db.book[id] = savedBook[id]; AHLedgerDB.items[id] = nil end
  ns.dataVersion = ns.dataVersion + 1
  return v[999601].verdict, v[999601].post, v[999602].verdict, v[999603].verdict, v[999604].verdict, v[999605].verdict,
         relistFirst, mailRow
end""")(ns)
print("Mes enchères :", auc)
assert auc[:6] == ("relist", 499, "keep", "sold", "npc", "relistlater"), auc
assert auc[6] and auc[7], auc   # reprise et or au courrier remontent dans les conseils
print("OK : mes enchères (reprendre, laisser, récupérer l'or, PNJ, remettre au retour)")

# Bilan : ce qui marche, prix trop haut, à arrêter, achat-revente perdant
rv = lua.eval("""function(ns)
  local realSum, realComp = ns.Ledger.Summary, ns.Tracker.Compute
  ns.Ledger.Summary = function() return {
    { id = 999701, sold = 10, expired = 1, soldN = 5, expiredN = 1, sellThrough = 10 / 11, avgSale = 300, revenue = 2850, bought = 0 },
    { id = 999702, sold = 0, expired = 6, soldN = 0, expiredN = 3, sellThrough = 0, revenue = 0, bought = 0 },
    { id = 999703, sold = 2, expired = 8, soldN = 2, expiredN = 4, sellThrough = 0.2, avgSale = 300, revenue = 570, bought = 0 },
    { id = 999704, sold = 4, expired = 0, soldN = 2, expiredN = 0, sellThrough = 1, avgSale = 100, revenue = 380, bought = 10 },
  } end
  ns.Tracker.Compute = function()
    return {}, { { id = 999704, bought = 10, soldFromBuys = 4, result = -400, avgBuy = 200, avgSell = 95 } }, {}
  end
  local v = {}
  for _, e in ipairs(ns.Advisor.Review()) do v[e.id] = e end
  local t = ns.Advisor.ReviewTotals()
  ns.Ledger.Summary, ns.Tracker.Compute = realSum, realComp
  return v[999701].verdict, v[999702].verdict, v[999703].verdict, v[999704].verdict, t.works, t.stop, v[999702].advice
end""")(ns)
print("Bilan :", rv[:6], strip(rv[6]))
assert rv[:6] == ("works", "stop", "price", "loss", 1, 1), rv
print("OK : bilan, ce qui marche et ce qui ne marche pas")

# Onglets : Conseils d'abord, vues qui tournent, dernière vue retenue par onglet
show_ui("advice")
nav = lua.eval("""function(ns)
  local UI = ns.UI
  UI.SetMode("advice")
  local first = UI.rows[1].shown and UI.rows[1].entry and UI.rows[1].entry.kind
  local help = UI.helpText
  UI.SetMode("review")
  local v1 = UI.mode
  UI.viewButton.scripts.OnClick(UI.viewButton, "LeftButton")
  local v2 = UI.mode
  UI.viewButton.scripts.OnClick(UI.viewButton, "LeftButton")
  local v3 = UI.mode
  UI.viewButton.scripts.OnClick(UI.viewButton, "RightButton")
  local v4 = UI.mode
  UI.SetMode("advice")
  UI.modeButtons.review.scripts.OnClick(UI.modeButtons.review)
  local back = UI.mode
  for _, m in ipairs({ "auctions", "farmwhat", "flip", "positions", "vendor", "snipe", "craft", "level", "farm", "market", "bags" }) do
    UI.SetMode(m)
  end
  return first, help, v1, v2, v3, v4, back, #UI.TABS, UI.modeButtons.market.text:GetText()
end""")(ns)
print("Navigation :", nav[0], strip(nav[1])[:80], nav[2:])
assert nav[1].startswith("À encaisser"), nav
assert nav[2:7] == ("review", "ledger", "journal", "ledger", "ledger"), nav
assert nav[7] == 5 and nav[8] == "Marché", nav
print("OK : 5 onglets orientés décision (Aujourd'hui, Mon stock, Opérations, Artisanat, Marché)")

# 1.0 phase 5 : au plus 7 colonnes par vue, et le panneau de détail montre la ligne en entier
det = lua.eval("""function(ns)
  local UI = ns.UI
  local tooMany = {}
  for _, tab in ipairs(UI.TABS) do
    for _, m in ipairs(UI.VIEWS[tab] or { tab }) do
      UI.SetMode(m)
      local n = 0
      for _, h in ipairs(UI.headers) do if h.shown then n = n + 1 end end
      if n > 7 then tooMany[#tooMany + 1] = m .. "=" .. n end
    end
  end
  -- chaque vue est rangée dans un onglet
  local orphans = {}
  for _, m in ipairs({ "advice", "bags", "auctions", "review", "ledger", "journal", "farm", "craft", "level",
                       "market", "flip", "positions", "vendor", "snipe", "farmwhat" }) do
    if not (UI.GROUP[m] or m == "advice") then orphans[#orphans + 1] = m end
  end
  UI.SetMode("advice")
  local row = UI.rows[1]
  local first = UI.detail.text.text
  local long = "pourquoi très long " .. string.rep("et encore ", 40)
  local e = { kind = "sell", id = 4306, qty = 3, price = 1234, gold = 5000, conf = "prouvé", why = long }
  local text = UI.DetailText("advice", e)
  row.entry = e
  row.scripts.OnEnter(row)
  local shown = UI.detail.text.text
  -- vue avec chiffres sans colonne (« more ») : ils apparaissent dans le détail
  local mk = UI.DetailText("market", { id = 4306, price = 100, minNow = 90, trend = 0.1, surePerDay = 2,
    measured = true, stockDays = 3.5, sellThrough = 0.5, stReliable = true, gpd = 200, signals = { "pénurie" } })
  -- survol gardé après un rafraîchissement : on survole la 2e ligne, le panneau y reste
  local keep = true
  local r2 = UI.rows[2]
  if r2.shown and r2.entry then
    r2.scripts.OnEnter(r2)
    local want = UI.detail.text.text
    UI.Refresh()
    keep = UI.detail.text.text == want and UI.detailKey ~= nil
  end
  -- raison trop longue pour le panneau : l'infobulle ajoute la colonne de texte entière
  TT = {}
  UI.detail.text.IsTruncated = function() return true end
  row.entry = e
  row.scripts.OnEnter(row)
  UI.detail.text.IsTruncated = nil
  local inTip = false
  for _, x in ipairs(TT) do if tostring(x):find("et encore et encore", 1, true) then inTip = true end end
  -- changement de vue : le détail repart sur la 1re ligne de la nouvelle vue, sans clé mémorisée
  UI.SetMode("journal")
  local cleared = UI.detailKey == nil
  local j1 = UI.rows[1].shown and UI.rows[1].entry
  local jOk = (not j1) or UI.detail.text.text == UI.DetailText("journal", j1)
  -- molette sans survol : le détail suit la 1re ligne affichée
  UI.liquidOnly = false
  UI.content.GetHeight = function() return 78 + 36 + 80 + 3 * 20 end -- 2 lignes visibles
  UI.SetMode("market")
  UI.content.scripts.OnMouseWheel(UI.content, -1)
  local top = UI.rows[1].entry
  local follows = UI.offset > 0 and UI.detailKey == nil and top ~= nil
    and UI.detail.text.text == UI.DetailText("market", top)
  UI.content.GetHeight = nil
  UI.liquidOnly = true
  UI.offset = 0
  return table.concat(tooMany, ","), table.concat(orphans, ","), first, text, shown, mk, cleared and jOk and j1 ~= nil, keep, inTip, follows
end""")(ns)
tooMany, orphans, first, dtext, dshown, mk, cleared, keep, inTip, follows = det
assert keep and follows, det
assert inTip, det
print("Détail :", strip(dtext)[:140]); print("Détail marché :", strip(mk))
assert tooMany == "" and orphans == "", det
assert first is not None, det                                    # la 1re ligne s'affiche d'office
assert ("et encore " * 40).strip() in strip(dtext) and "Pourquoi :" in strip(dtext), dtext
assert strip(dshown) == strip(dtext), det                         # survol = détail de la ligne
assert "Achat min/u" in strip(mk) and "Stock (j) 3.5" in strip(mk) and "pénurie" in strip(mk), mk
assert cleared, det
print("OK : 1.0 phase 5 — 7 colonnes au plus, panneau de détail (ligne entière, chiffres sans colonne)")

# Farm : jamais un objet qu'un marchand vend (il s'achète) ; montée de métier rentable affichée en gain
fv = lua.eval("""function(ns)
  local vendorFarmed, levelGold = false, nil
  local db = ns.realmDB()
  for _, e in ipairs(ns.Advisor.FarmTargets()) do if db.vendor and db.vendor[e.id] then vendorFarmed = true end end
  ns.dataVersion = ns.dataVersion + 1
  for _, e in ipairs(ns.Advisor.Actions()) do if e.kind == "level" then levelGold = e.gold end end
  return vendorFarmed, levelGold
end""")(ns)
print("Farm / métier :", fv)
assert fv[0] is False and fv[1] and fv[1] > 0, fv
print("OK : on ne farme pas ce qui s'achète au PNJ ; point de métier rentable compté en gain")

# Mises à jour d'Auctionator / Daylight UI : une accroche refusée tombe sur le repli, et /ahl diag
# dit ce qui tient encore (versions, fin de scan, historique, onglet HV, bouton des sacs)
compat = lua.eval("""function(ns)
  local out = {}
  local UI, Marks, Diag = ns.UI, ns.BagMarks, ns.Diag
  local saved = { UI.dlTried, UI.dlTab, UI.dlMain, UI.ahButton, Marks.toolHooked, Marks.started, ns.Bridge.hooked, Auctionator }
  local refuse, unhooked = false, 0
  local Main = { TABS = { { id = "buy" } } }
  function Main.Build() Main.frame = { pages = {} } end
  function Main.ShowTab() end
  local laid = 0
  local W = { LayoutTools = function() laid = laid + 1 end }
  local bagFrame = CreateFrame(); bagFrame.tools = {}
  local me = { RegisterMover = function() return true end, Unhook = function() unhooked = unhooked + 1 end,
    Wrap = function(t, k, fn) if refuse == true then return false end
      local o = t[k]; t[k] = function(...) return fn(o, ...) end; return { hook = true } end,
    Hook = function(t, k, fn) if refuse == "hook" or refuse == true then return false end
      local o = t[k]; t[k] = function(...) local r = o(...); fn(...); return r end; return { hook = true } end }
  DaylightUI = {
    GetModule = function(_, n) if n == "AuctionHouse" then return { ns = { Window = Main } } elseif n == "Bags" then return { ns = { Window = W } } end end,
    API = { major = 1, minor = 15, Skin = function() end, Text = function() return mock() end,
      Button = function() local b = CreateFrame(); b.text = mock(); return b end, Close = function() return mock() end,
      Colors = function() return {} end, Accent = function() return 1, 1, 1 end, Media = function(f) return f end,
      GetFrame = function(n) if n == "bags" then return bagFrame end end, For = function() return me end } }
  C_AddOns = { IsAddOnLoaded = function() return true end,
    GetAddOnMetadata = function(a) return ({ Auctionator = "353", DaylightUI = "2.2.7" })[a] end }
  local function diag()
    local t = {}
    for _, l in ipairs(select(2, Diag.Run())) do t[#t + 1] = l end
    return table.concat(t, "\\n")
  end

  -- 1. Daylight UI refuse ShowTab : pas d'onglet vide, Build défait, bouton de repli à l'HV
  refuse = "hook"
  UI.dlTried, UI.dlTab, UI.dlMain, UI.ahButton, ns.Look.me = nil, nil, nil, nil, nil
  out.tabRefused = UI.HookDaylightAH() == false and not UI.dlTab and unhooked == 1
  fire("AUCTION_HOUSE_SHOW")
  out.button = UI.ahButton ~= nil and UI.ahButton:IsShown()
  fire("AUCTION_HOUSE_CLOSED")
  -- 2. bouton des sacs refusé, puis accepté (fenêtre des sacs déjà construite : bouton ajouté tout de suite)
  refuse = true
  Marks.toolHooked = nil
  out.toolRefused = Marks.HookBagTools() == false and not Marks.toolHooked
  refuse = false
  out.toolOk = Marks.HookBagTools() == true and Marks.toolHooked and #bagFrame.tools == 2 and laid == 1
  -- deuxième bouton (trois barres) : allume / éteint les verdicts du bilan
  local vb = bagFrame.tools[2]
  local before = ns.Options.Get("bagVerdicts") and true or false
  vb.scripts.OnClick(vb, "LeftButton")
  out.verdictClick = (ns.Options.Get("bagVerdicts") and true or false) ~= before and vb.kind == "verdict"
  vb.scripts.OnClick(vb, "LeftButton")
  out.diagBad = diag()

  -- 3. tout tient : onglet dans la liste de Daylight UI, fin de scan écoutée, historique lu
  UI.dlTried, UI.dlTab, UI.dlMain = nil, nil, nil
  out.tabOk = UI.HookDaylightAH() == true
  Main.Build()
  Marks.started = true
  local today = math.floor(time() / 86400)
  Auctionator = { EventBus = {}, Constants = { SCAN_DAY_0 = 0 }, Database = { db = {} } }
  local hist = ns.realmDB().hist
  local n = 0
  for id in pairs(hist) do n = n + 1; Auctionator.Database.db[tostring(id)] = { h = { [tostring(today)] = 100 } } end
  ns.Bridge.hooked = true
  local min = Diag.HISTORY_MIN
  Diag.HISTORY_MIN = 1
  out.diagOk = diag()
  -- 4. format de la base Auctionator changé : plus aucun prix lu, le diag le signale
  for k in pairs(Auctionator.Database.db) do Auctionator.Database.db[k] = { x = {} } end
  ns.Bridge.hooked = nil
  out.diagFormat = diag()
  Diag.HISTORY_MIN = min
  out.n = n

  DaylightUI, C_AddOns, ns.Look.me = nil, nil, nil
  UI.dlTried, UI.dlTab, UI.dlMain, UI.ahButton, Marks.toolHooked, Marks.started, ns.Bridge.hooked, Auctionator = unpack(saved, 1, 8)
  return out
end""")(ns)
print("Compatibilité :", {k: compat[k] for k in ("tabRefused", "button", "toolRefused", "toolOk", "tabOk", "n")})
assert compat["tabRefused"] and compat["button"] and compat["toolRefused"] and compat["toolOk"] and compat["tabOk"] and compat["verdictClick"], dict(compat)
bad, good, fmt = strip(compat["diagBad"]), strip(compat["diagOk"]), strip(compat["diagFormat"])
print(good)
assert "Versions : Auctionator 353 · DaylightUI 2.2.7 · API Daylight 1.15" in good, good
assert "MANQUE Onglet AHLedger dans l'HV de Daylight UI" in bad and "OK   Bouton HV dans les sacs de Daylight UI" in bad, bad
assert "OK   Onglet AHLedger dans l'HV de Daylight UI" in good and "OK   Fin de scan Auctionator écoutée" in good, good
assert ("OK   Historique Auctionator : %d objets suivis sur %d ont des prix" % (compat["n"], compat["n"])) in good, good
assert "MANQUE Historique Auctionator" in fmt and "format de sa base changé" in fmt and "MANQUE Fin de scan Auctionator" in fmt, fmt
print("OK : accroches Daylight UI refusées → repli ; /ahl diag vérifie Auctionator et Daylight UI en direct")
# Verdicts du bilan sur les cases des sacs : éteints par défaut (rien n'est calculé), une bande
# perte / stop / prix une fois allumés, flip en cours perdant prioritaire, raison dans l'infobulle
vd = lua.eval("""function(ns)
  local out = {}
  local Marks, Adv, Pos = ns.BagMarks, ns.Advisor, ns.Positions
  local realReview, realEval = Adv.Review, Pos.Evaluate
  local db = Pos.DB()
  local savedPos, savedOpt = db.positions, AHLedgerDB.opt
  local reviews = 0
  Adv.Review = function()
    reviews = reviews + 1
    return { { id = 4306, verdict = "stop", advice = "0 vendu sur 7 mises en vente : arrête l'HV" },
             { id = 4338, verdict = "price", advice = "20 % seulement de tes mises en vente partent" },
             { id = 2589, verdict = "works", advice = "continue" },
             { id = 2592, verdict = "price", advice = "30 % seulement de tes mises en vente partent" } }
  end
  db.positions = { { id = 2592, unit = 300 }, { id = 4306, unit = 500, done = 1 } }
  Pos.Evaluate = function(p) return { verdict = "loss", why = "pas remonté : vends à perte ou garde" } end
  local holder = { CreateTexture = function()
    local t = mock(); t.SetColorTexture = function(self, r, g, b) self.rgb = { r, g, b } end; return t end }
  local painter
  DaylightUI = { API = { major = 1, Skin = function() end, Text = function() return mock() end, Button = function() return mock() end,
    Close = function() end, Colors = function() return {} end, Accent = function() return 1, 1, 1 end, Attach = function() return holder end,
    For = function() return { Paint = function(kind, fn) painter = fn end } end } }
  ns.Look.me, Marks.started = nil, nil
  Marks.Start()
  AHLedgerDB.opt = { bagMarks = "off", ttAway = "compact", ttShift = false }
  ns.ahOpen = true                                       -- verdicts : seulement à l'HV
  ns.dataVersion = ns.dataVersion + 1
  local ids, slots = { 4306, 4338, 2589, 2592 }, {}
  for i, id in ipairs(ids) do slots[i] = {}; painter(slots[i], {}, { bag = 0, slot = i, itemID = id }) end
  out.offNothing = Marks.slots[slots[1]] == nil and reviews == 0
  local function tooltip(id)
    TT = {}
    GameTooltip.GetItem = function() return 'x', '|Hitem:' .. id .. '::::|h' end
    GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
    return table.concat(TT, " / ")
  end
  out.ttOff = tooltip(4306)
  out.on = Marks.ToggleVerdicts(); runTimers()
  local function word(i) local m = Marks.slots[slots[i]]; return m and m.band and m.band.shown and m.word.text or "-" end
  out.words = table.concat({ word(1), word(2), word(3), word(4) }, ",")
  local rgb = Marks.slots[slots[4]].band.rgb
  out.red = rgb[1] > 0.9 and rgb[2] < 0.3
  out.dotHidden = not (Marks.slots[slots[1]].dot and Marks.slots[slots[1]].dot.shown)
  out.reviews = reviews
  out.ttOn = tooltip(4306)
  out.ttLoss = tooltip(2592)
  -- ce que le jeu dit avoir dans les sacs (case 2 liée : pas de bande), et le contrôle de /ahl diag
  C_Container = { GetContainerNumSlots = function(b) return b == 0 and 4 or 0 end,
    GetContainerItemInfo = function(b, s) if b == 0 then return { itemID = ids[s], isBound = s == 2 } end end }
  out.inBags = table.concat(Marks.InBagsText(), ", ")
  local lines = {}
  Marks.Probe(lines)
  out.probe = table.concat(lines, "\\n")
  C_Container = nil
  out.off = Marks.ToggleVerdicts(); runTimers()
  out.hidden = not Marks.slots[slots[1]].band.shown and not Marks.slots[slots[4]].band.shown
  out.ttAfter = tooltip(4306)
  Adv.Review, Pos.Evaluate, db.positions, AHLedgerDB.opt = realReview, realEval, savedPos, savedOpt
  DaylightUI, ns.Look.me = nil, nil
  ns.ahOpen = false
  ns.dataVersion = ns.dataVersion + 1
  return out
end""")(ns)
print("Verdicts sacs :", vd["words"], "| calculs :", vd["reviews"])
print(strip(vd["ttOn"]))
assert vd["offNothing"] and vd["on"] is True and vd["off"] is False, dict(vd)
assert vd["words"] == "stop,prix,-,perte", vd["words"]          # flip en cours perdant > prix ; « ça marche » sans bande
assert vd["red"] and vd["dotHidden"] and vd["reviews"] == 1 and vd["hidden"], dict(vd)
assert "Bilan : ne se vend pas · 0 vendu sur 7" in strip(vd["ttOn"]), vd["ttOn"]
assert "Bilan : flip perdant · flip en cours : acheté 3s 00c/u, pas remonté" in strip(vd["ttLoss"]), vd["ttLoss"]
assert "Bilan :" not in strip(vd["ttOff"]) and "Bilan :" not in strip(vd["ttAfter"]), (vd["ttOff"], vd["ttAfter"])
print("Dans les sacs :", strip(vd["inBags"]))
print(strip(vd["probe"]))
assert strip(vd["inBags"]).endswith("(perte)") and "(stop)" in vd["inBags"] and "prix" not in vd["inBags"], vd["inBags"]
probe = strip(vd["probe"])
assert "Verdicts sur les cases : allumés ; 3 objet(s) au bilan, 2 case(s) concernée(s) dans tes sacs ; Daylight UI nous a passé " in probe, probe
assert "(0:1, stop) : bande montrée" in probe and "(0:4, loss) : bande montrée" in probe and "mot « perte »" in probe, probe
print("OK : verdicts du bilan sur les sacs (bouton / option / /ahl verdicts), éteints par défaut")

# Sacs de Daylight UI restés transparents (fondu bloqué à 0 ou à mi-chemin) : AHLedger remet l'opacité à 1
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
  ns.BagMarks.UnstickSoon(); runTimers()                 -- chemin complet : 1 s puis 0,5 s, grisé figé
  local a3 = moving.items.a
  DaylightUI = saved
  return a1, a2, a3, fine.items.a
end""")(ns)
print("Sacs grisés :", list(us))
assert us[0] == 1 and abs(us[1] - 0.4) < 1e-9 and us[2] == 1 and us[3] == 1, us
print("OK : sacs grisés / invisibles (fondu de Daylight UI bloqué)")

# Ouverture des sacs : la peinture des cases ne calcule rien (pas de chute d'images), le calcul se fait
# par morceaux ensuite ; et un SKILL_LINES_CHANGED sans changement ne vide plus les caches
perf = lua.eval("""function(ns)
  local out = {}
  local v0 = ns.dataVersion
  ns.Prof.ScanSkills()
  out.skillsSame = ns.dataVersion == v0
  local holder = { CreateTexture = function()
    local t = mock(); t.shown = false
    t.Show = function(self) self.shown = true end; t.Hide = function(self) self.shown = false end
    t.SetColorTexture = function(self, r, g, b) self.rgb = { r, g, b } end
    return t end }
  local painter
  DaylightUI = { API = { major = 1, Skin = function() end, Text = function() return mock() end, Button = function() return mock() end,
    Close = function() end, Colors = function() return {} end, Attach = function() return holder end,
    For = function() return { Paint = function(kind, fn) painter = fn end } end } }
  ns.Look.me, ns.BagMarks.started = nil, nil
  ns.BagMarks.Start()
  local savedOpt = AHLedgerDB.opt
  AHLedgerDB.opt = { bagMarks = "always" }
  ns.ahOpen = true
  local real, calls = ns.Analysis.ItemStats, 0
  ns.Analysis.ItemStats = function(...) calls = calls + 1; return real(...) end
  ns.dataVersion = ns.dataVersion + 1
  local ids = { 4306, 4338, 2589, 2592 }
  -- les cases restent référencées (comme dans le jeu, où Daylight UI les garde) : Marks.info a des
  -- clés faibles, une case {} jetable pouvait disparaître au ramasse-miettes en plein calcul
  local slots = {}
  for i = 1, #ids do slots[i] = {} end
  for i, id in ipairs(ids) do painter(slots[i], {}, { bag = 0, slot = i, itemID = id }) end
  out.paintCalls = calls
  runTimers()
  out.warmCalls = calls
  out.ready = ns.Analysis.Ready()
  for _, id in ipairs(ids) do out.ready = out.ready and ns.Decide.Ready(id, math.max(ns.Bags.Count(id), 1)) end
  calls = 0
  for i, id in ipairs(ids) do painter(slots[i], {}, { bag = 0, slot = i, itemID = id }) end
  out.repaintCalls = calls
  ns.Analysis.ItemStats = real
  AHLedgerDB.opt, DaylightUI, ns.Look.me = savedOpt, nil, nil
  ns.ahOpen = false
  ns.dataVersion = ns.dataVersion + 1
  return out
end""")(ns)
print("Sacs, coût :", dict(perf))
assert perf["skillsSame"] is True, dict(perf)
assert perf["paintCalls"] == 0 and perf["warmCalls"] > 0 and perf["ready"] and perf["repaintCalls"] == 0, dict(perf)
print("OK : ouverture des sacs sans calcul (analyse par morceaux, métiers inchangés = caches gardés)")

# Hors de l'HV, AHLedger ne fait rien : ni relecture des sacs, ni relevé marchand, ni réponse aux
# infos d'objet demandées par d'autres addons
away = lua.eval("""function(ns)
  local out = {}
  ns.ahOpen = false
  local scans, realScan = 0, ns.Bags.ScanBags
  ns.Bags.ScanBags = function() scans = scans + 1 end
  fire("BAG_UPDATE_DELAYED"); runTimers()
  out.bagsAway = scans
  fire("AUCTION_HOUSE_SHOW"); runTimers()
  out.bagsAtAH = scans
  fire("AUCTION_HOUSE_CLOSED"); runTimers()
  ns.Bags.ScanBags = realScan
  local db = ns.realmDB()
  MERCHANT = { { "Linen Cloth", 10, 1, -1, 2589 } }
  local before = db.vendor[2589] and db.vendor[2589].p
  fire("MERCHANT_SHOW")
  out.vendorSame = (db.vendor[2589] and db.vendor[2589].p) == before
  local remembered, realRemember = 0, ns.rememberItem
  ns.rememberItem = function(...) remembered = remembered + 1; return realRemember(...) end
  fire("GET_ITEM_INFO_RECEIVED", 4306, true)
  ns.rememberItem = realRemember
  out.infoIgnored = remembered == 0
  out.ahOpen = ns.ahOpen
  return out
end""")(ns)
print("Hors HV :", dict(away))
assert away["bagsAway"] == 0 and away["bagsAtAH"] == 1 and away["vendorSame"] and away["infoIgnored"], dict(away)
assert away["ahOpen"] is False, dict(away)
print("OK : rien hors de l'HV (sacs, marchand, infos d'objet)")

# Supervision : une erreur pendant le calcul des pastilles ne les coupe pas pour la session ;
# un vieux prix PNJ à 0c ne rend pas un composant gratuit ; banque et marchand relus à la demande
fixes = lua.eval("""function(ns)
  local out, Marks = {}, ns.BagMarks
  local real, failed = ns.Analysis.Build, false
  ns.Analysis.Build = function(...) if not failed then failed = true; error("panne simulée") end; return real(...) end
  local errs = #ns.errors
  ns.ahOpen = true
  local savedOpt = AHLedgerDB.opt
  AHLedgerDB.opt = { bagMarks = "always" }
  ns.dataVersion = ns.dataVersion + 1
  Marks.Warm(); runTimers()
  out.errorCaught = failed and #ns.errors > errs
  local calls = 0
  ns.Analysis.Build = function(...) calls = calls + 1; return real(...) end
  ns.dataVersion = ns.dataVersion + 1
  Marks.Warm(); runTimers()
  out.restarted = calls > 0
  -- panne qui se répète : 2 essais au plus pour les mêmes données, puis on attend les suivantes
  local tries = 0
  ns.Analysis.Build = function() tries = tries + 1; error("panne durable") end
  ns.dataVersion = ns.dataVersion + 1
  for _ = 1, 5 do Marks.Warm(); runTimers() end
  out.capped = tries == 2
  ns.dataVersion = ns.dataVersion + 1
  Marks.Warm(); runTimers()
  out.retriedOnNewData = tries == 3
  ns.Analysis.Build = real
  AHLedgerDB.opt = savedOpt
  ns.ahOpen = false
  local db = ns.realmDB()
  local savedV = db.vendor[2589]
  db.vendor[2589] = { p = 0, lim = -1, t = 0 }
  local cost, src = ns.Analysis.ReagentCost(2589)
  out.zeroIgnored = src ~= "PNJ"
  db.vendor[2589] = savedV
  local banks, realBank = 0, ns.Bags.ScanBank
  ns.Bags.ScanBank = function() banks = banks + 1 end
  SlashCmdList.AHLEDGER("banque")
  out.bankClosed = banks
  fire("BANKFRAME_OPENED")
  SlashCmdList.AHLEDGER("banque")
  out.bankOpen = banks
  fire("BANKFRAME_CLOSED")
  ns.Bags.ScanBank = realBank
  MERCHANT = { { "Linen Cloth", 7, 1, -1, 2589 } }
  db.vendor[2589] = nil
  fire("MERCHANT_CLOSED")
  SlashCmdList.AHLEDGER("pnj")
  out.pnjClosed = db.vendor[2589] == nil
  fire("MERCHANT_SHOW")
  SlashCmdList.AHLEDGER("pnj")
  out.pnjOpen = db.vendor[2589] and db.vendor[2589].p
  fire("MERCHANT_CLOSED")
  db.vendor[2589] = savedV
  return out
end""")(ns)
print("Supervision :", dict(fixes))
assert fixes["errorCaught"] and fixes["restarted"] and fixes["capped"] and fixes["retriedOnNewData"], dict(fixes)
assert fixes["zeroIgnored"], dict(fixes)
assert fixes["bankClosed"] == 0 and fixes["bankOpen"] == 1, dict(fixes)
assert fixes["pnjClosed"] and fixes["pnjOpen"] == 7, dict(fixes)
print("OK : pastilles relancées après une erreur, PNJ à 0c ignoré, /ahl banque et /ahl pnj")

# Supervision (suite) : case liée avec les anciennes fonctions, métier sans GetTradeSkillNumMade,
# valeur d'artisanat et ligne « Tu le fabriques » tirées de Decide, verdict d'infobulle déjà calculé
more = lua.eval("""function(ns)
  local out = {}
  -- 1. anciennes fonctions des sacs : le 11e retour (isBound) écarte l'objet lié
  local savedC, savedBags, savedInfo = C_Container, BAGS, GetContainerItemInfo
  C_Container = nil
  BAGS = { [0] = { { 4306, 5 }, { 4338, 2, true } } }
  GetContainerItemInfo = function(b, s)
    local x = BAGS[b] and BAGS[b][s]; if not x then return nil end
    return nil, x[2], false, 1, false, false, nil, false, false, x[1], x[3] or false
  end
  ns.Bags.ScanBags()
  local c = ns.Prof.Char()
  local _, _, isBound = ns.Bags.SlotItem(0, 2)
  out.boundRead = isBound == true
  out.boundSkipped = c.bags[4338] == nil and c.bags[4306] == 5
  ns.ahOpen = true
  out.noDot = ns.BagMarks.KindFor(4338, 0, 2) == nil
  ns.ahOpen = false
  C_Container, BAGS, GetContainerItemInfo = savedC, savedBags, savedInfo
  ns.Bags.ScanBags()
  -- 2. client sans GetTradeSkillNumMade : 1 fabriqué par recette
  local savedMade = GetTradeSkillNumMade
  GetTradeSkillNumMade = function() return 3, 3 end
  ns.Prof.ScanRecipes()
  out.madeWith = ns.Prof.Recipes().firstaid[929].m
  GetTradeSkillNumMade = nil
  ns.Prof.ScanRecipes()
  out.madeWithout = ns.Prof.Recipes().firstaid[929].m
  GetTradeSkillNumMade = savedMade
  ns.Prof.ScanRecipes()
  -- 3. Analysis.Crafts suit Decide.OutValue : PNJ si l'objet fabriqué ne se vend pas, HV sinon
  local D, realOut = ns.Decide, ns.Decide.OutValue
  local function craft929()
    for _, e in ipairs(ns.Analysis.Crafts()) do if e.id == 929 then return e end end
  end
  D.OutValue = function() return { unit = 40, to = "PNJ" }, { v = "no" } end
  local e = craft929()
  out.unsold = e and tostring(e.value) .. "," .. tostring(e.sellTo) .. "," .. tostring(e.sells) .. "," .. tostring(e.vol)
  D.OutValue = function() return { unit = 900, to = "HV" }, { v = "yes" } end
  e = craft929()
  out.sold = e and tostring(e.value) .. "," .. tostring(e.sellTo) .. "," .. tostring(e.sells)
  -- 4. infobulle : « Tu le fabriques » prend le prix et la destination de Decide.OutValue
  D.OutValue = function() return { unit = 123, to = "PNJ" }, { v = "no" } end
  local savedOpt = AHLedgerDB.opt
  AHLedgerDB.opt = { ttAH = "full", ttShift = false }
  ns.ahOpen = true
  ns.dataVersion = ns.dataVersion + 1
  TT = {}
  GameTooltip.AddLine = function(_, t) TT[#TT + 1] = t end
  GameTooltip.AddDoubleLine = function(_, a, b) TT[#TT + 1] = a .. " = " .. b end
  GameTooltip.GetItem = function() return 'x', '|Hitem:929::::|h' end
  GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
  out.ttCraft = "-"
  for _, l in ipairs(TT) do if l:find("Tu le fabriques", 1, true) then out.ttCraft = l end end
  out.ttMoney = ns.money(123)
  D.OutValue = realOut
  -- 5. VerdictIfReady : rien tant que le bilan n'est pas calculé, puis le verdict
  local Adv, realReview = ns.Advisor, ns.Advisor.Review
  Adv.Review = function() return { { id = 4306, verdict = "stop", advice = "0 vendu" } } end
  AHLedgerDB.opt = { bagMarks = "off", bagVerdicts = true }
  ns.dataVersion = ns.dataVersion + 1
  out.notReady = ns.BagMarks.VerdictIfReady(4306) == nil
  runTimers()
  local v = ns.BagMarks.VerdictIfReady(4306)
  out.ready = v and v.kind or "-"
  Adv.Review = realReview
  AHLedgerDB.opt = savedOpt
  ns.ahOpen = false
  ns.dataVersion = ns.dataVersion + 1
  return out
end""")(ns)
print("Supervision (suite) :", dict(more))
assert more["boundRead"] and more["boundSkipped"] and more["noDot"], dict(more)
assert more["madeWith"] == 3 and more["madeWithout"] == 1, dict(more)
assert more["unsold"] == "40,PNJ,no,20", dict(more)
assert more["sold"] == "900,HV,yes", dict(more)
assert "(PNJ)" in more["ttCraft"] and strip(more["ttMoney"]) in strip(more["ttCraft"]), dict(more)
assert more["notReady"] and more["ready"] == "stop", dict(more)
print("OK : case liée (anciennes fonctions), quantité fabriquée par défaut, artisanat et infobulle via Decide, verdict prêt")

# Fiabilité des données : un scan tronqué (liste reçue en partie, 1 839 enchères au lieu de ~40 000
# le 25/11) est refusé ; un scan tronqué déjà enregistré est retiré de l'historique ; un prix plancher
# plus de 3× au-dessus du plus bas habituel n'est pas une vente sûre
trunc = lua.eval("""function(ns)
  local out, db, H = {}, ns.realmDB(), ns.History
  local id = 4306
  local function snap()
    local day = H.today()
    local r = H.parse(db.hist[id] and db.hist[id][day]) or {}
    local d = db.days[day] or {}
    return table.concat({ r.pSum or 0, r.pN or 0, r.qSum or 0, r.sold or 0, r.amb or 0, r.soldVal or 0, r.exp or 0,
      r.mSum or 0, d.scans or 0, d.obs or 0 }, ",")
  end
  -- un scan complet d'abord : la référence de taille
  advance(1800); buildAuctions(); ns.ahOpen = true
  SlashCmdList.AHLEDGER("scan"); runTimers()
  local full = #AUCTIONS
  local before, lastT, book, nScans = snap(), db.lastScanTime, db.book[id], #db.scans
  -- 1. scan tronqué : refusé, rien ne change
  advance(1800)
  AUCTIONS = { { id = id, count = 1, buyout = 99999, owner = "X", tl = 4 } }
  LOG = {}
  SlashCmdList.AHLEDGER("scan"); runTimers()
  local said = table.concat(LOG, " ")
  out.rejected = said:find("Scan incomplet ignoré", 1, true) ~= nil
  out.unchanged = snap() == before and db.lastScanTime == lastT and db.book[id] == book and #db.scans == nScans
  out.noted = db.rejected and db.rejected.n == 1
  -- 2. le même scan enregistré par une version d'avant le garde-fou, puis réparé
  local share = ns.Scan.COMPLETE_SHARE
  ns.Scan.COMPLETE_SHARE = 0
  advance(60)
  SlashCmdList.AHLEDGER("scan"); runTimers()
  ns.Scan.COMPLETE_SHARE = share
  out.polluted = snap() ~= before and db.lastMin[id] == 99999
  local fixed = ns.Scan.Repair(db)
  out.fixed = fixed
  out.restored = snap() == before
  out.lastBack = db.lastScanTime == lastT and db.lastSigs == nil and #db.scans == nScans
  out.minBack = db.lastMin[id] ~= 99999
  out.again = ns.Scan.Repair(db) == 0
  -- 3. plancher 5× le plus bas habituel : « Tester » 1, pas une vente sûre de toute la pile
  local A, realUsual = ns.Analysis, ns.Analysis.UsualMin
  local post = ns.Decide.PostPrice(id, A.Get(id))
  A.UsualMin = function() return post / 5, "Auctionator", 8 end
  -- sans prix d'équilibre (il passerait avant le plus bas habituel)
  local realEq = ns.Market.Equilibrium
  ns.Market.Equilibrium = function() return nil end
  ns.dataVersion = ns.dataVersion + 1
  local d = ns.Decide.For(id, 30)
  out.suspect = d and (d.action .. "," .. d.qty .. "," .. tostring(d.suspect)) or "-"
  out.why = d and d.reason or ""
  A.UsualMin = realUsual
  ns.Market.Equilibrium = realEq
  ns.ahOpen = false
  ns.dataVersion = ns.dataVersion + 1
  buildAuctions()
  return out
end""")(ns)
print("Scan tronqué :", {k: (strip(v) if isinstance(v, str) else v) for k, v in dict(trunc).items()})
assert trunc["rejected"] and trunc["unchanged"] and trunc["noted"], dict(trunc)
assert trunc["polluted"] and trunc["fixed"] == 1 and trunc["restored"] and trunc["lastBack"] and trunc["minBack"] and trunc["again"], dict(trunc)
assert trunc["suspect"] == "Tester,1,true" and "prix douteux" in strip(trunc["why"]), dict(trunc)
print("OK : scan tronqué refusé, ancien scan tronqué retiré de l'historique, prix douteux testé sur 1 seul")

# Scan tronqué, cas limites : juste après la mise à jour (une seule taille connue), réparation quand
# de bons scans ont suivi sans être enregistrés (keepRaw coupé), marché qui a vraiment rétréci,
# annulations retirées, flip sans carnet d'ordres
edge = lua.eval("""function(ns)
  local out, db, Scan = {}, ns.realmDB(), ns.Scan
  local id = 4306
  local tiny = function() return { { id = id, count = 1, buyout = 99999, owner = "X", tl = 4 } } end
  local function scan(list) advance(1800); AUCTIONS = list or (buildAuctions() or AUCTIONS); SlashCmdList.AHLEDGER("scan"); runTimers() end
  ns.ahOpen = true
  -- (a) une seule taille dans scanSizes : le repli sur db.scans complète la référence
  buildAuctions(); scan(AUCTIONS)
  db.scanSizes = { #AUCTIONS }
  local t0 = db.lastScanTime
  scan(tiny())
  out.oneSize = db.lastScanTime == t0
  -- (b) tronqué enregistré (ancienne version), puis un bon scan hors db.scans (keepRaw coupé)
  local share = Scan.COMPLETE_SHARE
  Scan.COMPLETE_SHARE = 0
  scan(tiny())
  Scan.COMPLETE_SHARE = share
  local badT = db.lastScanTime
  local last = db.scans[#db.scans]
  local fields = 0
  for _ in (tostring(last.items):match(id .. "=([^;]*)") or ""):gmatch("[^,]+") do fields = fields + 1 end
  out.canStored = fields == 14
  AHLedgerDB.keepRaw = false
  buildAuctions(); scan(AUCTIONS)
  AHLedgerDB.keepRaw = nil
  local goodT, goodMin = db.lastScanTime, db.lastMin[id]
  out.fixedOne = Scan.Repair(db) == 1
  out.keptNewer = db.lastScanTime == goodT and goodT > badT and db.lastMin[id] == goodMin and next(db.book) ~= nil
  -- (c) 3 scans de suite à la même petite taille : le marché a rétréci, le 3e est gardé
  local small = {}
  for i = 1, 3 do small[i] = { id = id, count = 1, buyout = 500 + i, owner = "X", tl = 4 } end
  local runs = {}
  for i = 1, 3 do local t = db.lastScanTime; scan({ small[1], small[2], small[3] }); runs[i] = db.lastScanTime ~= t end
  out.adoptNoDiff = db.scans[#db.scans].gap == nil -- pas comparé au dernier grand scan : pas de fausses ventes
  out.shrink = tostring(runs[1]) .. "," .. tostring(runs[2]) .. "," .. tostring(runs[3])
  out.newRef = db.scanSizes and #db.scanSizes == 2 and db.scanSizes[2] == 3
  -- le 4e petit scan est gardé aussi : la nouvelle taille tient
  local t4 = db.lastScanTime
  scan({ small[1], small[2], small[3] })
  out.newRefHolds = db.lastScanTime ~= t4
  -- au /reload suivant, la réparation ne retire ni le scan gardé exprès ni ceux qui le suivent
  local nKept = #db.scans
  out.repairKeepsShrink = db.scans[nKept - 1].acc == true and Scan.Repair(db) == 0 and #db.scans == nKept
  -- (d) flip sans carnet d'ordres : pas de prix
  local savedBook = db.book
  db.book = {}
  local price, empty = ns.Positions.SellPrice({ id = id, t = 0, c = 1, unit = 100, reco = {} }, { listed = 0 })
  out.noBook = price == nil and empty == true
  db.book = savedBook
  buildAuctions(); scan(AUCTIONS)
  ns.ahOpen = false
  return out
end""")(ns)
print("Scan tronqué, cas limites :", dict(edge))
assert edge["oneSize"], dict(edge)
assert edge["canStored"] and edge["fixedOne"] and edge["keptNewer"], dict(edge)
assert edge["shrink"] == "false,false,true" and edge["newRef"] and edge["newRefHolds"] and edge["adoptNoDiff"], dict(edge)
assert edge["repairKeepsShrink"], dict(edge)
assert edge["noBook"], dict(edge)
print("OK : une seule taille connue, keepRaw coupé, marché rétréci, flip sans carnet d'ordres")

# Anciens réglages : « toujours » et « seulement à l'HV » = allumées ; ttAway et bagMarksLast retirés
old = lua.eval("""function(ns)
  local O, saved = ns.Options, AHLedgerDB.opt
  local out = {}
  for _, v in ipairs({ "always", "ah", true, "on" }) do
    AHLedgerDB.opt = { bagMarks = v }; out[#out + 1] = O.Get("bagMarks")
  end
  for _, v in ipairs({ false, "off" }) do
    AHLedgerDB.opt = { bagMarks = v }; out[#out + 1] = O.Get("bagMarks")
  end
  AHLedgerDB.opt = { ttAway = "full", bagMarksLast = "ah", bagMarks = "always", ttAH = "compact" }
  O.Cleanup()
  local o = AHLedgerDB.opt
  out[#out + 1] = tostring(o.ttAway) .. "," .. tostring(o.bagMarksLast) .. "," .. o.bagMarks .. "," .. o.ttAH
  ns.ahOpen = false
  out[#out + 1] = O.TooltipMode()
  AHLedgerDB.opt = saved
  return table.concat(out, " ")
end""")(ns)
print("Anciens réglages :", old)
assert old == "on on on on off off nil,nil,on,compact off", old
print("OK : anciens réglages d'options convertis")

# Recherche à l'HV après le scan : moins cher que le plancher du scan → avertissement dans l'infobulle
live = lua.eval("""function(ns)
  local out, id, L = {}, 4306, ns.Live
  local _, _, floor = ns.Decide.PostPrice(id, ns.Analysis.Get(id))
  out.floor = floor ~= nil
  local savedAH, savedOpt = C_AuctionHouse, AHLedgerDB.opt
  local ROWS = {}
  C_AuctionHouse = {
    GetNumCommoditySearchResults = function() return #ROWS end,
    GetCommoditySearchResultInfo = function(_, i) return ROWS[i] end,
  }
  AHLedgerDB.opt = { ttAH = "full", ttShift = false }
  ns.ahOpen = true
  GameTooltip.AddLine = function(_, t) TT[#TT + 1] = t end
  GameTooltip.AddDoubleLine = function(_, a, b) TT[#TT + 1] = a .. " = " .. b end
  GameTooltip.GetItem = function() return 'Silk', '|Hitem:4306::::|h' end
  local function warn()
    ns.dataVersion = ns.dataVersion + 1
    TT = {}
    GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
    for _, l in ipairs(TT) do if l:find("Recherche il y a", 1, true) then return l end end
    return nil
  end
  -- 1. rien de cherché : pas d'avertissement
  out.none = warn() == nil
  -- 2. ta propre enchère, très bas, est ignorée ; une autre à floor - 100 déclenche l'avertissement
  ROWS = { { unitPrice = floor - 500, quantity = 2, numOwnerItems = 2 },
           { unitPrice = floor - 100, quantity = 7, numOwnerItems = 0 },
           { unitPrice = floor, quantity = 10, numOwnerItems = 0 } }
  fire("COMMODITY_SEARCH_RESULTS_UPDATED", id)
  local w = warn()
  out.warn = w or "-"
  out.cheap = ns.money(floor - 100)
  out.post = ns.money(floor - 101)
  out.scanMoney = ns.money(floor)
  -- 3. compact aussi
  AHLedgerDB.opt = { ttAH = "compact", ttShift = false }
  out.compact = warn() ~= nil
  AHLedgerDB.opt = { ttAH = "full", ttShift = false }
  -- 4. recherche au prix du scan : rien à dire
  ROWS = { { unitPrice = floor, quantity = 3, numOwnerItems = 0 } }
  fire("COMMODITY_SEARCH_RESULTS_UPDATED", id)
  out.same = warn() == nil
  -- 5. page Classic : garde le plus bas vu depuis le scan, une page plus chère ne l'efface pas
  L.Record(id, { { unit = floor - 50, qty = 4 } }, true)
  L.Record(id, { { unit = floor + 50, qty = 4 } }, true)
  out.partial = L.Get(id) and L.Get(id).min == floor - 50
  -- 6. un nouveau scan rend la recherche caduque
  local db = ns.realmDB()
  local savedScan = db.lastScanTime
  advance(60); db.lastScanTime = time()
  out.afterScan = warn() == nil
  db.lastScanTime = savedScan
  -- 7. trop vieille
  L.Record(id, { { unit = floor - 50, qty = 4 } })
  advance(L.MAX_AGE + 1)
  out.old = warn() == nil
  C_AuctionHouse, AHLedgerDB.opt = savedAH, savedOpt
  ns.ahOpen = false
  ns.dataVersion = ns.dataVersion + 1
  return out
end""")(ns)
print("Recherche après scan :", dict(live))
assert live["floor"] and live["none"], dict(live)
w = strip(live["warn"])
assert strip(live["cheap"]) in w and strip(live["scanMoney"]) in w and strip(live["post"]) in w and "7 à" in w, dict(live)
assert live["compact"] and live["same"] and live["partial"] and live["afterScan"] and live["old"], dict(live)
print("OK : une recherche moins chère que le scan signale un conseil périmé")

# Anciens scans vus un seul jour : pas une preuve de vente (« inconnu » → 1 à tester), deux jours oui ;
# avec les scans 0.9 (ventes sûres), un seul jour suffit pour « lent »
weak = lua.eval("""function(ns)
  local function s(days, obs9)
    return { obsHours = 48, obs9Hours = obs9, soldSure = 3, surePerDay = 1.5, perDay = 1.5, salesDays = days }
  end
  local D = ns.Decide
  local a, b, c = D.Sells(999301, s(1, 0)), D.Sells(999301, s(2, 0)), D.Sells(999301, s(1, 20))
  return a.v .. "," .. b.v .. "," .. c.v .. "|" .. a.why
end""")(ns)
print("Preuves faibles :", weak)
assert weak.startswith("unknown,yes,slow|") and "ventes pas prouvées" in weak, weak
print("OK : un seul jour d'anciens scans ne prouve pas que ça se vend")
# Sous-cotes : délai entre ta mise en vente et la première enchère moins chère vue (recherche ou scan)
und = lua.eval("""function(ns)
  local U, out = ns.Undercut, {}
  local savedAH = C_AuctionHouse
  local OWNED, ROWS = {}, {}
  C_AuctionHouse = {
    GetNumOwnedAuctions = function() return #OWNED end, GetOwnedAuctionInfo = function(i) return OWNED[i] end,
    GetNumCommoditySearchResults = function() return #ROWS end,
    GetCommoditySearchResultInfo = function(_, i) return ROWS[i] end,
  }
  local function owned(list)
    OWNED = {}
    for _, a in ipairs(list) do
      OWNED[#OWNED + 1] = { itemKey = { itemID = a[1] }, quantity = 1, buyoutAmount = a[2], timeLeftSeconds = 40000, status = 0 }
    end
    fire("OWNED_AUCTIONS_UPDATED")
  end
  local function search(id, price)
    ROWS = price and { { unitPrice = price, quantity = 5, numOwnerItems = 0 } } or {}
    fire("COMMODITY_SEARCH_RESULTS_UPDATED", id)
  end
  local A, B, C, D, E, F = 999401, 999402, 999403, 999404, 999405, 999406
  owned({}) -- lecture de référence
  LOG = {}
  -- A : sous-coté de 1 c en 3 min, trois fois, à 5 h d'écart (trois tranches de la journée)
  for _ = 1, 3 do
    advance(5 * 3600)
    owned({ { A, 1000 } })
    advance(180); search(A, 999)
    owned({})
  end
  -- B : sous-coté au bout de 3 h
  owned({ { B, 500 } }); advance(3 * 3600); search(B, 490); owned({})
  -- C : posté au-dessus du marché déjà vu : pas une sous-cote
  search(C, 300); advance(60); owned({ { C, 400 } }); advance(60); search(C, 290); owned({})
  -- D : jamais revu ; E : vu par deux scans, d'abord encore le moins cher, puis sous-coté
  owned({ { D, 800 }, { E, 700 } })
  advance(60); U.ObserveScan({ [E] = 700 }, time())
  advance(60); U.ObserveScan({ [E] = 650 }, time())
  -- F : pile découpée en 5 enchères, une seule recherche les montre sous-cotées : une seule sous-cote
  owned({ { F, 1000 }, { F, 1000 }, { F, 1000 }, { F, 1000 }, { F, 1000 } }); advance(120); search(F, 990)
  owned({})
  -- G : une enchère déjà sous-cotée sans qu'on le voie, puis une remise au même prix : délai incertain,
  -- pas une sous-cote rapide ni une alerte
  local G = 999407
  owned({ { G, 1000 } }); advance(3600); owned({ { G, 1000 }, { G, 1000 } }); advance(120); search(G, 990)
  owned({})
  out.alert = 0
  for _, l in ipairs(LOG) do if l:find("Sous-coté", 1, true) then out.alert = out.alert + 1 end end
  local by = {}
  for _, e in ipairs(U.Stats()) do by[e.id] = e end
  out.a = by[A] and (by[A].verdict .. "," .. by[A].fast .. "," .. by[A].slots .. "," .. tostring(by[A].step)) or "-"
  out.aWhy = by[A] and by[A].why or "-"
  out.b = by[B] and (by[B].verdict .. "," .. by[B].hits .. "," .. by[B].fast) or "-"
  out.c = by[C] == nil
  out.d = by[D] and (by[D].verdict .. "," .. by[D].unseen) or "-"
  out.e = by[E] and (by[E].verdict .. "," .. by[E].hits) or "-"
  out.f = by[F] and (by[F].verdict .. "," .. by[F].hits .. "," .. by[F].fast .. "," .. tostring(by[F].step)) or "-"
  out.g = by[G] and (by[G].verdict .. "," .. by[G].hits .. "," .. by[G].fast) or "-"
  out.first = U.Stats()[1].id == A
  LOG = {}
  SlashCmdList.AHLEDGER("souscote")
  out.slash = table.concat(LOG, "\\n")
  -- nouvelle visite à l'HV : une enchère déjà en vente (postée hors de vue) n'est pas une mise en vente
  local H, n0 = 999408, #U.DB().posts
  advance(3600); fire("AUCTION_HOUSE_SHOW"); advance(5)
  owned({ { H, 300 } })
  out.visit = #U.DB().posts == n0
  owned({ { H, 300 }, { H, 300 } })
  out.visitPost = #U.DB().posts == n0 + 1
  -- partie pendant l'absence : marquée done à la visite suivante, plus jamais sous-cotée
  local hp = U.DB().posts[#U.DB().posts]
  advance(3600); fire("AUCTION_HOUSE_SHOW"); advance(5)
  owned({})
  out.gone = hp.done ~= nil
  U.Observe(H, 250, time())
  out.noGhost = hp.hit == nil
  -- lecture dans la même seconde que l'ouverture, puis mise en vente : notée
  fire("AUCTION_HOUSE_SHOW")
  owned({})
  local n1 = #U.DB().posts
  advance(30); owned({ { H, 300 } })
  out.sameSecond = #U.DB().posts == n1 + 1
  owned({})
  -- correctif unique : un groupe de 3 objets différents au même instant (1re version) est retiré
  local db = ns.realmDB()
  local keepT = time()
  db.undercut.fix1 = nil
  for i = 1, 3 do table.insert(db.undercut.posts, { id = 999500 + i, unit = 100, t = 12345 }) end
  U.Stats()
  local left = 0
  for _, p in ipairs(db.undercut.posts) do if p.t == 12345 then left = left + 1 end end
  out.fix = left == 0 and db.undercut.fix1 == true and #db.undercut.posts > 0
  C_AuctionHouse = savedAH
  owned = nil
  return out
end""")(ns)
print("Sous-cotes :", dict(und))
assert und["a"] == "bot,3,3,1" and "robot probable" in und["aWhy"] and "toujours" in strip(und["aWhy"]), dict(und)
assert und["b"] == "normal,1,0" and und["c"] and und["d"] == "none,1" and und["e"] == "normal,1", dict(und)
assert und["visit"] and und["visitPost"] and und["gone"] and und["noGhost"] and und["fix"] and und["sameSecond"], dict(und)
assert und["first"] and und["alert"] == 5 and und["f"] == "normal,1,1,nil" and und["g"] == "normal,1,0", dict(und)
sl = strip(und["slash"])
assert "robot probable" in sl and "jamais revue" in sl, sl
lua.execute("SlashCmdList.AHLEDGER('claude')")
assert "## Sous-cotes de mes enchères" in strip(lua.eval("AHLedgerDB.brief.text"))
print("OK : sous-cotes rapides à toute heure → robot probable ; posté au-dessus du marché ignoré")
# Prix rentable d'un objet fabriqué : seuil (à perte dessous), prix rentable (+15 % net), et
# « garder en banque » quand le prix du jour est sous le coût mais que d'habitude il part plus cher
cr = lua.eval("""function(ns)
  local out, D, A = {}, ns.Decide, ns.Analysis
  local saved = { rc = A.ReagentCost, um = A.UsualMin, pp = D.PostPrice, se = D.Sells, opt = AHLedgerDB.opt, eq = ns.Market.Equilibrium }
  ns.Market.Equilibrium = function() return nil end -- repère = le plus bas habituel simulé
  local R = ns.Prof.Recipes()
  R.zztest = { [929] = { n = "Healing Potion", r = { [4306] = 2, [3371] = 1 }, m = 1 } }
  local costs = { [4306] = 1000, [3371] = 500 }
  A.ReagentCost = function(id) if costs[id] then return costs[id], "HV" end end
  D.Sells = function() return { v = "yes", p = 1, rate = 5, src = "scans", why = "~5 ventes sûres/j" } end
  local post, usual
  D.PostPrice = function() return post, "1c sous la moins chère", post end
  A.UsualMin = function() if usual then return usual, "scans", 7 end end
  local function case(p, u)
    post, usual = p, u
    ns.dataVersion = ns.dataVersion + 1
    local d = D.For(929, 5)
    local line, state = D.CostLine(d)
    return { action = d.action, hold = d.hold or false, holdAt = d.holdAt, line = D.Line(d), cost = line or "-",
             state = state or "-", warn = table.concat(d.warn, " / "), why = D.Why(d) }
  end
  local cc = D.CraftCost(929)
  out.unit, out.floor, out.target = cc.unit, cc.floor, cc.target
  out.ok = case(4000)
  out.thin = case(2800)
  out.hold = case(2100, cc.floor + 20)
  out.loss = case(2100, cc.floor - 400)
  -- objet en « garder en banque » qu'une de tes recettes transforme : Fabriquer, plus de « garder »
  R.zztest[5000] = { n = "Test Output", r = { [929] = 1 }, m = 1 }
  out.up = case(2100, cc.floor + 20)
  R.zztest[5000] = nil
  -- vue Artisanat : « Vendre dès » = prix rentable
  for _, e in ipairs(A.Crafts()) do if e.id == 929 and e.prof == "zztest" then out.minPrice = e.minPrice end end
  -- infobulle courte (onglet de vente de l'HV) : la ligne de rentabilité y est
  post, usual = 4000, nil
  ns.dataVersion = ns.dataVersion + 1
  AHLedgerDB.opt = { ttAH = "compact", ttShift = false }
  ns.ahOpen = true
  TT = {}
  GameTooltip.AddLine = function(_, t) TT[#TT + 1] = t end
  GameTooltip.AddDoubleLine = function(_, a, b) TT[#TT + 1] = a .. " = " .. b end
  GameTooltip.GetItem = function() return 'x', '|Hitem:929::::|h' end
  GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
  out.tt = table.concat(TT, " / ")
  ns.ahOpen = false
  R.zztest = nil
  A.ReagentCost, A.UsualMin, D.PostPrice, D.Sells, AHLedgerDB.opt = saved.rc, saved.um, saved.pp, saved.se, saved.opt
  ns.Market.Equilibrium = saved.eq
  ns.dataVersion = ns.dataVersion + 1
  return out
end""")(ns)
import math
keep = 1 - ns.Analysis.AH_CUT
ok, thin, hold, loss = (dict(cr[k]) for k in ("ok", "thin", "hold", "loss"))
up = dict(cr["up"])
assert up["action"] == "Fabriquer" and not up["hold"] and up.get("holdAt") is None, up
print("Prix rentable :", cr["unit"], cr["floor"], cr["target"], ok, thin, hold, loss, cr["minPrice"], strip(cr["tt"])[:300])
assert cr["unit"] == 2500 and cr["floor"] == math.ceil(2500 / keep) and cr["target"] == math.ceil(2500 * 1.15 / keep), dict(cr)
assert ok["action"] == "HV" and ok["state"] == "ok" and "Rentable dès" in strip(ok["cost"]) and "Rentable dès" in strip(ok["why"]), ok
assert thin["action"] == "HV" and thin["state"] == "thin" and "marge faible" in thin["warn"], thin
assert hold["action"] == "Attendre" and hold["hold"] and hold["holdAt"] == cr["floor"], hold
assert "Garder en banque" in strip(hold["line"]) and hold["state"] == "loss", hold
assert loss["action"] == "HV" and not loss["hold"] and "n'en fabrique plus" in loss["warn"], loss
assert cr["minPrice"] == cr["target"], dict(cr)
assert "Rentable dès" in strip(cr["tt"]), cr["tt"]
print("OK : prix rentable d'un objet fabriqué, marge faible, garder en banque, vente à perte signalée")
# 1.0, phase 1 : un seul calcul par chiffre (prix net, prix de mise en vente, coût d'une recette,
# bilan), prix douteux jamais « prouvé », garde-fous de données
p1 = lua.eval("""function(ns)
  local out, D, A = {}, ns.Decide, ns.Analysis
  local db = ns.realmDB()
  local c = ns.Prof.Char()
  local saved = { pp = D.PostPrice, um = A.UsualMin, se = D.Sells, rc = A.ReagentCost, hist = ns.Bridge and ns.Bridge.History,
                  auctions = c.auctions, bags = c.bags, bank = c.bank, skills = c.skills }
  -- (a) prix net : une seule formule
  local id = 4338
  ns.dataVersion = ns.dataVersion + 1
  local d = D.For(id, 5)
  local s = A.Get(id)
  out.netSame = d and d.post and math.abs(d.ahNet - A.NetAt(d.post, s, D.VendorPrice(id), d.sells.p)) < 0.01
  out.posSame = math.abs(ns.Positions.NetAt(s, 1000) - A.NetAt(1000, s)) < 0.01
  -- (b) coût d'un composant : on parcourt les enchères pour la quantité voulue
  local rid = 999501
  AHLedgerDB.items[rid] = { n = "Composant test", s = 0 }
  db.book[rid] = ns.Scan.PackBook({ { 100, 1 }, { 1000, 10 } }, 0, 0)
  out.rc1 = A.ReagentCost(rid, 1)
  out.rc5 = A.ReagentCost(rid, 5)
  db.book[rid] = nil
  -- (c) plus bas habituel d'Auctionator contredit par les ventes vues : écarté
  if ns.Bridge then
    local v = 1000
    ns.Bridge.History = function() return { { -1, v }, { -2, v }, { -3, v }, { -4, v }, { -5, v } } end
    local fake = { realPrice = 5000, salesDays = 3 }
    out.usualOff = A.UsualMin(1, fake) == nil
    v = 4000
    out.usualOn = A.UsualMin(1, fake) == 4000
    ns.Bridge.History = saved.hist
  end
  -- (d) Mes enchères : un prix du marché douteux ne fait pas reprendre l'enchère, et n'est pas « prouvé »
  D.Sells = function() return { v = "yes", own = true, src = "courrier", p = 0.8, rate = 5, why = "tes ventes" } end
  D.PostPrice = function() return 4699, "1c sous la moins chère (47s)", 4700 end
  local usual = 1000
  A.UsualMin = function() return usual, "Auctionator", 8 end
  local realEq = ns.Market.Equilibrium
  ns.Market.Equilibrium = function() return nil end -- repère = le plus bas habituel simulé
  c.auctions = { t = time(), list = { { id = id, qty = 5, unit = 4799, bid = 0, left = 40000 } } }
  ns.dataVersion = ns.dataVersion + 1
  local e = ns.Advisor.Auctions()[1]
  out.suspectVerdict, out.suspectConf = e.verdict, e.conf
  usual = 4000
  ns.dataVersion = ns.dataVersion + 1
  e = ns.Advisor.Auctions()[1]
  out.okVerdict, out.okConf = e.verdict, e.conf
  out.relistGold = e.gold
  out.relistGross = math.floor(4699 * 5 * (1 - A.AH_CUT))
  ns.Market.Equilibrium = realEq
  -- (e) Mes enchères : au-dessus du prix réel mais sous la moins chère des autres = pas « trop cher »
  c.auctions = { t = time(), list = { { id = id, qty = 5, unit = 4600, bid = 0, left = 40000 } } }
  local groups = ns.Auctions.Summary()
  out.status = groups[1].status
  -- (f) PNJ « rentable » seulement avec la marge
  local cc = { unit = 1000, floor = 1100, target = 1250 }
  local function pnj(v) local _, st = D.CostLine({ cost = cc, action = "PNJ", vendor = v }); return st end
  out.pnj = table.concat({ pnj(1200), pnj(1050), pnj(900) }, ",")
  -- (g) composant que tu as ou que tu récoltes : il coûte ce qu'il te rapporterait brut
  D.Sells = function() return { v = "no", p = 0.1, why = "-" } end
  A.ReagentCost = function(x) if x == rid then return 500, "HV" end return saved.rc(x) end
  AHLedgerDB.items[rid] = { n = "Minerai test", s = 100, c = 7, sc = 7 }
  c.bags, c.bank, c.skills = {}, {}, {}
  for k, v in pairs(saved.skills or {}) do c.skills[k] = v end
  c.skills.mining = nil
  ns.dataVersion = ns.dataVersion + 1
  local cost, src = D.ReagentCost(rid, 2)
  out.buy = cost .. "," .. src
  c.bags[rid] = 4
  ns.bagVersion = (ns.bagVersion or 0) + 1
  cost, src = D.ReagentCost(rid, 2)
  out.owned = cost .. "," .. src
  c.bags[rid] = nil
  c.skills.mining = 150
  ns.dataVersion = ns.dataVersion + 1
  cost, src = D.ReagentCost(rid, 2)
  out.mined = cost .. "," .. src
  out.recipe = D.RecipeCost({ r = { [rid] = 2 } })
  -- remise en état
  D.PostPrice, A.UsualMin, D.Sells, A.ReagentCost = saved.pp, saved.um, saved.se, saved.rc
  c.auctions, c.bags, c.bank, c.skills = saved.auctions, saved.bags, saved.bank, saved.skills
  AHLedgerDB.items[rid] = nil
  ns.dataVersion = ns.dataVersion + 1
  -- (h) commission mesurée absurde : bornée
  local L = ns.Ledger.DB()
  local ledger = L.ledger
  L.ledger = {}
  for i = 1, 6 do L.ledger[i] = { k = "sold", t = time() - i, id = id, c = 1, g = 1000, cut = 300 } end
  ns.Ledger.Calibrate()
  out.cut = A.AH_CUT
  L.ledger = ledger
  ns.Ledger.Calibrate()
  -- (i) erreurs gardées dans les SavedVariables
  ns.safe("test phase 1", function() error("boum") end)
  local errs = AHLedgerDB.errors or {}
  out.err = errs[#errs] or ""
  -- (j) rapport et /ahl bilan : le bilan réel de Tracker
  local _, _, tot = ns.Tracker.Compute()
  out.real = tot.real
  SlashCmdList.AHLEDGER("claude")
  out.brief = AHLedgerDB.brief.text
  out.headline = ns.Tracker.Headline(tot)
  return out
end""")(ns)
p1d = dict(p1)
print("Phase 1 :", {k: (strip(v)[:120] if isinstance(v, str) else v) for k, v in p1d.items() if k != "brief"})
assert p1d["netSame"] and p1d["posSame"], p1d
assert p1d["rc1"] == 100 and p1d["rc5"] == (100 + 4 * 1000) / 5, p1d
if "usualOff" in p1d:
    assert p1d["usualOff"] and p1d["usualOn"], p1d
assert p1d["suspectVerdict"] == "keep" and p1d["suspectConf"] == "à tester", p1d
assert p1d["okVerdict"] == "relist" and p1d["okConf"] == "prouvé", p1d
assert p1d["relistGold"] < p1d["relistGross"], p1d  # nouveau dépôt déduit
assert p1d["status"] == "ok", p1d
assert p1d["pnj"] == "ok,thin,loss", p1d
assert p1d["buy"] == "500,HV" and p1d["owned"] == "100,toi" and p1d["mined"] == "100,toi" and p1d["recipe"] == 200, p1d
assert abs(p1d["cut"] - 0.10) < 1e-9, p1d
assert "test phase 1 : " in p1d["err"] and "boum" in p1d["err"], p1d
brief = strip(p1d["brief"])
sec = brief.split("## Bilan réel")[1].split("\n## ")[0] if "## Bilan réel" in brief else ""
assert "bilan réel" in sec and "solde" not in sec, sec[:600]

# Scan partiel (35 à 60 % de la taille habituelle) : prix gardés, mais pas comparé au précédent
part = lua.eval("""function(ns)
  local out, db = {}, ns.realmDB()
  advance(1800); buildAuctions(); ns.ahOpen = true
  SlashCmdList.AHLEDGER("scan"); runTimers()
  local full = {}
  for i, a in ipairs(AUCTIONS) do full[i] = a end
  local half = {}
  for i = 1, math.floor(#full / 2) do half[i] = full[i] end
  db.scanSizes = { #full, #full, #full } -- référence connue (les tests d'avant l'ont fait varier)
  local sigsFull, tFull = db.lastSigs, db.lastScanTime
  advance(1800)
  AUCTIONS = half
  LOG = {}
  SlashCmdList.AHLEDGER("scan"); runTimers()
  out.said = table.concat(LOG, " ")
  out.partial = db.partial and db.partial.n == #half
  out.noDiff = db.scans[#db.scans].gap == nil
  out.stored = db.lastScanTime ~= nil and db.scans[#db.scans].total == #half
  -- le scan partiel ne devient pas la comparaison du suivant : on garde le dernier scan complet
  out.baseKept = db.lastSigs == sigsFull and db.sigsTime == tFull and db.lastScanTime ~= tFull
  -- scan complet suivant, mêmes enchères : comparé au complet d'il y a 1 h, aucune « nouvelle » enchère
  advance(1800)
  AUCTIONS = full
  SlashCmdList.AHLEDGER("scan"); runTimers()
  local last, posted = db.scans[#db.scans], 0
  for rest in tostring(last.items):gmatch("%d+=([^;]*)") do
    local f = {}
    for v in rest:gmatch("[^,]+") do f[#f + 1] = tonumber(v) or 0 end
    posted = posted + (f[9] or 0)
  end
  out.diffVsFull = last.gap == 3600 and posted == 0
  out.posted = posted
  ns.ahOpen = false
  buildAuctions()
  ns.dataVersion = ns.dataVersion + 1
  return out
end""")(ns)
partd = dict(part)
print("Scan partiel :", {k: (strip(v)[:160] if isinstance(v, str) else v) for k, v in partd.items()})
assert "Scan partiel" in strip(partd["said"]) and partd["partial"] and partd["noDiff"] and partd["stored"], partd
assert partd["baseKept"] and partd["diffVsFull"], partd
print("OK : 1.0 phase 1 — un seul prix net, coût de recette (composants à toi = valeur brute), prix douteux non prouvé, scan partiel sans ventes, commission bornée, erreurs gardées")


# Phase 1, retours du superviseur : scans partiels répétés, erreur pendant la lecture, scan périmé,
# borne basse du dépôt
p1b = lua.eval("""function(ns)
  local out, db = {}, ns.realmDB()
  advance(1800); buildAuctions(); ns.ahOpen = true
  SlashCmdList.AHLEDGER("scan"); runTimers()
  local full = {}
  for i, a in ipairs(AUCTIONS) do full[i] = a end
  local usual0 = ns.Scan.UsualSize(db)
  -- (a) scans partiels de suite : la taille de référence ne baisse pas, puis la nouvelle taille est adoptée
  local half = {}
  for i = 1, math.floor(#full / 2) do half[i] = full[i] end
  local sizes = {}
  for k = 1, 3 do
    advance(1800); AUCTIONS = half; LOG = {}
    SlashCmdList.AHLEDGER("scan"); runTimers()
    sizes[k] = ns.Scan.UsualSize(db)
    if k == 2 then out.noDiff2 = db.scans[#db.scans].gap == nil end
    if k == 3 then out.adoptSaid = table.concat(LOG, " ") end
  end
  out.keep1 = sizes[1] == usual0 and sizes[2] == usual0
  out.adopted = sizes[3] == #half
  -- (b) lignes illisibles (plus de 20 et plus de 2 %) : scan partiel aussi
  local big = {}
  for k = 1, 10 do for _, a in ipairs(full) do local c = {}; for x, y in pairs(a) do c[x] = y end; big[#big + 1] = c end end
  AUCTIONS = big
  advance(1800); SlashCmdList.AHLEDGER("scan"); runTimers()
  advance(1800)
  local realInfo = GetAuctionItemInfo
  GetAuctionItemInfo = function(t, i)
    if i > #big - 25 then return nil end
    return realInfo(t, i)
  end
  LOG = {}
  SlashCmdList.AHLEDGER("scan"); runTimers()
  out.holesSaid = table.concat(LOG, " ")
  out.holesNoDiff = db.scans[#db.scans].gap == nil
  -- (c) erreur pendant la lecture : le scan s'arrête au lieu de rester « en cours »
  GetAuctionItemInfo = function() error("ligne cassée") end
  advance(1800); LOG = {}
  SlashCmdList.AHLEDGER("scan"); runTimers()
  out.stopped = not ns.Scan.running
  out.errSaid = table.concat(LOG, " ")
  GetAuctionItemInfo = realInfo
  AUCTIONS = full
  ns.ahOpen = false
  -- (d) scan périmé : aucun achat conseillé nulle part
  local A = ns.Analysis
  local realFF = A.FlipFor
  A.FlipFor = function(s) return { kind = "now", id = s.id, s = s, qty = 1, cost = 1, maxBuy = 1, resale = 2, profit = 1000, roi = 9, days = 1 } end
  ns.dataVersion = ns.dataVersion + 1
  out.freshFlips = #A.Flips() > 0
  advance((ns.Decide.STALE_HOURS + 1) * 3600)
  ns.dataVersion = ns.dataVersion + 1
  out.stale = A.Stale()
  out.staleFlips = #A.Flips()
  local _, _, staleV = A.VendorFlips()
  out.staleVendor = staleV == true
  local anyFlip = false
  for _, e in ipairs(ns.Advisor.Actions()) do if e.kind == "flip" or e.kind == "vendor" then anyFlip = true end end
  out.adviceFlip = anyFlip
  ns.UI.Build()
  ns.UI.SetMode("flip")
  out.staleEmpty = ns.UI.empty:GetText() or ""
  local savedSn = ns.realmDB().snipes
  ns.realmDB().snipes = { { id = 4306, profit = 500, unit = 100, vendor = 600, qty = 1 } }
  out.staleReport = ns.Export.Build()
  ns.realmDB().snipes = savedSn
  -- infobulle : plus de ligne « Flip » ni « PNJ → HV »
  local db2 = ns.realmDB()
  db2.book = db2.book or {}
  local savedBook = db2.book[4306]
  db2.book[4306] = "2,500|500:12 950:40"
  TT = {}
  GameTooltip.GetItem = function() return 'Silk', '|Hitem:4306::::|h' end
  GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
  local ttFlip = false
  for _, x in ipairs(TT) do if tostring(x):find("Flip") or tostring(x):find("PNJ → HV") then ttFlip = true end end
  out.ttFlip = ttFlip
  -- achat sans conseil vu : pas de flip suivi
  local P = ns.Positions.DB()
  P.recos[4306] = nil
  local nPos = #P.positions
  out.boughtNone = ns.Positions.Bought(4306, 1, 100) == nil and #P.positions == nPos
  db2.book[4306] = savedBook
  -- Revente PNJ : aucune ligne, et le message du scan périmé
  local savedSnipes = db2.snipes
  db2.snipes = { { id = 4306, profit = 500, unit = 100, vendor = 600, qty = 1 } }
  ns.UI.SetMode("snipe")
  out.snipeEmpty = ns.UI.empty:GetText() or ""
  out.snipeRows = ns.UI.empty:IsShown() and 0 or 1
  db2.snipes = savedSnipes
  A.FlipFor = realFF
  -- (e) dépôt mesuré absurde (trop bas) : borné à 5 % du prix PNJ
  local L = ns.Ledger.DB()
  local ledger = L.ledger
  local id = next(AHLedgerDB.items)
  local meta = AHLedgerDB.items[id]
  local s0 = meta.s
  meta.s = 1000
  L.ledger = {}
  for i = 1, 6 do L.ledger[i] = { k = "sold", t = time() - i, id = id, c = 1, g = 1000, cut = 50, dep = 1 } end
  ns.Ledger.Calibrate()
  out.dep = A.DEPOSIT_RATE
  L.ledger = ledger
  meta.s = s0
  ns.Ledger.Calibrate()
  advance(1800); buildAuctions(); ns.ahOpen = true
  SlashCmdList.AHLEDGER("scan"); runTimers()
  ns.ahOpen = false
  ns.dataVersion = ns.dataVersion + 1
  return out
end""")(ns)
p1bd = dict(p1b)
print("Phase 1 (superviseur) :", {k: (strip(v)[:160] if isinstance(v, str) else v) for k, v in p1bd.items()})
assert p1bd["keep1"] and p1bd["noDiff2"] and p1bd["adopted"] and "nouvelle taille" in strip(p1bd["adoptSaid"]), p1bd
assert "Scan partiel" in strip(p1bd["holesSaid"]) and "illisibles" in strip(p1bd["holesSaid"]) and p1bd["holesNoDiff"], p1bd
assert p1bd["stopped"] and "ligne cassée" in strip(p1bd["errSaid"]), p1bd
assert p1bd["freshFlips"] and p1bd["stale"] and p1bd["staleFlips"] == 0 and p1bd["staleVendor"] and not p1bd["adviceFlip"], p1bd
assert "aucun achat" in strip(p1bd["staleEmpty"]), p1bd
_rep = strip(p1bd["staleReport"])
assert "aucun achat conseillé, rescanne l'HV" in _rep and "## Revente PNJ" not in _rep, _rep[:2000]
assert not p1bd["ttFlip"] and p1bd["boughtNone"] and p1bd["snipeRows"] == 0 and "aucun achat" in strip(p1bd["snipeEmpty"]), p1bd
assert abs(p1bd["dep"] - 0.05) < 1e-9, p1bd
print("OK : 1.0 phase 1 — scans partiels hors référence, lignes illisibles, erreur de lecture, scan périmé sans achat, dépôt borné")

# 1.0, phase 2 : prix d'équilibre, journal du marché, chances de vente, délai, durée, Midas en second recours
p2 = lua.eval("""function(ns)
  local out, db, M, D, H = {}, ns.realmDB(), ns.Market, ns.Decide, ns.History
  local function bump() ns.dataVersion = ns.dataVersion + 1 end
  local function pack(...) local t = { ... }; for i = 1, select("#", ...) do t[i] = tostring(t[i]) end; return table.concat(t, ",") end
  local today = H.today()
  -- (a) équilibre : médiane pondérée par jour (v9 seulement, 7 jours), un jour aberrant ne la déplace pas
  local id = 999500
  db.hist[id] = {
    [today] = "12,1,10,4,0,40,0,0,12",              -- 4 vendus à 10c (affiché 12c)
    [today - 1] = "12,1,10,10,0,120,0,0,12",        -- 10 à 12c
    [today - 2] = "12,1,10,1,0,500,0,0,12",         -- 1 à 500c (aberrant)
    [today - 3] = "1000,1,10,50,0,50000,0,0",       -- ancien format (retraits comptés) : ignoré
    [today - 9] = "1000,1,10,50,0,50000,0,0,1000",  -- hors fenêtre
  }
  -- jours observés de bout en bout en 0.9 (sauf la veille de l'ancien format)
  local savedDays = {}
  for dd = today - 9, today do
    savedDays[dd] = db.days[dd]
    db.days[dd] = { obs = 3600, o9 = 3600, scans = 1 }
  end
  bump()
  out.eq = pack(M.Equilibrium(id))
  out.eqText = M.EqText(id)
  -- un jour pas entièrement observé en 0.9 ne compte pas
  db.days[today - 1] = { obs = 3600, o9 = 1800, scans = 1 }
  bump()
  out.eqPart = pack(M.Equilibrium(id))
  db.days[today - 1] = { obs = 3600, o9 = 3600, scans = 1 }
  -- équilibre loin du prix affiché du jour (pile bradée vite rachetée) : écarté, comme le prix réel
  local keepToday = db.hist[id][today]
  db.hist[id][today] = "1000,1,10,4,0,40,0,0,1000"
  bump()
  out.eqFar = pack(M.Equilibrium(id))
  db.hist[id][today] = keepToday
  out.lowText = M.Text({ odds = 0.07, oddsSrc = "tes ventes", hours = 0.5, dur = 12 })
  -- un seul jour de ventes : pas d'équilibre ; Midas en second recours s'il est prêt
  db.hist[id] = { [today] = "12,1,10,4,0,40,0,0,12" }
  bump()
  out.eqThin = pack(M.Equilibrium(id))
  _G.MidasAPI = { IsReady = function() return true end, GetFairPrice = function() return 13.6 end,
                  GetSellOdds = function() return 0.42 end, GetVersion = function() return "1.3.7", 1 end }
  bump()
  out.eqMidas = pack(M.Equilibrium(id))
  _G.MidasAPI.GetFairPrice = function() return 777 end
  bump()
  out.eqMidasFar = pack(M.Equilibrium(id))
  out.midasText = M.Text({ odds = 0.42, oddsSrc = "Midas", hours = 100, dur = 48 })
  out.status = ns.MidasLink.Status()
  _G.MidasAPI.GetFairPrice = function() error("boum Midas") end
  bump()
  out.eqMidasErr = pack(M.Equilibrium(id))
  _G.MidasAPI.IsReady = function() return false end
  bump()
  out.eqMidasNotReady = pack(M.Equilibrium(id))
  _G.MidasAPI = nil
  out.statusAbsent = ns.MidasLink.Status()
  db.hist[id] = nil
  for dd = today - 9, today do db.days[dd] = savedDays[dd] end

  -- (b) Scan.Diff : vendue (temps en rayon connu) et expirée notées dans b.ev
  local T0 = time() - 7200
  local prev = { ["999501:1:500:?"] = { c = 1, tl = 4, f = T0 }, ["999501:1:600:?"] = { c = 1, tl = 1, f = T0 },
                 ["999501:1:700:?"] = { c = 1, tl = 4 } }
  local diff = ns.Scan.Diff(prev, {}, 3600, T0 + 7200)
  local ev = {}
  for _, e in ipairs(diff[999501].ev or {}) do ev[#ev + 1] = ("%s:%d:%d:%s"):format(e.sold and "s" or "e", e.unit, e.n, tostring(e.life)) end
  table.sort(ev)
  out.ev = table.concat(ev, " ")
  out.evNoNow = ns.Scan.Diff(prev, {}, 3600)[999501].ev[1].life == nil

  -- (c) journal : écrit, relu, purgé après 14 jours, 40 enchères au plus
  local jid = 999502
  db.sales = db.sales or {}
  db.sales[jid] = nil
  M.Record(db, jid, { { sold = true, unit = 900, n = 5, life = 3 } }, time() - 15 * 86400)
  M.Record(db, jid, { { sold = true, unit = 950, n = 5, life = 2.25 }, { sold = false, unit = 1200, n = 1 } }, time())
  bump()
  local log = M.Log(jid)
  out.log = #log .. "," .. db.sales[jid]
  local many = {}
  for i = 1, 50 do many[i] = { sold = true, unit = 900 + i, n = 1, life = i } end
  M.Record(db, 999503, many, time())
  bump()
  out.cap = #M.Log(999503)
  db.sales[999503] = nil
  db.sales[999504] = "100,5,1,s,10"
  M.Prune(db, time())
  out.pruned = db.sales[999504] == nil and db.sales[jid] ~= nil
  db.sales[999506] = ("%d,100,1,s,10;%d,100,1,s,20"):format(time() - 20 * 86400, time())
  bump()
  out.oldIgnored = #M.Log(999506)
  db.sales[999506] = nil

  -- (d) chances et délai à un prix donné : 6 ventes à ~980, 4 expirations à 1200
  local evs = {}
  for i = 1, 6 do evs[#evs + 1] = { sold = true, unit = 980, n = 1, life = 2 * i } end
  for _ = 1, 4 do evs[#evs + 1] = { sold = false, unit = 1200, n = 1 } end
  db.sales[jid] = nil
  M.Record(db, jid, evs, time())
  bump()
  out.odds980 = pack(M.Odds(jid, 980))
  out.odds1100 = pack(M.Odds(jid, 1100))
  out.odds1300 = pack(M.Odds(jid, 1300))  -- 4 expirations seulement : pas assez
  out.hours = pack(M.Hours(jid, 980, 1, nil, 0))
  out.hoursMany = pack(M.Hours(jid, 980, 10, { surePerDay = 24 }, 14))
  out.hoursRate = pack(M.Hours(jid, 2000, 2, { surePerDay = 12 }, 4))
  out.hoursNone = M.Hours(jid, 2000, 2, nil, 0) == nil
  out.dur = pack(M.Duration(7), M.Duration(12), M.Duration(24), M.Duration(nil))

  -- (e) prix de mise en vente face à un bradage, et objet surveillé par un robot
  AHLedgerDB.items[jid] = { n = "Objet test équilibre", s = 10 }
  local realEq, realSells, realStats, realGet = M.Equilibrium, D.Sells, ns.Undercut.Stats, ns.Analysis.Get
  local fakeS = { surePerDay = 10, obs9Hours = 24, obsHours = 24, salesDays = 5 }
  ns.Analysis.Get = function(i) if i == jid then return fakeS end return realGet(i) end
  M.Equilibrium = function(i) if i == jid then return 1000, "tes scans", 30, 5 end return realEq(i) end
  D.Sells = function() return { v = "yes", src = "scans", p = 0.7, rate = 10, why = "~10 ventes sûres/j" } end
  ns.Undercut.Stats = function() return {} end
  db.book[jid] = "0,0|500:3,980:10,1100:20"     -- 3 bradées à 5s, puis le prix normal
  bump()
  local post, why, first, info = D.PostPrice(jid, nil, 10)
  out.small = pack(post, first, info.ahead, info.dump, tostring(info.bigDump))
  out.smallWhy = why
  local d = D.For(jid, 5)
  out.smallAction = d.action .. "," .. d.post
  out.smallWhyAll = D.Why(d)
  out.proj = d.proj and pack(d.proj.odds, d.proj.oddsSrc, d.proj.oddsN, d.proj.hours, d.proj.hoursSrc, d.proj.dur) or "-"
  db.book[jid] = "0,0|500:30,980:10"             -- 30 bradées : plus qu'un jour de ventes
  bump()
  post, why, first, info = D.PostPrice(jid, nil, 10)
  out.big = pack(post, tostring(info.bigDump), info.dump)
  d = D.For(jid, 5)
  out.bigAction = d.action
  out.bigReason = d.reason
  -- robot probable : pas de course au centime, prix d'équilibre et heure calme
  db.book[jid] = "0,0|970:10,1100:20"
  ns.Undercut.Stats = function() return { { id = jid, verdict = "bot", quiet = { 3 } } } end
  bump()
  post, why, first, info = D.PostPrice(jid, nil, 10)
  out.bot = pack(post, info.watch and info.watch.verdict, info.ahead)
  out.botWhy = why
  -- sans équilibre : la règle d'avant (1c sous la moins chère), robot ou pas
  M.Equilibrium = function() return nil end
  bump()
  post = D.PostPrice(jid, nil, 10)
  out.noEq = post
  M.Equilibrium, D.Sells, ns.Undercut.Stats, ns.Analysis.Get = realEq, realSells, realStats, realGet
  db.book[jid], db.sales[jid], AHLedgerDB.items[jid] = nil, nil, nil
  bump()

  -- (f) heures calmes d'un objet sous-coté par un robot (Undercut.Stats)
  local u = ns.Undercut.DB()
  local savedPosts = u.posts
  local t0 = time() - 2 * 86400
  t0 = t0 - (tonumber(date("%H", t0)) * 3600 + tonumber(date("%M", t0)) * 60 + tonumber(date("%S", t0)))
  local uid = 999505
  u.posts = {
    { id = uid, unit = 100, t = t0 + 2 * 3600, hit = t0 + 2 * 3600 + 60, by = 99, gap = 1 },
    { id = uid, unit = 100, t = t0 + 10 * 3600, hit = t0 + 10 * 3600 + 60, by = 99, gap = 1 },
    { id = uid, unit = 100, t = t0 + 18 * 3600, hit = t0 + 18 * 3600 + 60, by = 99, gap = 1 },
    { id = uid, unit = 100, t = t0 + 14 * 3600, ok = t0 + 14 * 3600 + 600 },
  }
  for _, e in ipairs(ns.Undercut.Stats()) do
    if e.id == uid then out.quiet = e.verdict .. ":" .. table.concat(e.quiet, ",") end
  end
  u.posts = savedPosts

  -- (g) bout à bout : les 14 jours simulés ont rempli le journal et daté les enchères
  local n, withF = 0, 0
  for _ in pairs(db.sales or {}) do n = n + 1 end
  for _, sg in pairs(db.lastSigs or {}) do if sg.f then withF = withF + 1 end end
  out.journal, out.withF = n, withF
  out.linenEq = pack(M.Equilibrium(2589))
  return out
end""")(ns)
p2d = {k: (strip(v) if isinstance(v, str) else v) for k, v in dict(p2).items()}
print("Phase 2 :", p2d)
assert p2d["eq"] == "12,tes scans,15,3", p2d
assert p2d["eqPart"] == "10,tes scans,5,2", p2d
assert p2d["eqFar"] == "nil" and p2d["lowText"].startswith("si elle part, c'est en moins d'1 h, 7 % de chances (tes ventes)"), p2d
assert "équilibre" in p2d["eqText"] and "15 vendus en 3 j" in p2d["eqText"], p2d
assert p2d["eqThin"] == "nil" and p2d["eqMidas"] == "13,Midas,nil,nil" and p2d["eqMidasFar"] == "nil", p2d
assert "plus qu'une mise en vente de 48 h" in p2d["midasText"] and "Midas, pour une mise en vente de 48 h" in p2d["midasText"], p2d
assert p2d["eqMidasErr"] == "nil" and p2d["eqMidasNotReady"] == "nil", p2d
assert "présent (version 1.3.7, données prêtes)" in p2d["status"] and p2d["statusAbsent"] == "absent", p2d
assert p2d["ev"] == "e:600:1:1.5 s:500:1:1.5 s:700:1:nil" and p2d["evNoNow"], p2d
assert p2d["log"].startswith("2,") and ",950,5,s,23" in p2d["log"] and ",1200,1,e," in p2d["log"] and ",900," not in p2d["log"], p2d
assert p2d["cap"] == 40 and p2d["pruned"] and p2d["oldIgnored"] == 1, p2d
assert p2d["odds980"] == "1,tes scans,6" and p2d["odds1100"] == "0.6,tes scans,10" and p2d["odds1300"] == "nil", p2d
assert p2d["hours"] == "7,tes scans" and p2d["hoursMany"] == "24,tes scans" and p2d["hoursRate"] == "12,débit" and p2d["hoursNone"], p2d
assert p2d["dur"] == "12,24,48,48", p2d
assert p2d["small"] == "979,500,3,3,nil" and "partiront avant les tiennes" in p2d["smallWhy"], p2d
assert p2d["smallAction"] == "HV,979", p2d
assert "part en ~" in p2d["smallWhyAll"] and "% de chances" in p2d["smallWhyAll"] and "mets-la" in p2d["smallWhyAll"], p2d
assert "équilibre 10s 00c/u (30 vendus en 5 j)" in p2d["smallWhyAll"], p2d
assert p2d["proj"] == "1,tes scans,6,19.2,tes scans,48", p2d
assert p2d["big"] == "499,true,30" and p2d["bigAction"] == "Attendre" and "30 bradées devant toi" in p2d["bigReason"], p2d
assert p2d["bot"] == "1000,bot,10" and "robot probable" in p2d["botWhy"] and "12 h-16 h" in p2d["botWhy"], p2d
assert "PNJ ou garde-le" in p2d["botWhy"], p2d
assert p2d["noEq"] == 969, p2d
assert p2d["quiet"] == "bot:3", p2d
assert p2d["journal"] > 0 and p2d["withF"] > 0 and ",tes scans," in p2d["linenEq"], p2d
print("OK : 1.0 phase 2 — équilibre (scans, puis Midas), journal du marché, chances et délai à un prix, durée, bradage, robot")

farm2 = lua.eval("""function(ns)
  local out, db, D, A = {}, ns.realmDB(), ns.Decide, ns.Analysis
  local function bump() ns.dataVersion = ns.dataVersion + 1 end
  bump()
  local pick
  for _, e in ipairs(ns.Advisor.FarmTargets()) do
    if not D.Sells(e.id, e.s).own then pick = e; break end
  end
  if not pick then out.none = true; return out end
  local id = pick.id
  db.sales = db.sales or {}
  local saved = db.sales[id]
  local evs = {}
  -- 1 vente, 5 expirations : chance 1/6, qu'aucune valeur par défaut ne donne
  evs[1] = { sold = true, unit = pick.post, n = 1, life = 1 }
  for _ = 1, 5 do evs[#evs + 1] = { sold = false, unit = pick.post, n = 1 } end
  db.sales[id] = nil
  ns.Market.Record(db, id, evs, time())
  bump()
  for _, e in ipairs(ns.Advisor.FarmTargets()) do
    if e.id == id then
      local s = A.Get(id)
      local sells = D.Sells(id, s)
      local p, src = D.Odds(id, e.post, s, sells)
      out.src, out.p = src, p
      out.differs = math.abs((sells.p or 0) - p) > 1e-6
      out.same = math.abs(e.net - A.NetAt(e.post, s, D.VendorPrice(id), p)) < 1e-6
      out.raw = math.abs(D.RawValue(id) - math.max(D.VendorPrice(id), e.net)) < 1e-6
    end
  end
  db.sales[id] = saved
  bump()
  return out
end""")(ns)
f2 = dict(farm2)
print("Farm, chance unique :", f2)
assert not f2.get("none") and f2["src"] == "tes scans" and abs(f2["p"] - 1 / 6) < 1e-9 and f2["differs"] and f2["same"] and f2["raw"], f2
print("OK : 1.0 phase 2 — la liste farm valorise avec la même chance de vente que le Bilan (Decide.Odds)")

# ---------------------------------------------------------------------------------------------
# 1.0 phase 3 : tes vrais coûts. Achats chez le marchand et fabrications relevés à ton clic, prix
# de revient de chaque unité (acheté / fabriqué / farmé), et « matière brute ou fabriqué »
p3 = lua.eval("""function(ns)
  local out, db, D, T = {}, ns.realmDB(), ns.Decide, ns.Tracker
  local c = ns.Prof.Char()
  local function bump() ns.dataVersion = ns.dataVersion + 1 end
  local saved = { buys = db.buys, crafts = db.crafts, ledger = db.ledger, bags = c.bags, bank = c.bank,
                  auctions = c.auctions, recipes = c.recipes.zz3, gt = GetTime, gic = GetItemCount,
                  hook = hooksecurefunc, bmi = BuyMerchantItem, dts = DoTradeSkill, link = GetTradeSkillItemLink,
                  merchant = MERCHANT }
  db.buys, db.crafts, db.ledger = {}, {}, {}
  c.bags, c.bank, c.auctions = {}, {}, nil
  local clock = 1000
  GetTime = function() return clock end
  local COUNT = {}
  GetItemCount = function(id) return COUNT[id] or 0 end
  -- le jeu : hooksecurefunc appelle notre fonction après l'originale
  hooksecurefunc = function(a, b, cfn)
    if type(a) == "table" then
      local orig = a[b]; a[b] = function(...) orig(...); cfn(...) end
    else
      local orig = _G[a]; _G[a] = function(...) orig(...); b(...) end
    end
  end
  AHLedgerDB.items[2321] = { n = "Fine Thread", s = 25 }
  AHLedgerDB.items[5001] = { n = "Sac de test", s = 40 }
  AHLedgerDB.items[5002] = { n = "Tissu de test", s = 30 }
  AHLedgerDB.items[5003] = { n = "Objet PNJ cher", s = 200 }
  AHLedgerDB.items[5004] = { n = "Objet PNJ juste", s = 65 }
  AHLedgerDB.items[5005] = { n = "Objet sans acheteur", s = 0 }

  -- 1. marchand : rien à l'ouverture ; un clic d'achat d'une pile de 5 (100c la pile) = 5 à 20c
  BuyMerchantItem = function() end
  ns.Vendor.hooked = nil
  ns.Vendor.HookBuys()
  MERCHANT = { { "Fine Thread", 100, 5, -1, 2321 }, { "Insigne", 0, 1, -1, 5099 } }
  fire("MERCHANT_SHOW")
  fire("BAG_UPDATE_DELAYED")
  out.noBuyOnShow = #db.buys == 0
  BuyMerchantItem(1, 1)
  out.notYet = #db.buys == 0
  COUNT[2321] = 5
  fire("BAG_UPDATE_DELAYED")
  local b = db.buys[1]
  out.buy = b and ("%d,%d,%d,%s"):format(b.id, b.c, b.g, tostring(b.w))
  -- deux clics avant que les sacs se mettent à jour : 10 reçus d'un coup, comptés une fois
  BuyMerchantItem(1, 1); BuyMerchantItem(1, 1)
  COUNT[2321] = 15
  fire("BAG_UPDATE_DELAYED")
  out.twoClicks = #db.buys == 2 and db.buys[2].c == 10 and db.buys[2].g == 200
  -- butin du même objet juste après l'achat (dans les 10 s) : pas un achat
  COUNT[2321] = 18
  fire("BAG_UPDATE_DELAYED")
  out.lootNotBought = #db.buys == 2
  COUNT[2321] = 15
  -- un clic sur une pile de 5, et 8 arrivent d'un coup (3 de butin) : 5 achetés à 100c, le reste ignoré
  BuyMerchantItem(1, 1)
  COUNT[2321] = 23
  fire("BAG_UPDATE_DELAYED")
  out.capped = #db.buys == 3 and db.buys[3].c == 5 and db.buys[3].g == 100
  table.remove(db.buys, 3)
  COUNT[2321] = 15
  -- payé en insignes : pas d'or, pas de relevé
  BuyMerchantItem(2, 1); COUNT[5099] = 1; fire("BAG_UPDATE_DELAYED")
  out.tokenIgnored = #db.buys == 2
  -- achat qui ne passe pas (sacs pleins) : oublié ; un loot plus tard n'est pas un achat
  BuyMerchantItem(1, 1)
  clock = clock + 20
  fire("BAG_UPDATE_DELAYED")
  COUNT[2321] = 16
  fire("BAG_UPDATE_DELAYED")
  out.failedForgotten = #db.buys == 2
  COUNT[2321] = 15

  -- 2. fabrication : Sac = 1 fil (acheté au marchand) + 2 tissus (farmés), relevée à ton clic
  c.recipes.zz3 = { [5001] = { n = "Sac de test", r = { [2321] = 1, [5002] = 2 }, m = 1 },
                    [5003] = { n = "Objet PNJ cher", r = { [5002] = 2 }, m = 1 },
                    [5004] = { n = "Objet PNJ juste", r = { [5002] = 2 }, m = 1 },
                    [5005] = { n = "Objet sans acheteur", r = { [5002] = 2 }, m = 1 } }
  bump()
  COUNT[5002], COUNT[5001] = 10, 0
  DoTradeSkill = function() end
  GetTradeSkillItemLink = function() return "|Hitem:5001::::|h" end
  ns.Prof.craftHooked = nil
  local savedTSUI = C_TradeSkillUI
  C_TradeSkillUI = nil
  ns.Prof.HookCrafts()
  C_TradeSkillUI = savedTSUI
  DoTradeSkill(3, 3)
  COUNT[2321], COUNT[5002], COUNT[5001] = 14, 8, 1
  fire("BAG_UPDATE_DELAYED")
  COUNT[2321], COUNT[5002], COUNT[5001] = 13, 6, 2
  fire("BAG_UPDATE_DELAYED")
  -- composants partis, objet pas encore là : rien ; puis il arrive
  COUNT[2321], COUNT[5002] = 12, 4
  fire("BAG_UPDATE_DELAYED")
  out.waitOutput = #db.crafts == 2
  COUNT[5001] = 3
  fire("BAG_UPDATE_DELAYED")
  local e = db.crafts[3]
  out.crafts = #db.crafts
  out.craft = e and ("%d,%d,%d,%d,%s"):format(e.id, e.c, e.u[2321], e.u[5002], tostring(e.v[5002]))
  -- série finie : plus rien n'est attribué à la fabrication
  clock = clock + 30
  COUNT[5002] = 2; COUNT[5001] = 4
  fire("BAG_UPDATE_DELAYED")
  out.seriesOver = #db.crafts == 3

  -- 3. Bilan : le fil (20c payé) et le tissu (30c, sa valeur brute) passent au sac : 80c de revient
  c.bags = { [2321] = 12, [5001] = 3, [5002] = 4 }
  ns.bagVersion = (ns.bagVersion or 0) + 1
  bump()
  local basis = T.CostBasis()
  local s1 = basis[5001]
  out.sacBasis = s1 and ("%d,%d,%d,%d"):format(s1.units, s1.cost, s1.paid, s1.crafted)
  local th = basis[2321]
  out.threadBasis = th and ("%d,%d,%d"):format(th.units, th.cost, th.bought)
  -- vente de 2 sacs à l'HV : 500c, commission 25c
  db.ledger[#db.ledger + 1] = { k = "sold", t = time() + 60, id = 5001, n = "Sac de test", c = 2, g = 500, cut = 25 }
  c.bags[5001] = 1
  bump()
  local journal, list, tot, items = T.Compute(60)
  local it = items[5001]
  out.craftGain, out.farm, out.real = it.craftGain, it.farm, it.real
  out.sacInList, out.threadInList = false, false
  for _, x in ipairs(list) do
    if x.id == 5001 then out.sacInList = true end
    if x.id == 2321 then out.threadInList = true end
  end
  out.spentPNJ, out.threadSpent = items[2321].spentPNJ, items[2321].spent
  out.threadStock = items[2321].left
  local kinds = {}
  for _, r in ipairs(journal) do
    if r.kind == "craft" and r.id == 5001 then kinds.craft = (kinds.craft or 0) + 1; out.craftRow = ("%d,%d"):format(r.paid, r.own) end
    if r.kind == "buy" and r.src == "PNJ" then kinds.pnj = (kinds.pnj or 0) + 1 end
    if r.kind == "sell" and r.id == 5001 then out.sellRow = ("%s,%s,%d"):format(tostring(r.craftGain), tostring(r.farm), r.effect) end
  end
  out.craftRows, out.pnjRows = kinds.craft, kinds.pnj
  out.headline = T.Headline(tot)
  -- un courrier d'achat à l'HV du même objet n'est pas confondu avec l'achat au marchand
  db.ledger[#db.ledger + 1] = { k = "bought", t = time() + 30, id = 2321, n = "Fine Thread", c = 5, g = 125 }
  bump()
  local j2 = T.Compute(60)
  for _, r in ipairs(j2) do if r.kind == "buy" and r.src == "mail" and r.id == 2321 then out.mailKept = true end end
  table.remove(db.ledger)
  bump()

  -- 4. prix de revient /u : le sac fabriqué 80c ; le fil, 12 achetés 20c ; 2 de plus farmés (valeur brute)
  local uc = D.UnitCost(5001, 1)
  out.sacCost = uc and ("%d,%d,%d,%d"):format(uc.unit, uc.crafted, uc.bought, uc.farmed)
  out.sacText = D.UnitCostText(uc)
  local ut = D.UnitCost(2321, 14)
  out.threadCost = ut and ("%d,%d,%s"):format(ut.bought, ut.farmed, ("%.2f"):format(ut.unit))
  out.threadRaw = D.RawValue(2321)
  out.noneOwned = D.UnitCost(5001, 0) == nil
  -- vendre le sac à l'HV sous son prix de revient : la décision le dit (sans changer de geste)
  local sv = { se = D.Sells, pp = D.PostPrice, eq = ns.Market.Equilibrium }
  D.Sells = function() return { v = "yes", p = 1, rate = 5, src = "scans", why = "~5 ventes sûres/j" } end
  D.PostPrice = function() return 60, "1c sous la moins chère", 60 end
  ns.Market.Equilibrium = function() return nil end
  bump()
  local d = D.For(5001, 1)
  out.dAction = d and d.action
  out.dBasis = d and d.basis and d.basis.known
  out.dWarn = d and table.concat(d.warn, " / ")
  D.Sells, D.PostPrice, ns.Market.Equilibrium = sv.se, sv.pp, sv.eq
  bump()

  -- 5. matière brute ou fabriqué : 2 tissus (30c bruts chacun, à toi) → objet racheté 200c, 65c, ou par personne
  local R = c.recipes.zz3
  local rc3 = D.RawOrCraft(5003, R[5003])
  local rc4 = D.RawOrCraft(5004, R[5004])
  local rc5 = D.RawOrCraft(5005, R[5005])
  out.rc3 = ("%d,%d,%d,%s,%s"):format(rc3.raw, rc3.cost, rc3.craft, rc3.to, tostring(rc3.ok))
  out.rc4 = ("%d,%d,%s"):format(rc4.craft, rc4.gain, tostring(rc4.ok))
  out.rc5 = ("%s,%s"):format(tostring(rc5.ok), tostring(rc5.to))
  for _, x in ipairs(ns.Analysis.Crafts()) do
    if x.prof == "zz3" and x.id == 5003 then out.cr3 = ("%d,%d,%s,%d"):format(x.raw, x.value, tostring(x.ok), x.daily) end
    if x.prof == "zz3" and x.id == 5004 then out.cr4 = ("%s,%d"):format(tostring(x.ok), x.daily) end
  end
  -- Mes objets : 10 tissus → fabriquer l'objet à 200c (le verdict de la recette le permet)
  c.bags[5002] = 10
  ns.bagVersion = (ns.bagVersion or 0) + 1
  bump()
  local dt = D.For(5002, 10)
  out.tissue = dt and dt.action
  out.tissueOut = dt and dt.craft and dt.craft.out
  -- sans la recette rentable : plus de « Fabriquer » (65c pour 60c de tissu : marge trop faible)
  R[5003] = nil
  bump()
  local dt2 = D.For(5002, 10)
  out.tissueNoCraft = dt2 and dt2.action
  R[5003] = { n = "Objet PNJ cher", r = { [5002] = 2 }, m = 1 }
  bump()

  -- 6. les vues : Artisanat (Brut / Fabriqué / Conseil), Journal, Achat-revente, sans erreur
  out.uiOk = pcall(function()
    for _, mode in ipairs({ "craft", "journal", "ledger", "bags" }) do ns.UI.SetMode(mode) end
  end)

  db.buys, db.crafts, db.ledger = saved.buys, saved.crafts, saved.ledger
  c.bags, c.bank, c.auctions, c.recipes.zz3 = saved.bags, saved.bank, saved.auctions, saved.recipes
  GetTime, GetItemCount, hooksecurefunc = saved.gt, saved.gic, saved.hook
  BuyMerchantItem, DoTradeSkill, GetTradeSkillItemLink, MERCHANT = saved.bmi, saved.dts, saved.link, saved.merchant
  for _, id in ipairs({ 2321, 5001, 5002, 5003, 5004, 5005 }) do AHLedgerDB.items[id] = nil end
  ns.Vendor.hooked, ns.Prof.craftHooked = nil, nil
  ns.bagVersion = (ns.bagVersion or 0) + 1
  bump()
  return out
end""")(ns)
r3 = dict(p3)
print("Phase 3 :", {k: (strip(v) if isinstance(v, str) else v) for k, v in r3.items()})
# 1. marchand
assert r3["noBuyOnShow"] and r3["notYet"] and r3["buy"] == "2321,5,100,PNJ", r3
assert r3["twoClicks"] and r3["tokenIgnored"] and r3["failedForgotten"], r3
assert r3["lootNotBought"] and r3["capped"], r3
# 2. fabrication : 3 sacs, la 3e comptée quand le sac arrive ; tissu à sa valeur brute (30c, PNJ)
assert r3["waitOutput"] and r3["crafts"] == 3 and r3["craft"] == "5001,1,1,2,30" and r3["seriesOver"], r3
# 3. Bilan : 3 sacs à 80c (20c payés chacun) ; il reste 12 fils à 20c
assert r3["sacBasis"] == "3,240,60,3" and r3["threadBasis"] == "12,240,12", r3
# vente de 2 sacs : net 475 ; valeur ajoutée 475 − 160 = 315 ; valeur brute du tissu 120 en farm ; réel = 475 − 40 payés
assert abs(r3["craftGain"] - 315) < 1e-6 and abs(r3["farm"] - 120) < 1e-6 and abs(r3["real"] - 435) < 1e-6, r3
assert r3["sacInList"] and not r3["threadInList"], r3
assert r3["spentPNJ"] == 300 and r3["threadSpent"] == 0 and r3["threadStock"] == 0, r3
assert r3["craftRows"] == 3 and r3["craftRow"] == "20,60" and r3["pnjRows"] == 2 and r3["sellRow"] == "315,120,435", r3
assert "fabrication +3s 15c" in strip(r3["headline"]) and "prix de revient" in strip(r3["headline"]), strip(r3["headline"])
assert r3["mailKept"], r3
# 4. prix de revient /u
assert r3["sacCost"] == "80,1,0,0" and "1 fabriqué 80c" in strip(r3["sacText"]), r3
assert r3["threadCost"] == "12,2,%.2f" % ((12 * 20 + 2 * r3["threadRaw"]) / 14), r3
assert r3["noneOwned"], r3
assert r3["dAction"] == "HV" and r3["dBasis"] == 1 and "sous son prix de revient (80c/u)" in strip(r3["dWarn"]), r3
# 5. matière brute ou fabriqué
assert r3["rc3"] == "60,60,200,PNJ,true" and r3["rc4"] == "65,5,false" and r3["rc5"] == "false,nil", r3
assert r3["cr3"].startswith("60,200,true,") and int(r3["cr3"].split(",")[3]) > 0 and r3["cr4"] == "false,0", r3
assert r3["tissue"] == "Fabriquer" and r3["tissueOut"] == 5003 and r3["tissueNoCraft"] != "Fabriquer", r3
assert r3["uiOk"], r3
print("OK : 1.0 phase 3 — achats au marchand et fabrications relevés à ton clic, prix de revient, matière brute ou fabriqué")

# Matière brute ou fabriqué : des composants qu'on achète moins cher qu'ils ne se revendent bruts ne font
# pas fabriquer un objet qui rapporte moins que leur vente brute (Y doit battre X, pas seulement le coût)
yx = lua.eval("""function(ns)
  local D, A = ns.Decide, ns.Analysis
  local realRC = A.ReagentCost
  AHLedgerDB.items[5006] = { n = "Composant revendable", s = 100 }
  AHLedgerDB.items[5004] = { n = "Objet PNJ juste", s = 65 }
  A.ReagentCost = function(id, k) if id == 5006 then return 20, "PNJ" end return realRC(id, k) end
  ns.dataVersion = ns.dataVersion + 1
  local rc = D.RawOrCraft(5004, { r = { [5006] = 1 }, m = 1 })
  A.ReagentCost = realRC
  AHLedgerDB.items[5006], AHLedgerDB.items[5004] = nil, nil
  ns.dataVersion = ns.dataVersion + 1
  return ("%d,%d,%d,%d,%d,%s"):format(rc.raw, rc.cost, rc.base, rc.craft, rc.gain, tostring(rc.ok))
end""")(ns)
print("Y contre X :", yx)
assert yx == "100,20,100,65,-35,false", yx
print("OK : 1.0 phase 3 — fabriquer seulement si l'objet fabriqué bat la vente brute des composants")

# Supervision phase 3 : fabrication en chaîne (un objet fabriqué sert de composant), achat payé en
# monnaie spéciale ignoré, tri de l'onglet Artisanat par la colonne Conseil
chain = lua.eval("""function(ns)
  local out, db, T = {}, ns.realmDB(), ns.Tracker
  local c = ns.Prof.Char()
  local saved = { buys = db.buys, crafts = db.crafts, ledger = db.ledger, bags = c.bags, bank = c.bank, auctions = c.auctions }
  local now = time()
  -- 2 fils achetés au marchand 20c ; sac = 1 fil + 2 tissus farmés (30c) ; malle = 1 sac + 1 fil
  db.buys = { { t = now, id = 2321, c = 2, g = 40, w = "PNJ" } }
  db.crafts = { { t = now + 1, id = 5001, c = 1, u = { [2321] = 1, [5002] = 2 }, v = { [5002] = 30 } },
                { t = now + 2, id = 5007, c = 1, u = { [5001] = 1, [2321] = 1 }, v = {} } }
  db.ledger = { { k = "sold", t = now + 3, id = 5007, c = 1, g = 300, cut = 15 } }
  c.bags, c.bank, c.auctions = {}, {}, nil
  ns.bagVersion = (ns.bagVersion or 0) + 1
  ns.dataVersion = ns.dataVersion + 1
  local _, _, tot, items = T.Compute(60)
  local it = items[5007]
  out.chain = ("%d,%d,%d"):format(it.craftGain, it.farm, it.real)
  out.balanced = math.abs((tot.farm + tot.gain + tot.craft) - (285 - 40)) < 1e-6
  db.buys, db.crafts, db.ledger = saved.buys, saved.crafts, saved.ledger
  c.bags, c.bank, c.auctions = saved.bags, saved.bank, saved.auctions
  ns.bagVersion = ns.bagVersion + 1
  ns.dataVersion = ns.dataVersion + 1
  return out
end""")(ns)
ch = dict(chain)
print("Chaîne :", ch)
# malle : prix de revient 40 payés + 60 de tissu = 100 ; net 285 → fabrication 185, farm 60, réel 245 = 285 − 40 payés
assert ch["chain"] == "185,60,245" and ch["balanced"], ch

ext = lua.eval("""function(ns)
  local db = ns.realmDB()
  local saved = { buys = db.buys, gt = GetTime, gic = GetItemCount, hook = hooksecurefunc, bmi = BuyMerchantItem,
                  m = MERCHANT, info = GetMerchantItemInfo }
  db.buys = {}
  local clock, COUNT = 5000, {}
  GetTime = function() return clock end
  GetItemCount = function(id) return COUNT[id] or 0 end
  hooksecurefunc = function(a, b) local orig = _G[a]; _G[a] = function(...) orig(...); b(...) end end
  BuyMerchantItem = function() end
  ns.Vendor.hooked = nil
  ns.Vendor.HookBuys()
  MERCHANT = { { "Objet à insignes", 500, 1, -1, 5008 } }
  -- prix en or ET en monnaie spéciale (extendedCost) : pas un prix de revient en or
  GetMerchantItemInfo = function(i) local m = MERCHANT[i]; return m[1], nil, m[2], m[3], m[4], true, true, true end
  BuyMerchantItem(1, 1)
  COUNT[5008] = 1
  fire("BAG_UPDATE_DELAYED")
  local n = #db.buys
  db.buys = saved.buys
  GetTime, GetItemCount, hooksecurefunc, BuyMerchantItem = saved.gt, saved.gic, saved.hook, saved.bmi
  MERCHANT, GetMerchantItemInfo = saved.m, saved.info
  ns.Vendor.hooked = nil
  return n
end""")(ns)
assert ext == 0, ext

sortc = lua.eval("""function(ns)
  local c = ns.Prof.Char()
  AHLedgerDB.items[5003] = { n = "Objet PNJ cher", s = 200 }
  AHLedgerDB.items[5004] = { n = "Objet PNJ juste", s = 65 }
  AHLedgerDB.items[5002] = { n = "Tissu de test", s = 30 }
  c.recipes.zz4 = { [5003] = { n = "Objet PNJ cher", r = { [5002] = 2 }, m = 1 },
                    [5004] = { n = "Objet PNJ juste", r = { [5002] = 2 }, m = 1 } }
  local savedBags = c.bags
  c.bags = { [5002] = 10 }
  ns.bagVersion = (ns.bagVersion or 0) + 1
  ns.dataVersion = ns.dataVersion + 1
  local ranks = {}
  for _, e in ipairs(ns.Analysis.Crafts()) do if e.prof == "zz4" then ranks[e.id] = e.okRank end end
  ns.UI.SetMode("craft")
  ns.UI.sortKey, ns.UI.sortDesc = "okRank", true
  local ok1, err1 = true, nil
  local ok2, err2 = pcall(ns.UI.Refresh)
  c.recipes.zz4, c.bags = nil, savedBags
  ns.bagVersion = ns.bagVersion + 1
  for _, id in ipairs({ 5002, 5003, 5004 }) do AHLedgerDB.items[id] = nil end
  ns.dataVersion = ns.dataVersion + 1
  return ("%s,%s,%s,%s"):format(tostring(ranks[5003]), tostring(ranks[5004]), tostring(ok1 and ok2), tostring(err1 or err2))
end""")(ns)
print("Tri Conseil :", sortc)
assert sortc.startswith("3,2,true"), sortc
print("OK : 1.0 phase 3 — fabrication en chaîne équilibrée, monnaie spéciale ignorée, tri Artisanat par Conseil")

print("\nOK : tous les tests de la 1.0 (phases 1, 2, 3 et 5) passent.")
