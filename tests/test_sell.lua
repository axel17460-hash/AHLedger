-- Tests du module Vente (Sell.lua) : prix proposé, file, undercuts, mise en vente, commandes, interface.
-- Lancé par tests/test_sell.py, qui charge l'addon dans le harnais et fournit la table NS.
local ns = NS
local Sell = ns.Sell
local fails = {}
local function check(name, cond, extra)
  if not cond then fails[#fails + 1] = name .. (extra ~= nil and (" : " .. tostring(extra)) or "") end
end
local function near(a, b, eps) return a ~= nil and math.abs(a - b) <= (eps or 0.01) end
local function plain(s) return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local function lastLog(n)
  local out = {}
  for i = math.max(1, #LOG - n + 1), #LOG do out[#out + 1] = plain(LOG[i]) end
  return table.concat(out, "\n")
end

-- Objets de test : id → { nom, prix PNJ, classID }
AHLedgerDB.items = {
  [1] = { n = "Alpha", s = 100, c = 7 }, [2] = { n = "Beta", s = 10, c = 7 }, [3] = { n = "Gamma", s = 10, c = 7 },
  [4] = { n = "Epée", s = 50, c = 4 }, [5] = { n = "Epsilon", s = 10, c = 7 },
}
-- Statistiques simulées (Analysis.Get) : le test porte sur Sell, pas sur l'analyse du marché
local STATS = {
  [1] = { id = 1, price = 500, perDay = 20, stock = 40, signals = {}, deposit = 10 },
  [2] = { id = 2, price = 200, perDay = 5, stock = 20, signals = {}, deposit = 2 },
  [3] = { id = 3, price = 300, perDay = 5, stock = 30, signals = {}, deposit = 2 },
  [5] = { id = 5, price = 480, perDay = 10, stock = 32, signals = {}, deposit = 2 },
}
ns.Analysis.Get = function(id) return STATS[id] end
local function book(id, levels)
  local db = ns.realmDB()
  db.book = db.book or {}
  db.book[id] = ns.Scan.PackBook(levels, 3, 400)
end
local function setAuctions(list) ns.Prof.Char().auctions = { t = time(), list = list } end
local LV1 = { { 500, 10 }, { 510, 10 }, { 520, 20 } }
local function q1(extra)
  local o = { s = STATS[1], levels = LV1, mine = {} }
  for k, v in pairs(extra or {}) do o[k] = v end
  return Sell.Quote(1, o)
end

------------------------------------------------------------------------
-- Montants et règles
------------------------------------------------------------------------
check("ParseMoney 5g 20s 3c", Sell.ParseMoney("5g 20s 3c") == 52003, Sell.ParseMoney("5g 20s 3c"))
check("ParseMoney nu = cuivre", Sell.ParseMoney("250") == 250)
check("ParseMoney 1.5s", Sell.ParseMoney("1.5s") == 150)
check("ParseMoney illisible", Sell.ParseMoney("abc") == nil)

check("règles par défaut", Sell.Rules(1).undercutCopper == 1 and Sell.Rules(1).undercutPct == nil and Sell.Rules(1).floorPct == 0.7)
Sell.SetRule("default", nil, "floorPct", 0.5)
Sell.SetRule("cat", 7, "floorPct", 0.6)
Sell.SetRule("item", 1, "floorPct", 0.8)
check("règle objet > catégorie > défaut", Sell.Rules(1).floorPct == 0.8 and Sell.Rules(2).floorPct == 0.6 and Sell.Rules(4).floorPct == 0.5,
  table.concat({ Sell.Rules(1).floorPct, Sell.Rules(2).floorPct, Sell.Rules(4).floorPct }, "/"))
Sell.SetRule("item", 1, "floorPct", nil)
check("retirer la règle objet retombe sur la catégorie", Sell.Rules(1).floorPct == 0.6)
Sell.SetRule("cat", 7, "floorPct", nil)
Sell.SetRule("default", nil, "floorPct", nil)
check("retour aux défauts", Sell.Rules(1).floorPct == 0.7)
check("règle inconnue refusée", Sell.SetRule("default", nil, "nimporte", 3) == false)
Sell.SetRule("item", 2, "stackSize", 5)
Sell.SetRule("item", 2, "stackSize", false)
check("false désactive une règle héritée", Sell.Rules(2).stackSize == nil)
Sell.SetRule("item", 2, "stackSize", nil)

------------------------------------------------------------------------
-- Prix proposé
------------------------------------------------------------------------
-- plancher : le plus grand de PNJ + marge (100 × 1,1 / 0,95), 70 % du prix réel (350)
local a = q1()
check("prix : palier − 1 c", a and a.status == "ok" and a.price == 499, a and a.price)
check("plancher = 70 % du prix réel", a and a.floor == 350 and a.floorWhy:find("prix r") ~= nil, a and a.floor)
check("durée lente : 48 h (vend 20/j pour 40 en rayon)", a and a.duration == 48, a and a.duration)
check("net = prix − commission", a and near(a.net, 499 * (1 - ns.Analysis.AH_CUT)), a and a.net)

-- anti-troll : 2 unités à 1 po dans 42 en rayon (< 10 %) sont ignorées
local b = q1({ levels = { { 100, 2 }, { 480, 10 }, { 500, 30 } } })
check("troll ignoré : on vise le palier sain", b.price == 479 and b.ignored == 2 and b.tier == 480, b.price)
check("troll : pistes de rachat", b.reset and b.reset.units == 2 and b.reset.cost == 200 and b.reset.tier == 480)

-- marché réellement sous le plancher : plus de 10 % du stock
local c = q1({ levels = { { 300, 30 }, { 500, 10 } } })
check("marché sous le plancher", c.status == "plancher" and c.price == nil and c.wouldPost == 299 and c.action == "keep", c.status)
Sell.SetRule("item", 1, "belowFloor", "vendor")
check("règle « sous le plancher » : PNJ", q1({ levels = { { 300, 30 }, { 500, 10 } } }).action == "vendor")
Sell.SetRule("item", 1, "belowFloor", nil)

-- plafond : jamais au-dessus de 1,2 × le prix réel
local d = q1({ levels = { { 900, 5 } } })
check("plafond 1,2 ×", d.status == "ok" and d.price == 600 and d.capped == true, d.price)

-- undercut en %, avec un minimum de 1 c
Sell.SetRule("default", nil, "undercut", { pct = 0.02 })
check("undercut 2 %", q1().price == 490, q1().price)
check("undercut % : 1 c au minimum", Sell.Quote(1, { s = { price = 30, signals = {} }, levels = { { 30, 5 } }, mine = {},
  rules = (function() local r = Sell.Rules(1); r.floorPct = 0.1; r.vendorMargin = 0; return r end)() }).step == 1)
-- pénurie : on vise haut (undercut minimal, plafond relevé, durée longue) ; afflux : on veut partir vite
local pen = q1({ s = { price = 500, perDay = 20, stock = 40, signals = { "pénurie" } } })
check("pénurie : undercut minimal, 48 h, plafond +0,2", pen.price == 499 and pen.duration == 48 and pen.ceil == 700, pen.price)
local aff = q1({ s = { price = 500, perDay = 20, stock = 40, signals = { "afflux" } } })
check("afflux : undercut doublé (2 % = 10 c → 20 c), 12 h", aff.price == 480 and aff.duration == 12, aff.price)
Sell.SetRule("default", nil, "undercut", 1)
check("retour à 1 c", q1().price == 499)

-- rayon vide : prix habituel, sans undercut
local e = q1({ levels = {} })
check("rayon vide", e.noCompetition and e.price == 500 and e.step == 0, e.price)
-- mes propres enchères sont retirées du carnet
local f = q1({ mine = { { unit = 500, qty = 10 } } })
check("mes enchères retirées du carnet", f.price == 509, f.price)
check("WithoutMine ignore une enchère absente du carnet",
  #Sell.WithoutMine({ { 500, 5 } }, { { unit = 480, qty = 10 } }) == 1 and Sell.WithoutMine({ { 500, 5 } }, { { unit = 500, qty = 10 } })[1][2] == 5)
-- durée fixée par règle, plancher fixé
Sell.SetRule("item", 1, "duration", 12)
check("durée imposée", q1().duration == 12)
Sell.SetRule("item", 1, "duration", nil)
Sell.SetRule("item", 1, "floorFixed", 600)
check("plancher fixé", q1().floor == 600 and q1().status == "plancher")
Sell.SetRule("item", 1, "floorFixed", nil)
-- prix fixé : ni undercut ni plafond, mais le plancher reste
Sell.SetRule("item", 1, "fixedPrice", 650)
local fx = q1()
check("prix fixé : au-dessus du plafond, accepté", fx.status == "ok" and fx.price == 650 and fx.fixed and fx.reason:find("prix fix") ~= nil, fx.price)
Sell.SetRule("item", 1, "fixedPrice", 300)
check("prix fixé sous le plancher : refusé (plancher)", q1().status == "plancher", q1().status)
Sell.SetRule("item", 1, "fixedPrice", nil)
check("prix fixé retiré", q1().price == 499)
-- plancher : coût d'achat connu + marge (courriers d'HV)
ns.Ledger.DB().ledger[#ns.Ledger.DB().ledger + 1] = { id = 1, k = "bought", c = 10, g = 4000, t = time() }
ns.dataVersion = (ns.dataVersion or 0) + 1
local cost = q1()
check("plancher : coût d'achat + marge", cost.floor == 464 and cost.floorWhy:find("achat") ~= nil, cost.floor)
ns.Ledger.DB().ledger = {}
ns.dataVersion = ns.dataVersion + 1

-- plancher : coût d'opportunité d'un objet farmé. Zone A (1 h) : 10 Alpha (PNJ 100) + 100 Beta (PNJ 10),
-- 2000/h ; zone B (1 h) : 100 Gamma + 12000 d'or ramassé, 13000/h. Or/h de référence = médiane = 7500.
-- Temps réparti au prorata quantité × prix PNJ : Alpha 0,5 h → 7500 × 0,5 / 10 = 375/u, plancher 375 / 0,95.
local T0 = time()
ns.realmDB().farm = {
  { zone = "A", start = T0 - 7200, stop = T0 - 3600, money = 0, loot = { [1] = 10, [2] = 100 } },
  { zone = "B", start = T0 - 3600, stop = T0, money = 12000, loot = { [3] = 100 } },
}
ns.dataVersion = ns.dataVersion + 1
check("farm : or/h de référence = médiane des zones", near(ns.Farm.RefRate(), 7500), ns.Farm.RefRate())
check("farm : coût/u au prorata quantité × PNJ", near(ns.Farm.UnitCost(1), 375) and near(ns.Farm.UnitCost(2), 37.5) and near(ns.Farm.UnitCost(3), 75), ns.Farm.UnitCost(1))
check("farm : objet jamais farmé, pas de coût", ns.Farm.UnitCost(4) == nil)
local fq = q1()
check("plancher : coût de farm", fq.floor == 395 and fq.floorWhy == "coût de farm", fq.floor .. " " .. tostring(fq.floorWhy))
Sell.SetRule("item", 1, "farmCost", 0.5)
check("coût de farm × 0,5 : retombe sous 70 % du prix réel", q1().floor == 350, q1().floor)
SlashCmdList.AHLEDGER("vendre regle farm 0")
check("/ahl vendre regle farm 0 : désactivé par défaut", Sell.DB().default.farmCost == false and Sell.Rules(2).farmCost == nil)
check("… mais la règle objet garde le sien", Sell.Rules(1).farmCost == 0.5)
Sell.SetRule("item", 1, "farmCost", nil)
check("farm désactivé : plancher habituel", q1().floor == 350, q1().floor)
SlashCmdList.AHLEDGER("vendre regle farm off")
check("farm off : retour au défaut (activé)", Sell.Rules(1).farmCost == 1 and q1().floor == 395, q1().floor)
-- session en cours : son loot compte aussi
ns.Farm.current = { start = T0 - 1800, zone = "A", loot = { [4] = 1 }, money0 = GetMoney() }
check("farm : la session en cours compte", ns.Farm.UnitCost(4) ~= nil and ns.Farm.UnitCost(4) > 0)
ns.Farm.current = nil
ns.realmDB().farm = {}
ns.dataVersion = ns.dataVersion + 1
check("sans session de farm : plus de coût", q1().floor == 350 and ns.Farm.RefRate() == nil)

------------------------------------------------------------------------
-- File de mise en vente
------------------------------------------------------------------------
LV2 = { { 200, 10 }, { 210, 10 } }
book(1, LV1); book(2, LV2); book(3, { { 100, 30 } }); book(5, { { 100, 2 }, { 480, 30 } })
local ADV = { [1] = 8, [2] = 5, [3] = 5 }
ns.Bags.Advise = function(id, n)
  if ADV[id] then return { action = "Vendre HV", postQty = ADV[id] } end
  return { action = "Garder" }
end
ns.Prof.Char().bags = { [1] = 30, [2] = 10, [3] = 10, [4] = 1 }
setAuctions({})
local qu = Sell.Queue()
check("file : 3 lignes (l'objet « Garder » est exclu)", #qu == 3, #qu)
check("file : gain net décroissant, bloquées à la fin", qu[1].id == 1 and qu[2].id == 2 and qu[3].id == 3 and qu[3].blocked, qu[1].id .. "," .. qu[2].id .. "," .. qu[3].id)
check("file : quantité conseillée", qu[1].qty == 8 and qu[2].qty == 5, qu[1].qty)
check("file : gain net = prix × qté − commission", near(qu[1].net, 499 * 8 * 0.95), qu[1].net)
check("file : ligne bloquée sans prix, action de la règle", qu[3].price == nil and qu[3].action == "Garder", qu[3].action)
check("Next : la meilleure ligne non bloquée", Sell.Next(qu).id == 1)
Sell.Pin(2)
check("Pin : la ligne choisie passe devant", Sell.Next(qu).id == 2)
Sell.Pin(3)
check("Pin sur une ligne bloquée : ignoré", Sell.Next(qu).id == 1)
Sell.Pin(3)
-- ce qui est déjà en vente compte dans la quantité visée
setAuctions({ { id = 2, qty = 3, unit = 205, sold = false, left = 40000, aid = 22 } })
local qu2 = Sell.Queue()
local row2
for _, r in ipairs(qu2) do if r.id == 2 then row2 = r end end
check("déjà en vente : quantité réduite (5 − 3)", row2 and row2.qty == 2 and row2.listed == 3, row2 and row2.qty)
setAuctions({ { id = 2, qty = 9, unit = 205, sold = false, left = 40000, aid = 22 } })
local none = true
for _, r in ipairs(Sell.Queue()) do if r.id == 2 then none = false end end
check("déjà assez en vente : plus proposé", none)
-- règles de pile : taille × nombre
Sell.SetRule("item", 1, "stackSize", 3); Sell.SetRule("item", 1, "stacks", 2)
setAuctions({})
local qs = Sell.Queue()
check("pile 3 × 2 : on poste 3 à la fois sur 6 visés", qs[1].id == 1 and qs[1].qty == 3 and qs[1].planned == 6, qs[1].qty .. "/" .. qs[1].planned)
Sell.SetRule("item", 1, "stackSize", nil); Sell.SetRule("item", 1, "stacks", nil)
-- banque relue : ses objets entrent dans la file, marqués « banque », triés avec le reste, jamais postés
ADV[2], ADV[5] = 12, 6
ns.Prof.Char().bank = { [2] = 3, [5] = 6, [4] = 2 }
local qb = Sell.Queue()
local order = {}
for _, r in ipairs(qb) do order[#order + 1] = r.id .. (r.bank and "b" or "") end
check("banque : triée par gain avec le reste, bloquées à la fin", table.concat(order, ",") == "1,5b,2,2b,3", table.concat(order, ","))
check("banque : ne vise que ce que les sacs ne couvrent pas (12 − 10)", qb[4].bank and qb[4].qty == 2 and qb[3].qty == 10, qb[4].qty)
check("banque : marquée et expliquée", qb[2].where == "banque" and qb[2].action == "Retirer" and qb[2].reason:find("retirer d'abord") ~= nil and not qb[2].blocked, qb[2].reason)
check("banque : Next ne la propose jamais", Sell.Next(qb).id == 1 and not Sell.Next(qb).bank)
Sell.Pin(5)
check("banque : choisie d'un clic, toujours pas postée", Sell.Next(qb).id == 1)
Sell.Pin(5)
check("banque : le garde-fou refuse de la poster", select(2, Sell.Guard(qb[2])):find("banque") ~= nil)
ADV[2] = 5
local q5 = Sell.Queue()
local bank2 = false
for _, r in ipairs(q5) do if r.id == 2 and r.bank then bank2 = true end end
check("banque : rien si les sacs couvrent la quantité visée", not bank2)
ns.Prof.Char().bank = nil
ADV[5] = nil

------------------------------------------------------------------------
-- Undercuts
------------------------------------------------------------------------
setAuctions({
  { id = 1, qty = 10, unit = 520, sold = false, left = 30 * 3600, aid = 11 },   -- battue par 500 et 510
  { id = 2, qty = 3, unit = 205, sold = false, left = 3 * 3600, aid = 22 },     -- battue par 200
  { id = 3, qty = 5, unit = 150, sold = false, left = 20 * 3600, aid = 33 },    -- marché sous mon plancher
  { id = 5, qty = 4, unit = 479, sold = false, left = 20 * 3600, aid = 55 },    -- battue par un bradeur ignoré
  { id = 1, qty = 5, sold = true },                                              -- vendue
})
local uc = Sell.Undercuts()
local byId = {}
for _, g in ipairs(uc) do byId[g.id] = g end
check("undercuts : 4 enchères battues", #uc == 4, #uc)
check("undercut 1 : prix conseillé 499, écart vs 500", byId[1] and byId[1].newPrice == 499 and byId[1].low == 500 and near(byId[1].gap, 520 / 500 - 1), byId[1] and byId[1].newPrice)
check("undercut 1 : gain attendu ≈ 540,5 et rentable", byId[1] and near(byId[1].gain, 540.5, 0.5) and byId[1].worth and byId[1].status == "à reposter", byId[1] and byId[1].gain)
check("undercut 2 : à reposter", byId[2] and byId[2].worth and byId[2].newPrice == 199, byId[2] and byId[2].status)
check("undercut 3 : sous le plancher, on laisse", byId[3] and byId[3].status == "sous le plancher" and not byId[3].worth and byId[3].newPrice == nil, byId[3] and byId[3].status)
check("undercut 5 : le bradeur est ignoré", byId[5] and byId[5].status == "bradeur ignoré" and not byId[5].worth, byId[5] and byId[5].status)
check("undercuts : rentables d'abord, plus gros gain en tête", uc[1].id == 1 and uc[2].id == 2, uc[1].id .. "," .. uc[2].id)
-- gain : formule vérifiée à la main (dépôt perdu à l'annulation, nouveau dépôt à risque)
local g = Sell.RepostGain(10, 520, 499, 1.25 / 1.5, 1, 10)
check("RepostGain", near(g, 540.5, 0.01), g)
check("repost sans gain : une enchère déjà en tête n'est pas listée", (function()
  setAuctions({ { id = 1, qty = 10, unit = 500, sold = false, left = 30 * 3600, aid = 11 } })
  return #Sell.Undercuts() == 0
end)())
-- un gain trop faible ne vaut pas le repost
setAuctions({ { id = 1, qty = 1, unit = 501, sold = false, left = 40 * 3600, aid = 11 } })
local tiny = Sell.Undercuts()[1]
check("gain minuscule : « pas rentable »", tiny and not tiny.worth and tiny.status == "pas rentable", tiny and tiny.gain)

------------------------------------------------------------------------
-- Résumé
------------------------------------------------------------------------
setAuctions({
  { id = 1, qty = 10, unit = 520, sold = false, left = 30 * 3600, aid = 11 },
  { id = 2, qty = 3, unit = 205, sold = false, left = 3 * 3600, aid = 22 },
  { id = 3, qty = 5, unit = 150, sold = false, left = 20 * 3600, aid = 33 },
  { id = 1, qty = 5, sold = true },
})
local sum = Sell.Summary()
check("résumé : comptes", sum.sold == 1 and sum.active == 3 and sum.undercut == 2 and sum.below == 1, sum.sold .. "/" .. sum.active .. "/" .. sum.undercut .. "/" .. sum.below)
check("résumé : texte", Sell.SummaryText(sum) == "2 à reposter, 1 vendue, 1 sous plancher, repasser dans ~3 h", Sell.SummaryText(sum))

------------------------------------------------------------------------
-- Poster et annuler (API simulée)
------------------------------------------------------------------------
local posted, cancelled, status = nil, {}, 2
C_AuctionHouse = {
  PostCommodity = function(loc, code, qty, price) posted = { kind = "commodity", loc = loc, code = code, qty = qty, price = price } end,
  PostItem = function(loc, code, qty, bid, buyout) posted = { kind = "item", loc = loc, code = code, qty = qty, bid = bid, buyout = buyout } end,
  CancelAuction = function(aid) cancelled[#cancelled + 1] = aid end,
  GetItemCommodityStatus = function() return status end,
}
ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
local SLOTS = { [2] = { itemID = 1, stackCount = 30, isBound = false }, [3] = { itemID = 4, stackCount = 1, isBound = false },
                [1] = { itemID = 1, stackCount = 5, isBound = true } }
C_Container = {
  GetContainerNumSlots = function(bag) return bag == 0 and 3 or 0 end,
  GetContainerItemInfo = function(bag, slot) return SLOTS[slot] end,
}
setAuctions({})
Sell.pinned = nil
local loc, total = Sell.FindItem(1)
check("FindItem : ignore les objets liés, additionne les piles", loc and loc.slot == 2 and total == 30, total)
check("PostNext", Sell.PostNext() == true)
check("PostCommodity : durée 48 h = code 3, 8 u. à 499 c", posted and posted.kind == "commodity" and posted.code == 3 and posted.qty == 8 and posted.price == 499,
  posted and (posted.kind .. posted.code .. "/" .. posted.qty .. "/" .. posted.price))
check("session comptée", Sell.session.posted == 1 and near(Sell.session.net, 499 * 8 * 0.95))
check("message de mise en vente", lastLog(2):find("Mise en vente : Alpha ×8") ~= nil, lastLog(2))
check("un objet à peine posté n'est pas reproposé", Sell.Next().id ~= 1)
-- objet unique (équipement) : prix de la pile, 1 exemplaire
status = 1
check("Post d'un objet unique", Sell.Post({ id = 4, qty = 3, price = 200, floor = 100, duration = 24, s = { price = 190 } }) == true
  and posted.kind == "item" and posted.qty == 1 and posted.buyout == 200 and posted.bid == nil and posted.code == 2, posted and posted.kind)
status = 2
-- garde-fous
local ok1, why1 = Sell.Post({ id = 1, qty = 1, price = 100, floor = 350, duration = 24, s = STATS[1] })
check("garde : sous le plancher", ok1 == false and why1 == "sous le plancher", why1)
local ok2, why2 = Sell.Post({ id = 1, qty = 1, price = 100, duration = 24, s = STATS[1] })
check("garde : le marchand paierait plus", ok2 == false and why2 == "le marchand paierait plus", why2)
local ok3, why3 = Sell.Post({ id = 1, qty = 1, price = 2000, floor = 350, duration = 24, s = STATS[1] })
check("garde : plus de 3 × le prix réel", ok3 == false and why3 == "plus de 3 × le prix réel", why3)
posted = nil
check("rien n'est posté quand un garde-fou refuse", posted == nil)
check("objet absent des sacs", select(2, Sell.Post({ id = 2, qty = 1, price = 199, floor = 140, duration = 24, s = STATS[2] })):find("introuvable") ~= nil)
AuctionHouseFrame.shown = false; ns.ahOpen = false
check("HV fermé : refusé", select(2, Sell.Post({ id = 1, qty = 1, price = 499, floor = 350, duration = 24, s = STATS[1] })) == "ouvre l'hôtel des ventes")
AuctionHouseFrame.shown = true; ns.ahOpen = true
local saveAH = C_AuctionHouse
C_AuctionHouse = nil
check("sans API : message clair", select(2, Sell.Post({ id = 1, qty = 1, price = 499, floor = 350, duration = 24 })):find("API") ~= nil)
C_AuctionHouse = saveAH

-- annulation : une enchère par appel, la plus rentable d'abord, jamais deux fois la même
setAuctions({
  { id = 1, qty = 10, unit = 520, sold = false, left = 30 * 3600, aid = 11 },
  { id = 2, qty = 3, unit = 205, sold = false, left = 3 * 3600, aid = 22 },
  { id = 3, qty = 5, unit = 150, sold = false, left = 20 * 3600, aid = 33 },
})
check("CancelNext 1", Sell.CancelNext() == true and cancelled[1] == 11, cancelled[1])
check("CancelNext 2", Sell.CancelNext() == true and cancelled[2] == 22, cancelled[2])
check("CancelNext 3 : plus rien de rentable", Sell.CancelNext() == false and #cancelled == 2)
check("annulations comptées", Sell.session.cancelled == 2)

------------------------------------------------------------------------
-- Commandes
------------------------------------------------------------------------
local function cmd(s) SlashCmdList.AHLEDGER("vendre " .. s) end
cmd("regle undercut 3")
check("/ahl vendre regle undercut 3", Sell.Rules(1).undercutCopper == 3 and Sell.Rules(1).undercutPct == nil)
cmd("regle undercut 2%")
check("… 2 %", Sell.Rules(1).undercutPct == 0.02)
cmd("regle undercut off")
check("… off : retour au défaut", Sell.Rules(1).undercutCopper == 1 and Sell.Rules(1).undercutPct == nil)
cmd("regle plancher 80%")
check("règle plancher 80 %", Sell.Rules(1).floorPct == 0.8)
cmd("regle plancher off")
cmd("regle objet |cffffffff|Hitem:1::::|h[Alpha Item]|h|r sous pnj")
check("règle objet par lien (nom avec espace)", Sell.DB().item[1] and Sell.DB().item[1].belowFloor == "vendor", Sell.DB().item[1] and Sell.DB().item[1].belowFloor)
cmd("regle objet 1 sous off")
cmd("regle cat 7 plafond 1.5")
check("règle de catégorie", Sell.DB().cat[7] and Sell.DB().cat[7].ceilMult == 1.5)
cmd("regle duree 12")
check("durée 12 h", Sell.Rules(1).duration == 12)
cmd("regle duree 7")
check("durée 7 h refusée", Sell.Rules(1).duration == 12 and lastLog(1):find("illisible") ~= nil, lastLog(1))
cmd("regle duree off")
cmd("regle pile 4")
check("règle pile", Sell.Rules(1).stackSize == 4)
cmd("regle pile off")
cmd("prix |cffffffff|Hitem:1::::|h[Alpha Item]|h|r 6g 50s")
check("/ahl vendre prix par lien", Sell.DB().item[1] and Sell.DB().item[1].fixedPrice == 65000, Sell.DB().item[1] and Sell.DB().item[1].fixedPrice)
cmd("prix 1 off")
check("/ahl vendre prix off", Sell.Rules(1).fixedPrice == nil)
cmd("prix")
check("prix sans argument : aide", lastLog(1):find("Syntaxe") ~= nil)
cmd("regle bidon 3")
check("clé inconnue : aide", lastLog(1):find("Clés") ~= nil)
setAuctions({})
cmd("file")
check("/ahl vendre file affiche la file", lastLog(5):find("File de vente") ~= nil, lastLog(5))
cmd("regles")
check("/ahl vendre regles", lastLog(3):find("undercut") ~= nil)
cmd("undercuts")
cmd("")
Sell.DB().cat[7] = nil

------------------------------------------------------------------------
-- Session : ventes encaissées d'après les courriers
------------------------------------------------------------------------
Sell.session.cancels = {} -- les annulations des tests précédents comptent sinon comme dépôts perdus
local before = Sell.SessionSold()
check("session : rien d'encaissé au départ", before.units == 0 and before.net == 0)
local L = ns.Ledger.DB().ledger
L[#L + 1] = { id = 1, k = "sold", c = 10, g = 5000, cut = 250, t = time() + 5 }
L[#L + 1] = { id = 2, k = "sold", c = 4, g = 800, cut = 40, t = time() + 6 }
L[#L + 1] = { id = 1, k = "sold", c = 99, g = 99999, cut = 99, t = Sell.session.start - 100 } -- avant la session
L[#L + 1] = { id = 1, k = "bought", c = 5, g = 700, t = time() + 7 }                         -- un achat, pas une vente
local ss = Sell.SessionSold()
check("session : ventes depuis le début seulement", ss.units == 14 and ss.gross == 5800 and ss.cut == 290 and ss.net == 5510, ss.units .. "/" .. ss.gross .. "/" .. ss.net)
check("session : texte au pied de page", plain(Sell.SessionText()):find("encaissé 14 u., commission 2s 90c, net 55s 10c") ~= nil, plain(Sell.SessionText()))
-- dépôts perdus : 5 Beta expirées (dépôt 2/u) + une annulation (3 Alpha, dépôt 10/u)
L[#L + 1] = { id = 2, k = "expired", c = 5, t = time() + 8 }
Sell.session.cancels[1] = { t = time(), id = 1, qty = 3, dep = 30 }
local sd = Sell.SalesSummary()
check("résumé : dépôts perdus (expirés + annulés)", sd.expired == 5 and sd.cancelled == 1 and near(sd.depLost, 40) and near(sd.net, 5470), sd.depLost .. "/" .. sd.net)
check("résumé : or net par heure", near(sd.perHour, 5470 / (sd.secs / 3600)), sd.perHour)
check("pied de page : dépôts perdus", plain(Sell.SessionText()):find("dépôts perdus 40c, net 54s 70c") ~= nil, plain(Sell.SessionText()))
-- annulation depuis l'addon : dépôt perdu noté
local saveCancel = C_AuctionHouse.CancelAuction
C_AuctionHouse.CancelAuction = function() end
setAuctions({ { id = 1, qty = 10, unit = 520, sold = false, left = 30 * 3600, aid = 11 } })
book(1, LV1)
Sell.CancelNext()
local lastC = Sell.session.cancels[#Sell.session.cancels]
check("annulation : dépôt perdu estimé (10 × 10)", #Sell.session.cancels == 2 and lastC.id == 1 and near(lastC.dep, 100), lastC and lastC.dep)
table.remove(Sell.session.cancels)
C_AuctionHouse.CancelAuction = saveCancel
-- session /ahl farm en cours : ventes depuis son début seulement (la vente de Beta, son expiration)
ns.Farm.current = { start = time() + 6, zone = "Tanaris", loot = { [2] = 20 }, money0 = GetMoney() }
local fc = Sell.FarmCompare()
check("farm : ventes pendant le farm", fc.farmSales and fc.farmSales.units == 4 and near(fc.farmSales.net, 750), fc.farmSales and fc.farmSales.net)
check("farm : or/h du farm en cours", fc.farm and fc.farm.lootPerHour > 0 and fc.farm.zone == "Tanaris")
local short, long = Sell.FarmCompareText(fc)
check("farm : texte court", short:find("ventes de la session : net") and short:find("farm en cours") ~= nil, short)
check("farm : texte complet", long:find("dépôts perdus") and long:find("Farm en cours %(Tanaris") ~= nil, long)
SlashCmdList.AHLEDGER("")
ns.UI.SetMode("farm")
check("onglet Farm : comparaison au pied de page et dans l'aide", plain(ns.UI.footer.text):find("farm en cours") ~= nil
  and ns.UI.helpText:find("Session de jeu") ~= nil, plain(ns.UI.footer.text))
ns.Farm.current = nil
Sell.session.cancels = {}
ns.Ledger.DB().ledger = {}

------------------------------------------------------------------------
-- Interface : vues Mes objets → file de vente → undercuts
------------------------------------------------------------------------
SlashCmdList.AHLEDGER("")
local UI = ns.UI
setAuctions({})
local function rowsText()
  local out = {}
  for _, row in pairs(UI.rows) do
    if row.shown then
      local cells = {}
      for i = 1, 10 do if row.cells[i].text and row.cells[i].text ~= "" then cells[#cells + 1] = plain(row.cells[i].text) end end
      out[#out + 1] = table.concat(cells, " | ")
    end
  end
  return out
end
ns.Prof.Char().bank = { [5] = 6 }
ADV[5] = 6
UI.SetMode("sell")
local bankRow
for _, r in ipairs(rowsText()) do if r:find("Epsilon") then bankRow = r end end
check("file : ligne banque affichée « (banque) » et « Retirer »", bankRow and bankRow:find("%(banque%)") and bankRow:find("Retirer") and not bankRow:find("►"), bankRow)
ns.Prof.Char().bank = nil
ADV[5] = nil
UI.SetMode("bags")
check("Mes objets : bouton de vue vers la file", UI.VIEWS.bags.other == "sell" and UI.sellButton.shown == false)
UI.SetMode("sell")
local rows = rowsText()
check("file : lignes affichées", #rows == 3, #rows)
check("file : première ligne = Alpha à 499", rows[1] and rows[1]:find("Alpha") and rows[1]:find("8") and rows[1]:find("Poster"), rows[1])
check("file : ligne bloquée signalée", rows[3] and rows[3]:find("Gamma") and rows[3]:find("Garder"), rows[3])
check("file : bouton Poster suivant visible", UI.sellButton.shown == true and UI.sellButton.text == "Poster suivant", UI.sellButton.text)
check("file : pied de page = session", plain(UI.footer.text):find("session :") ~= nil, plain(UI.footer.text))
-- un clic sur une ligne la choisit ; le bouton poste celle-là
Sell.pinned = nil
for _, row in pairs(UI.rows) do
  if row.shown and row.entry and row.entry.id == 2 then row.scripts.OnClick(row) end
end
local marked
for _, r in ipairs(rowsText()) do if r:find("►") then marked = r end end
check("clic sur une ligne : choisie (►) sur la ligne de Beta", Sell.pinned == 2 and marked and marked:find("Beta") ~= nil, marked)
posted = nil
SLOTS[2] = { itemID = 2, stackCount = 10, isBound = false }
Sell.last = nil
UI.sellButton.scripts.OnClick()
check("le bouton poste une seule enchère, celle choisie", posted and posted.kind == "commodity", posted and posted.kind)
setAuctions({
  { id = 1, qty = 10, unit = 520, sold = false, left = 30 * 3600, aid = 11 },
  { id = 2, qty = 3, unit = 205, sold = false, left = 3 * 3600, aid = 22 },
})
UI.SetMode("repost")
local rows2 = rowsText()
check("undercuts : 2 lignes, la plus rentable d'abord", #rows2 == 2 and rows2[1]:find("Alpha") and rows2[1]:find("à reposter"), rows2[1])
check("undercuts : bouton Annuler suivante", UI.sellButton.text == "Annuler suivante")
cancelled = {}
UI.sellButton.scripts.OnClick()
check("le bouton annule une seule enchère", #cancelled == 1 and cancelled[1] == 11, #cancelled)
UI.SetMode("market")
check("hors vente : bouton caché", UI.sellButton.shown == false)

return fails
