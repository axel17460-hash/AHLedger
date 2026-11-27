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

-- plancher : coût de farm. Une session de 2 h loote 10 Alpha et 100 Beta ; l'heure vaut 26 pa (2600 c).
-- Valeurs de marché (net) : Alpha 200, Beta 10 → 2000 et 1000 : Alpha absorbe 2/3 des 5200 c de la session.
local realAll = ns.Analysis.All
ns.Analysis.All = function() return { byId = { [1] = { net = 200 }, [2] = { net = 10 } } } end
local dbf = ns.realmDB()
local savedFarm = dbf.farm
dbf.farm = { { zone = "Test", start = 1000, stop = 1000 + 7200, loot = { [1] = 10, [2] = 100 } } }
check("farm : sans règle « heure », aucun coût", Sell.FarmCost(1, nil) == nil and q1().floor == 350)
check("farm : coût à l'unité (2 h × 26 pa × 2/3 ÷ 10 u.)", near(Sell.FarmCost(1, 2600), 346.6667, 0.01), Sell.FarmCost(1, 2600))
check("farm : Beta absorbe 1/3 sur 100 u.", near(Sell.FarmCost(2, 2600), 17.3333, 0.01), Sell.FarmCost(2, 2600))
check("farm : un objet jamais looté n'a pas de coût de farm", Sell.FarmCost(3, 2600) == nil)
Sell.SetRule("default", nil, "farmHourly", 2600)
local fc = q1()
check("farm : le coût de farm + marge relève le plancher (402) sans bloquer le prix",
  fc.floor == 402 and fc.floorWhy:find("farm") ~= nil and fc.status == "ok" and fc.price == 499, fc.floor .. "/" .. tostring(fc.floorWhy))
Sell.SetRule("default", nil, "farmHourly", 3600)
local fc2 = q1()
check("farm : une heure plus chère pousse le plancher (556) au-dessus du marché : bloqué",
  fc2.floor == 556 and fc2.status == "plancher" and fc2.wouldPost == 499, fc2.floor .. "/" .. fc2.status)
Sell.SetRule("default", nil, "farmHourly", nil)
check("farm : règle retirée, plancher d'origine", q1().floor == 350)
-- la commande : /ahl vendre regle heure 50g
SlashCmdList.AHLEDGER("vendre regle heure 50g")
check("/ahl vendre regle heure 50g", Sell.Rules(1).farmHourly == 500000, Sell.Rules(1).farmHourly)
check("regles décrit l'heure de farm", (function() SlashCmdList.AHLEDGER("vendre regles"); return lastLog(3):find("heure de farm 50g") ~= nil end)(), lastLog(3))
SlashCmdList.AHLEDGER("vendre regle heure off")
check("/ahl vendre regle heure off", Sell.Rules(1).farmHourly == nil)
-- une session sans loot valorisé n'a pas de coût (pas de division par zéro)
dbf.farm = { { zone = "Vide", start = 1000, stop = 4600, loot = {} }, { zone = "Zéro", start = 1000, stop = 4600, loot = { [3] = 4 } } }
ns.dataVersion = ns.dataVersion + 1
check("farm : loot sans valeur = pas de coût", Sell.FarmCost(3, 2600) ~= nil and Sell.FarmCost(3, 2600) > 0 and Sell.FarmCost(1, 2600) == nil)
dbf.farm = savedFarm
ns.Analysis.All = realAll
ns.dataVersion = ns.dataVersion + 1

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

