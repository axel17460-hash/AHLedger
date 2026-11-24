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
for mode in ("market", "flip", "craft", "level", "vendor", "snipe", "farm", "track"):
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
assert any(x.startswith("Tu en as 30 (sacs 30, banque 0) : Vendre HV") for x in tt), tt
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
assert "Données : " in shift and "Tu en as 30" in shift, shift
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
  return footer, emptyHidden, empty, emptyShown, UI.headers[9].arrow.shown, UI.helpText ~= nil
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
         found and found.post == low - 1, found and found.premium, found and found.qty, mineSkipped, r1
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