-- banque : les objets qui n'y sont que figurent dans la file (« Retirer »), jamais postables depuis la banque
AHLedgerDB.items[6] = { n = "Zeta", s = 10, c = 7 }
STATS[6] = { id = 6, price = 300, perDay = 5, stock = 35, signals = {}, deposit = 2 }
book(6, { { 100, 30 }, { 500, 5 } }) -- marché bradé : sous le plancher (210)
ADV[5], ADV[6] = 4, 5
local cc = ns.Prof.Char()
cc.bank, cc.bankTime = { [5] = 6, [6] = 5, [1] = 7, [4] = 2 }, time() - 7200
local qb = Sell.Queue()
local byBank = {}
for _, r in ipairs(qb) do byBank[r.id] = r end
check("banque : 5 lignes (sacs 1-3 + banque 5 et 6 ; l'objet « Garder » exclu)", #qb == 5, #qb)
check("banque : objet seulement en banque = ligne « Retirer » non postable",
  byBank[5] and byBank[5].inBank and byBank[5].blocked and byBank[5].action == "Retirer" and byBank[5].bankQty == 6 and byBank[5].price == 479,
  byBank[5] and (tostring(byBank[5].action) .. "/" .. tostring(byBank[5].price)))
check("banque : la raison dit où il est et depuis quand", byBank[5] and byBank[5].reason:find("en banque") and byBank[5].reason:find("retire") and byBank[5].reason:find("vue il y a"), byBank[5] and byBank[5].reason)
check("banque : qté visée d'après le conseil (4 sur 6)", byBank[5] and byBank[5].qty == 4, byBank[5] and byBank[5].qty)
check("banque : objet à la fois en sac et en banque = ligne des sacs, quantité en banque en note",
  byBank[1] and not byBank[1].inBank and not byBank[1].blocked and byBank[1].bankQty == 7 and byBank[1].reason:find("%+7 en banque"), byBank[1] and byBank[1].reason)
check("banque : objet en banque sous le plancher = bloqué par la règle, pas « Retirer »",
  byBank[6] and byBank[6].inBank and byBank[6].status == "plancher" and byBank[6].action == "Garder", byBank[6] and byBank[6].action)
local order = {}
for i, r in ipairs(qb) do order[i] = r.id end
check("banque : ordre = sacs rentables, banque prête, puis lignes bloquées par le plancher",
  order[1] == 1 and order[2] == 2 and order[3] == 5 and ((order[4] == 3 and order[5] == 6) or (order[4] == 6 and order[5] == 3)), table.concat(order, ","))
check("banque : Next ne prend jamais une ligne de banque", Sell.Next(qb).id == 1)
Sell.Pin(5)
check("banque : épingler une ligne de banque est sans effet", Sell.Next(qb).id == 1, Sell.Next(qb).id)
Sell.Pin(5)
-- les sacs vides : seule la banque reste, rien à poster
local savedBags = cc.bags
cc.bags = {}
check("banque seule : rien n'est postable", Sell.Next() == nil)
cc.bags = savedBags
-- retour à l'état d'avant (les tests suivants comptent 3 lignes)
cc.bank, cc.bankTime = nil, nil
ADV[5], ADV[6] = nil, nil
check("banque vidée : retour à 3 lignes", #Sell.Queue() == 3, #Sell.Queue())

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
local bl = Sell.SessionBalance()
check("bilan : vendu net 5510, acheté 700 (5 u.), solde 4810", bl.net == 5510 and bl.bought == 700 and bl.boughtUnits == 5 and bl.balance == 4810, bl.net .. "/" .. bl.bought .. "/" .. bl.balance)
check("bilan : solde par heure = solde ÷ durée (≥ 1 min)", bl.hours >= 1 / 60 and near(bl.perHour, bl.balance / bl.hours, 0.5), bl.hours)
local bt = plain(Sell.SessionBalanceText())
check("bilan : texte", bt:find("vendu 14 u., commission 2s 90c, net 55s 10c") and bt:find("acheté 7s") and bt:find("solde %+48s 10c"), bt)
L[#L + 1] = { id = 2, k = "bought", c = 1, g = 9000, t = time() + 8 }
check("bilan : solde négatif affiché avec un signe moins", plain(Sell.SessionBalanceText()):find("solde %-41s 90c") ~= nil, plain(Sell.SessionBalanceText()))
L[#L] = nil
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
-- file de vente avec la banque : la ligne « Retirer » s'affiche, le bouton ne la poste pas
ADV[5] = 4
ns.Prof.Char().bank, ns.Prof.Char().bankTime = { [5] = 6 }, time() - 600
setAuctions({})
UI.SetMode("sell")
local rowsB = rowsText()
local retire
for _, r in ipairs(rowsB) do if r:find("Epsilon") then retire = r end end
check("UI file : ligne banque affichée avec « Retirer »", retire and retire:find("Retirer") and retire:find("en banque"), retire)
check("UI file : 4 lignes avec la banque", #rowsB == 4, #rowsB)
ns.Prof.Char().bank, ns.Prof.Char().bankTime = nil, nil
ADV[5] = nil
-- onglet Farm : pied de page = bilan de la session à l'HV
UI.SetMode("farm")
check("UI farm : sans courrier lu, le pied de page l'explique", plain(UI.footer.text):find("rien encaiss") ~= nil, plain(UI.footer.text))
local LL = ns.Ledger.DB().ledger
LL[#LL + 1] = { id = 1, k = "sold", c = 10, g = 5000, cut = 250, t = time() + 5 }
LL[#LL + 1] = { id = 1, k = "bought", c = 5, g = 700, t = time() + 7 }
ns.dataVersion = (ns.dataVersion or 0) + 1
UI.SetMode("farm")
local ft = plain(UI.footer.text)
check("UI farm : bilan vendu / acheté / solde dans le pied de page", ft:find("vendu 10 u.") and ft:find("acheté 7s") and ft:find("solde %+40s 50c"), ft)
ns.Ledger.DB().ledger = {}
ns.dataVersion = ns.dataVersion + 1
UI.SetMode("market")
check("hors vente : bouton caché", UI.sellButton.shown == false)

return fails
