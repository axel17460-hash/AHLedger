-- Tests du module Vente (Sell.lua) : prix proposé, file, undercuts, mise en vente, commandes, interface.
-- Lancé par tests/test_sell.py, qui charge l'addon dans le harnais et fournit la table NS.
-- Les prix sont en cuivre et en multiples de 100 (argent entier) : l'API d'HV refuse le cuivre sans message.
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
local function silverOnly(v) return v == nil or v % 100 == 0 end

-- Objets de test : id → { nom, prix PNJ, classID }
AHLedgerDB.items = {
  [1] = { n = "Alpha", s = 100, c = 7 }, [2] = { n = "Beta", s = 10, c = 7 }, [3] = { n = "Gamma", s = 10, c = 7 },
  [4] = { n = "Epée", s = 50, c = 4 }, [5] = { n = "Epsilon", s = 10, c = 7 },
}
-- Statistiques simulées (Analysis.Get) : le test porte sur Sell, pas sur l'analyse du marché
local STATS = {
  [1] = { id = 1, price = 50000, perDay = 20, stock = 40, signals = {}, deposit = 1000 },
  [2] = { id = 2, price = 20000, perDay = 5, stock = 20, signals = {}, deposit = 200 },
  [3] = { id = 3, price = 30000, perDay = 5, stock = 30, signals = {}, deposit = 200 },
  [5] = { id = 5, price = 48000, perDay = 10, stock = 32, signals = {}, deposit = 200 },
}
ns.Analysis.Get = function(id) return STATS[id] end
local function book(id, levels)
  local db = ns.realmDB()
  db.book = db.book or {}
  db.book[id] = ns.Scan.PackBook(levels, 3, 400)
end
local function setAuctions(list) ns.Prof.Char().auctions = { t = time(), list = list } end
local LV1 = { { 50000, 10 }, { 51000, 10 }, { 52000, 20 } }
local function q1(extra)
  local o = { s = STATS[1], levels = LV1, mine = {} }
  for k, v in pairs(extra or {}) do o[k] = v end
  return Sell.Quote(1, o)
end
ns.realmDB().lastScanTime = time() -- un scan récent : sans lui, on ne poste ni n'annule

------------------------------------------------------------------------
-- Montants et règles
------------------------------------------------------------------------
check("ParseMoney 5g 20s 3c", Sell.ParseMoney("5g 20s 3c") == 52003, Sell.ParseMoney("5g 20s 3c"))
check("ParseMoney nu = cuivre", Sell.ParseMoney("250") == 250)
check("ParseMoney 1.5s", Sell.ParseMoney("1.5s") == 150)
check("ParseMoney illisible", Sell.ParseMoney("abc") == nil)

check("règles par défaut", Sell.Rules(1).undercutCopper == 100 and Sell.Rules(1).undercutPct == nil and Sell.Rules(1).floorPct == 0.7)
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
local a = q1()
check("prix : palier − 1 pa", a and a.status == "ok" and a.price == 49900, a and a.price)
check("plancher = 70 % du prix réel", a and a.floor == 35000 and a.floorWhy:find("prix r") ~= nil, a and a.floor)
check("durée lente : 48 h (vend 20/j pour 40 en rayon)", a and a.duration == 48, a and a.duration)
check("net = prix − commission", a and near(a.net, 49900 * (1 - ns.Analysis.AH_CUT)), a and a.net)

-- argent entier : jamais de cuivre (l'API refuse sans message), même avec un carnet qui en contient
local sv = q1({ s = { price = 96800, perDay = 5, stock = 10, signals = {} }, levels = { { 96850, 10 } } })
check("carnet avec du cuivre : prix en argent entier", sv.price == 96700 and silverOnly(sv.price) and silverOnly(sv.floor), sv.price)
local sv2 = q1({ s = { price = 81234.6, perDay = 5, stock = 10, signals = {} }, levels = {} })
check("rayon vide : prix habituel arrondi à l'argent", sv2.price == 81200 and silverOnly(sv2.ceil), sv2.price)
local cheap = Sell.Quote(2, { s = { price = 96, perDay = 5, stock = 10, signals = {} }, levels = { { 96, 10 } }, mine = {} })
check("objet à moins de 1 pa : prix minimal 1 pa", cheap.status == "ok" and cheap.price == 100, cheap.price)
Sell.SetRule("default", nil, "undercut", { pct = 0.02 })
check("undercut % arrondi à l'argent", silverOnly(q1({ levels = { { 12345, 10 } }, s = { price = 12345, perDay = 5, stock = 10, signals = {} } }).price))
Sell.SetRule("default", nil, "undercut", 1)
check("undercut de 1 c demandé : au moins 1 pa", q1().price == 49900)

-- anti-troll : 2 unités à 100 pa dans 42 en rayon (< 10 %) sont ignorées
local b = q1({ levels = { { 10000, 2 }, { 48000, 10 }, { 50000, 30 } } })
check("troll ignoré : on vise le palier sain", b.price == 47900 and b.ignored == 2 and b.tier == 48000, b.price)
check("troll : pistes de rachat", b.reset and b.reset.units == 2 and b.reset.cost == 20000 and b.reset.tier == 48000)

-- marché réellement sous le plancher : plus de 10 % du stock
local c = q1({ levels = { { 30000, 30 }, { 50000, 10 } } })
check("marché sous le plancher", c.status == "plancher" and c.price == nil and c.wouldPost == 29900 and c.action == "keep", c.status)
Sell.SetRule("item", 1, "belowFloor", "vendor")
check("règle « sous le plancher » : PNJ", q1({ levels = { { 30000, 30 }, { 50000, 10 } } }).action == "vendor")
Sell.SetRule("item", 1, "belowFloor", nil)

-- carnet tronqué à 15 niveaux, tous sous le plancher mais légers : ce n'est pas un rayon vide
local many = {}
for i = 1, 15 do many[i] = { 10000 + i * 100, 1 } end
local trunc = q1({ s = { price = 50000, perDay = 5, stock = 500, signals = {} }, levels = many })
check("carnet tronqué : bloqué, pas « rayon vide »", trunc.status == "plancher" and trunc.reason:find("tronqu") ~= nil and not trunc.noCompetition, trunc.reason)
local few = {}
for i = 1, 3 do few[i] = { 10000 + i * 100, 1 } end
check("3 bradeurs seulement : rayon vide, prix habituel", q1({ s = { price = 50000, perDay = 5, stock = 500, signals = {} }, levels = few }).noCompetition == true)

-- plafond : jamais au-dessus de 1,2 × le prix réel
local d = q1({ levels = { { 90000, 5 } } })
check("plafond 1,2 ×", d.status == "ok" and d.price == 60000 and d.capped == true, d.price)

-- undercut en %
Sell.SetRule("default", nil, "undercut", { pct = 0.02 })
check("undercut 2 %", q1().price == 49000, q1().price)
local pen = q1({ s = { price = 50000, perDay = 20, stock = 40, signals = { "pénurie" } } })
check("pénurie : undercut minimal, 48 h, plafond +0,2", pen.price == 49900 and pen.duration == 48 and pen.ceil == 70000, pen.price)
local aff = q1({ s = { price = 50000, perDay = 20, stock = 40, signals = { "afflux" } } })
check("afflux : undercut doublé (2 % = 10 pa → 20 pa), 12 h", aff.price == 48000 and aff.duration == 12, aff.price)
Sell.SetRule("default", nil, "undercut", 100)
check("retour à 1 pa", q1().price == 49900)

-- rayon vide : prix habituel, sans undercut
local e = q1({ levels = {} })
check("rayon vide", e.noCompetition and e.price == 50000 and e.step == 0, e.price)
-- mes propres enchères sont retirées du carnet
local f = q1({ mine = { { unit = 50000, qty = 10 } } })
check("mes enchères retirées du carnet", f.price == 50900, f.price)
check("WithoutMine ignore une enchère absente du carnet",
  #Sell.WithoutMine({ { 500, 5 } }, { { unit = 480, qty = 10 } }) == 1 and Sell.WithoutMine({ { 500, 5 } }, { { unit = 500, qty = 10 } })[1][2] == 5)
Sell.SetRule("item", 1, "duration", 12)
check("durée imposée", q1().duration == 12)
Sell.SetRule("item", 1, "duration", nil)
Sell.SetRule("item", 1, "floorFixed", 60000)
check("plancher fixé", q1().floor == 60000 and q1().status == "plancher")
Sell.SetRule("item", 1, "floorFixed", nil)
Sell.SetRule("item", 1, "fixedPrice", 65000)
local fx = q1()
check("prix fixé : au-dessus du plafond, accepté", fx.status == "ok" and fx.price == 65000 and fx.fixed and fx.reason:find("prix fix") ~= nil, fx.price)
Sell.SetRule("item", 1, "fixedPrice", 30000)
check("prix fixé sous le plancher : refusé (plancher)", q1().status == "plancher", q1().status)
Sell.SetRule("item", 1, "fixedPrice", nil)
check("prix fixé retiré", q1().price == 49900)
local capped = q1({ s = { price = 50000, perDay = 20, stock = 40, signals = {}, ev = { maxSold = 40000, list = {} } } })
check("rien vu vendu plus cher : prix plafonné au plus haut prix vendu", capped.price == 40000 and capped.trustCap and silverOnly(capped.price), capped.price)
ns.Ledger.DB().ledger[#ns.Ledger.DB().ledger + 1] = { id = 1, k = "bought", c = 10, g = 400000, t = time() }
ns.dataVersion = (ns.dataVersion or 0) + 1
local cost = q1()
check("plancher : coût d'achat + marge", cost.floor == 46400 and cost.floorWhy:find("achat") ~= nil, cost.floor)
ns.Ledger.DB().ledger = {}
ns.dataVersion = ns.dataVersion + 1

-- plancher : coût d'opportunité d'un objet farmé (aucune stat HV : le loot est valorisé au prix PNJ).
-- Les prix du marché sont en argent entier (×100 depuis l'arrondi à 1 pa) : le coût de farm d'un loot sans or
-- vaut à peu près son prix PNJ, on multiplie donc ici les prix PNJ par 100 (rétablis en fin de bloc) pour que
-- le coût de farm reste comparable au prix réel (50000) comme avant.
-- Zone A (1 h, sans or) : 10 Alpha (PNJ 10000) + 100 Beta (PNJ 1000) → 200000/h.
-- Zone B (1 h) : 10 Alpha + 100 Gamma (PNJ 1000) = 200000 de loot + 1200000 d'or ramassé → 1400000/h ; seul
-- 1/7 du temps a servi au loot (part de l'or retirée). Zone C (10 min < 15 min) : 6 Epsilon (PNJ 1000), sans or.
-- Or/h de référence = médiane des zones d'au moins 15 min (A, B) = 800000 ; C retombe sur cette médiane.
-- Alpha : A 200000 × 0,5 h + B 1400000 × (1/7 × 0,5 h) = 200000 pour 20 u. → 10000/u.
-- Gamma : 1400000 × 1/14 h / 100 = 1000/u (sans retirer la part de l'or : 7000/u). Epsilon : 800000 × 1/6 h / 6 ≈ 22222/u.
local savedVendor = {}
for id, m in pairs(AHLedgerDB.items) do savedVendor[id] = m.s; m.s = m.s * 100 end
local T0 = time()
ns.realmDB().farm = {
  { zone = "A", start = T0 - 7800, stop = T0 - 4200, money = 0, loot = { [1] = 10, [2] = 100 } },
  { zone = "B", start = T0 - 4200, stop = T0 - 600, money = 1200000, loot = { [1] = 10, [3] = 100 } },
  { zone = "C", start = T0 - 600, stop = T0, money = 0, loot = { [5] = 6 } },
}
ns.dataVersion = ns.dataVersion + 1
check("farm : or/h de référence = médiane des zones d'au moins 15 min", near(ns.Farm.RefRate(), 800000), ns.Farm.RefRate())
check("farm : cadence par zone (A 200000, B 1400000, C absente)", near(ns.Farm.ZoneRates().A, 200000) and near(ns.Farm.ZoneRates().B, 1400000)
  and ns.Farm.ZoneRates().C == nil)
check("farm : coût/u à l'or/h de chaque zone", near(ns.Farm.UnitCost(1), 10000) and near(ns.Farm.UnitCost(2), 1000), ns.Farm.UnitCost(1))
check("farm : la part de l'or ramassé ne pèse sur aucun objet", near(ns.Farm.UnitCost(3), 1000), ns.Farm.UnitCost(3))
check("farm : zone de moins de 15 min → médiane globale", near(ns.Farm.UnitCost(5), 800000 / 36), ns.Farm.UnitCost(5))
check("farm : objet jamais farmé, pas de coût", ns.Farm.UnitCost(4) == nil)
check("farm : coefficient par défaut 0,5", Sell.Rules(1).farmCost == 0.5, Sell.Rules(1).farmCost)
-- défaut 0,5 : 10000 × 0,5 / 0,95 ≈ 5263 < 70 % du prix réel (35000) ; le coût de farm est quand même affiché
local fq = q1()
check("coût de farm × 0,5 : sous 70 % du prix réel, plancher inchangé", fq.floor == 35000 and fq.floorWhy ~= "coût de farm", fq.floor)
check("coût de farm affiché même s'il ne fixe pas le plancher", fq.reason:find("coût de farm 1g 00s/u", 1, true) ~= nil and near(fq.farmUnit, 10000), fq.reason)
-- coefficient 4 : 10000 × 4 / 0,95 ≈ 42105 → arrondi à l'argent supérieur 42200 : c'est lui qui fixe le plancher
Sell.SetRule("item", 1, "farmCost", 4)
local f4 = q1()
check("plancher : coût de farm (arrondi à 1 pa)", f4.floor == 42200 and silverOnly(f4.floor) and f4.floorWhy == "coût de farm" and f4.reason:find("fixe le plancher") ~= nil, f4.floor .. " " .. tostring(f4.floorWhy))
-- coefficient 10 : 105263 > 0,9 × 50000 → plafonné à 45000, la vente au prix réel (49900) passe
Sell.SetRule("item", 1, "farmCost", 10)
local f10 = q1()
check("coût de farm plafonné à 0,9 × le prix réel", f10.floor == 45000 and f10.floorWhy == "coût de farm" and f10.farmCapped
  and f10.status == "ok" and f10.price == 49900 and f10.reason:find("plafonné à 90 %", 1, true) ~= nil, f10.floor .. " " .. f10.reason)
-- 10000 × 10 / 0,95 ≈ 105263, arrondi à l'argent supérieur
check("sans prix réel connu : pas de plafond", Sell.Floor(1, nil, Sell.Rules(1)) == 105300, Sell.Floor(1, nil, Sell.Rules(1)))
SlashCmdList.AHLEDGER("vendre regle farm 0")
check("/ahl vendre regle farm 0 : désactivé par défaut", Sell.DB().default.farmCost == false and Sell.Rules(2).farmCost == nil)
check("… mais la règle objet garde le sien", Sell.Rules(1).farmCost == 10)
Sell.SetRule("item", 1, "farmCost", nil)
local foff = q1()
check("farm désactivé : plancher habituel, coût affiché", foff.floor == 35000 and foff.reason:find("règle désactivée") ~= nil, foff.reason)
SlashCmdList.AHLEDGER("vendre regle farm off")
check("farm off : retour au défaut (0,5)", Sell.Rules(1).farmCost == 0.5 and q1().floor == 35000, q1().floor)
-- cache : invalidé quand un prix PNJ est appris, sans changement de données de marché
ITEMS[777] = { "Nouveau", 5000, 7 }
AHLedgerDB.items[777] = nil
ns.realmDB().farm[1].loot[777] = 1 -- prix PNJ encore inconnu : poids minimal, loot valorisé à 0
ns.dataVersion = ns.dataVersion + 1
local v0, before = ns.dataVersion, ns.Farm.UnitCost(777)
ns.rememberItem(777)               -- le prix PNJ arrive (5000) : sans changement de dataVersion
check("cache : invalidé quand un prix PNJ est appris", ns.dataVersion == v0 and before < 2 and near(ns.Farm.UnitCost(777), 5000),
  tostring(before) .. " → " .. tostring(ns.Farm.UnitCost(777)))
ns.realmDB().farm[1].loot[777] = nil
ns.dataVersion = ns.dataVersion + 1
-- cache : par royaume
local saveRealm = GetRealmName
GetRealmName = function() return "Autreroyaume" end
check("cache : par royaume (autre royaume, pas de farm)", ns.Farm.UnitCost(1) == nil and ns.Farm.RefRate() == nil)
GetRealmName = saveRealm
check("cache : retour au royaume, coût retrouvé", near(ns.Farm.UnitCost(1), 10000), ns.Farm.UnitCost(1))
-- session en cours : son loot compte, et chaque ramassage invalide le cache
SlashCmdList.AHLEDGER("farm start")
ns.Farm.current.start = T0 - 1800
check("farm : session en cours sans loot, pas de coût", ns.Farm.UnitCost(4) == nil)
fire("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:4::::|h[Epée]|h|r.")
local c4 = ns.Farm.UnitCost(4)
check("farm : la session en cours compte, cache invalidé par un ramassage", c4 ~= nil and c4 > 0, c4)
fire("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:4::::|h[Epée]|h|r.")
check("cache : 2e ramassage, coût/u recalculé", ns.Farm.UnitCost(4) ~= nil and ns.Farm.UnitCost(4) < c4, ns.Farm.UnitCost(4))
-- or retiré du courrier pendant le farm : exclu de l'or ramassé
fire("MAIL_SHOW")
addMoney(50000); fire("PLAYER_MONEY")
fire("MAIL_CLOSED")
addMoney(300); fire("PLAYER_MONEY")
check("farm : or du courrier exclu", ns.Farm.current.mail == 50000 and ns.Farm.CurrentStats().money == 300, ns.Farm.CurrentStats().money)
SlashCmdList.AHLEDGER("farm stop")
local last = ns.realmDB().farm[#ns.realmDB().farm]
check("farm : session enregistrée sans l'or du courrier", last.money == 300 and last.mail == 50000 and last.money0 == nil, last.money)
ns.realmDB().farm = {}
ns.dataVersion = ns.dataVersion + 1
check("sans session de farm : plus de coût", q1().floor == 35000 and ns.Farm.RefRate() == nil, q1().floor)
for id, s in pairs(savedVendor) do AHLedgerDB.items[id].s = s end -- prix PNJ d'origine pour la suite
ns.dataVersion = ns.dataVersion + 1

------------------------------------------------------------------------
-- File de mise en vente
------------------------------------------------------------------------
book(1, LV1); book(2, { { 20000, 10 }, { 21000, 10 } }); book(3, { { 10000, 30 } }); book(5, { { 10000, 2 }, { 48000, 30 } })
local ADV = { [1] = 8, [2] = 5, [3] = 5 }
local WAIT = {}
ns.Bags.Advise = function(id, n)
  if ADV[id] then return { action = "Vendre HV", postQty = ADV[id] } end
  if WAIT[id] then return { action = "Attendre" } end
  return { action = "Garder" }
end
ns.Prof.Char().bags = { [1] = 30, [2] = 10, [3] = 10, [4] = 1 }
setAuctions({})
Sell.pending = {}
local qu = Sell.Queue()
check("file : 3 lignes (l'objet « Garder » est exclu)", #qu == 3, #qu)
check("file : gain net décroissant, bloquées à la fin", qu[1].id == 1 and qu[2].id == 2 and qu[3].id == 3 and qu[3].blocked, qu[1].id .. "," .. qu[2].id .. "," .. qu[3].id)
check("file : quantité conseillée", qu[1].qty == 8 and qu[2].qty == 5, qu[1].qty)
check("file : gain net = prix × qté − commission", near(qu[1].net, 49900 * 8 * 0.95), qu[1].net)
check("file : ligne bloquée sans prix, action de la règle", qu[3].price == nil and qu[3].action == "Garder", qu[3].action)
check("file : tous les prix en argent entier", silverOnly(qu[1].price) and silverOnly(qu[2].price))
check("Next : la meilleure ligne non bloquée", Sell.Next(qu).id == 1)
Sell.Pin(2)
check("Pin : la ligne choisie passe devant", Sell.Next(qu).id == 2)
Sell.Pin(3)
check("Pin sur une ligne bloquée : ignoré", Sell.Next(qu).id == 1)
Sell.Pin(3)
Sell.failed[1] = time()
check("ligne en échec : on passe à la suivante", Sell.Next(qu).id == 2)
Sell.failed = {}
WAIT[5] = true
ns.Prof.Char().bags[5] = 10
local qt = Sell.Queue()
local row5
for _, r in ipairs(qt) do if r.id == 5 then row5 = r end end
check("bradeur écarté : « Attendre » du conseil devient une ligne à poster", row5 and row5.price == 47900 and not row5.blocked, row5 and row5.price)
WAIT[5] = nil
ns.Prof.Char().bags[5] = nil
setAuctions({ { id = 2, qty = 3, unit = 20500, sold = false, left = 40000, aid = 22 } })
local qu2 = Sell.Queue()
local row2
for _, r in ipairs(qu2) do if r.id == 2 then row2 = r end end
check("déjà en vente : quantité réduite (5 − 3)", row2 and row2.qty == 2 and row2.listed == 3, row2 and row2.qty)
setAuctions({ { id = 2, qty = 9, unit = 20500, sold = false, left = 40000, aid = 22 } })
local none = true
for _, r in ipairs(Sell.Queue()) do if r.id == 2 then none = false end end
check("déjà assez en vente : plus proposé", none)
setAuctions({})
Sell.pending = { [1] = { qty = 8, t = time() } }
local noneA = true
for _, r in ipairs(Sell.Queue()) do if r.id == 1 then noneA = false end end
check("posté à l'instant, liste pas relue : pas reproposé", noneA and Sell.Listed(1) == 8, Sell.Listed(1))
advance(5)
setAuctions({ { id = 1, qty = 8, unit = 49900, sold = false, left = 100000, aid = 99 } })
check("liste relue depuis : le compte local s'efface sans double compte", Sell.Listed(1) == 8 and Sell.pending[1] == nil, Sell.Listed(1))
Sell.pending = {}
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
  { id = 1, qty = 10, unit = 52000, sold = false, left = 30 * 3600, aid = 11 },
  { id = 2, qty = 3, unit = 20500, sold = false, left = 3 * 3600, aid = 22 },
  { id = 3, qty = 5, unit = 15000, sold = false, left = 20 * 3600, aid = 33 },
  { id = 5, qty = 4, unit = 47900, sold = false, left = 20 * 3600, aid = 55 },
  { id = 1, qty = 5, sold = true },
})
local uc = Sell.Undercuts()
local byId = {}
for _, g in ipairs(uc) do byId[g.id] = g end
check("undercuts : 4 enchères battues", #uc == 4, #uc)
check("undercut 1 : prix conseillé 49900, écart vs 50000", byId[1] and byId[1].newPrice == 49900 and byId[1].low == 50000 and near(byId[1].gap, 52000 / 50000 - 1), byId[1] and byId[1].newPrice)
check("undercut 1 : gain attendu ≈ 54050 et rentable", byId[1] and near(byId[1].gain, 54050, 5) and byId[1].worth and byId[1].status == "à reposter", byId[1] and byId[1].gain)
check("undercut 2 : à reposter", byId[2] and byId[2].worth and byId[2].newPrice == 19900, byId[2] and byId[2].status)
check("undercut 3 : sous le plancher, on laisse", byId[3] and byId[3].status == "sous le plancher" and not byId[3].worth and byId[3].newPrice == nil, byId[3] and byId[3].status)
check("undercut 5 : le bradeur est ignoré", byId[5] and byId[5].status == "bradeur ignoré" and not byId[5].worth, byId[5] and byId[5].status)
check("undercuts : rentables d'abord, plus gros gain en tête", uc[1].id == 1 and uc[2].id == 2, uc[1].id .. "," .. uc[2].id)
local g = Sell.RepostGain(10, 52000, 49900, 1.25 / 1.5, 1, 1000)
check("RepostGain", near(g, 54050, 0.01), g)
check("repost sans gain : une enchère déjà en tête n'est pas listée", (function()
  setAuctions({ { id = 1, qty = 10, unit = 50000, sold = false, left = 30 * 3600, aid = 11 } })
  return #Sell.Undercuts() == 0
end)())
setAuctions({ { id = 1, qty = 1, unit = 50100, sold = false, left = 40 * 3600, aid = 11 } })
local tiny = Sell.Undercuts()[1]
check("gain négatif : « pas rentable »", tiny and not tiny.worth and tiny.status == "pas rentable", tiny and tiny.gain)

------------------------------------------------------------------------
-- Résumé
------------------------------------------------------------------------
setAuctions({
  { id = 1, qty = 10, unit = 52000, sold = false, left = 30 * 3600, aid = 11 },
  { id = 2, qty = 3, unit = 20500, sold = false, left = 3 * 3600, aid = 22 },
  { id = 3, qty = 5, unit = 15000, sold = false, left = 20 * 3600, aid = 33 },
  { id = 1, qty = 5, sold = true },
})
local sum = Sell.Summary()
check("résumé : comptes", sum.sold == 1 and sum.active == 3 and sum.undercut == 2 and sum.below == 1, sum.sold .. "/" .. sum.active .. "/" .. sum.undercut .. "/" .. sum.below)
check("résumé : texte", Sell.SummaryText(sum) == "2 à reposter, 1 vendue, 1 sous plancher, repasser dans ~3 h", Sell.SummaryText(sum))

------------------------------------------------------------------------
-- Poster et annuler (API simulée)
------------------------------------------------------------------------
local posted, cancelled, status = nil, {}, 2
local needsConfirm, availCount, cancelCost, cancelError = false, nil, 0, false
C_AuctionHouse = {
  PostCommodity = function(loc, code, qty, price)
    posted = { kind = "commodity", loc = loc, code = code, qty = qty, price = price }
    return needsConfirm
  end,
  PostItem = function(loc, code, qty, bid, buyout)
    posted = { kind = "item", loc = loc, code = code, qty = qty, bid = bid, buyout = buyout }
    return needsConfirm
  end,
  CancelAuction = function(aid)
    if cancelError then error("action bloquée") end
    cancelled[#cancelled + 1] = aid
  end,
  GetCancelCost = function() return cancelCost end,
  GetItemCommodityStatus = function() return status end,
  GetAvailablePostCount = function() return availCount or 999 end,
}
ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
local SLOTS = { [2] = { itemID = 1, stackCount = 30, isBound = false }, [3] = { itemID = 4, stackCount = 1, isBound = false },
                [1] = { itemID = 1, stackCount = 5, isBound = true }, [4] = { itemID = 1, stackCount = 9, isBound = false, isLocked = true } }
C_Container = {
  GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
  GetContainerItemInfo = function(bag, slot) return SLOTS[slot] end,
}
setAuctions({})
Sell.pinned = nil
Sell.pending = {}
Sell.failed = {}
local loc, total, firstCount = Sell.FindItem(1)
check("FindItem : ignore les objets liés et verrouillés, additionne les piles", loc and loc.slot == 2 and total == 30 and firstCount == 30, total)
check("PostNext", Sell.PostNext() == true)
check("PostCommodity : durée 48 h = code 3, 8 u. à 49900 c", posted and posted.kind == "commodity" and posted.code == 3 and posted.qty == 8 and posted.price == 49900,
  posted and (posted.kind .. posted.code .. "/" .. posted.qty .. "/" .. posted.price))
check("session comptée", Sell.session.posted == 1 and near(Sell.session.net, 49900 * 8 * 0.95))
check("message de mise en vente", lastLog(2):find("Mise en vente : Alpha ×8") ~= nil, lastLog(2))
check("posté : compté en attendant la relecture de la liste", Sell.pending[1] and Sell.pending[1].qty == 8 and Sell.Listed(1) == 8)
check("un objet à peine posté n'est pas reproposé", Sell.Next() == nil or Sell.Next().id ~= 1)
fire("AUCTION_HOUSE_POST_ERROR")
check("erreur de mise en vente : compte défait", Sell.session.posted == 0 and Sell.pending[1].qty == 0 and Sell.failed[1] ~= nil and lastLog(1):find("refus") ~= nil, lastLog(1))
Sell.failed = {}
Sell.pending = {}
needsConfirm = true
local okc, whyc = Sell.Post({ id = 1, qty = 2, price = 49900, floor = 35000, duration = 24, s = STATS[1] })
check("needsConfirmation : pas un succès", okc == false and whyc:find("confirmation") ~= nil and Sell.session.posted == 0 and next(Sell.pending) == nil, whyc)
needsConfirm = false
status = 1
check("Post d'un objet unique", Sell.Post({ id = 4, qty = 3, price = 20000, floor = 10000, duration = 24, s = { price = 19000 } }) == true
  and posted.kind == "item" and posted.qty == 1 and posted.buyout == 20000 and posted.bid == nil and posted.code == 2, posted and posted.kind)
local oks, whys = Sell.Post({ id = 1, qty = 2, price = 49900, floor = 35000, duration = 24, s = STATS[1] })
check("pile d'objets non marchandise : refusée", oks == false and whys:find("empilable") ~= nil, whys)
status = 2
availCount = 0
check("rien à poster selon le jeu : refusé", select(2, Sell.Post({ id = 1, qty = 2, price = 49900, floor = 35000, duration = 24, s = STATS[1] })):find("rien poster") ~= nil)
availCount = 3
posted = nil
Sell.Post({ id = 1, qty = 8, price = 49900, floor = 35000, duration = 24, s = STATS[1] })
check("quantité plafonnée par GetAvailablePostCount", posted and posted.qty == 3, posted and posted.qty)
availCount = nil
Sell.pending = {}
local ok1, why1 = Sell.Post({ id = 1, qty = 1, price = 10000, floor = 35000, duration = 24, s = STATS[1] })
check("garde : sous le plancher", ok1 == false and why1 == "sous le plancher", why1)
local ok2, why2 = Sell.Post({ id = 1, qty = 1, price = 100, duration = 24, s = STATS[1] })
check("garde : le marchand paierait plus", ok2 == false and why2 == "le marchand paierait plus", why2)
local ok3, why3 = Sell.Post({ id = 1, qty = 1, price = 200000, floor = 35000, duration = 24, s = STATS[1] })
check("garde : plus de 3 × le prix réel", ok3 == false and why3 == "plus de 3 × le prix réel", why3)
local ok4, why4 = Sell.Post({ id = 1, qty = 1, price = 49950, floor = 35000, duration = 24, s = STATS[1] })
check("garde : du cuivre dans le prix", ok4 == false and why4:find("cuivre") ~= nil, why4)
check("objet absent des sacs", select(2, Sell.Post({ id = 2, qty = 1, price = 19900, floor = 14000, duration = 24, s = STATS[2] })):find("introuvable") ~= nil)
AuctionHouseFrame.shown = false; ns.ahOpen = false
check("HV fermé : refusé", select(2, Sell.Post({ id = 1, qty = 1, price = 49900, floor = 35000, duration = 24, s = STATS[1] })) == "ouvre l'hôtel des ventes")
AuctionHouseFrame.shown = true; ns.ahOpen = true
ns.realmDB().lastScanTime = time() - 3 * 3600
check("scan de 3 h : refusé", select(2, Sell.Post({ id = 1, qty = 1, price = 49900, floor = 35000, duration = 24, s = STATS[1] })):find("rescanne") ~= nil)
ns.realmDB().lastScanTime = nil
check("jamais scanné : refusé", select(2, Sell.Post({ id = 1, qty = 1, price = 49900, floor = 35000, duration = 24, s = STATS[1] })):find("scan") ~= nil)
ns.realmDB().lastScanTime = time() - 3 * 3600
check("annulation refusée avec un scan trop vieux", Sell.CancelNext() == false and lastLog(1):find("rescanne") ~= nil)
ns.realmDB().lastScanTime = time()
local saveAH = C_AuctionHouse
C_AuctionHouse = nil
check("sans API : message clair", select(2, Sell.Post({ id = 1, qty = 1, price = 49900, floor = 35000, duration = 24 })):find("API") ~= nil)
C_AuctionHouse = saveAH
Sell.pinned = 2
Sell.PostNext() -- l'objet 2 n'est pas dans les sacs simulés : échec
check("PostNext en échec : la ligne est sautée au clic suivant", Sell.failed[2] ~= nil and (Sell.Next() == nil or Sell.Next().id ~= 2))
Sell.failed = {}
Sell.pinned = nil

-- annulation : une enchère par appel, jamais celle qui a une offre ou un coût
setAuctions({
  { id = 1, qty = 10, unit = 52000, sold = false, left = 30 * 3600, aid = 11, bid = 5000 },
  { id = 2, qty = 3, unit = 20500, sold = false, left = 3 * 3600, aid = 22 },
  { id = 3, qty = 5, unit = 15000, sold = false, left = 20 * 3600, aid = 33 },
})
check("CancelNext 1 : saute l'enchère qui a une offre", Sell.CancelNext() == true and cancelled[1] == 22, cancelled[1])
check("CancelNext 2 : plus rien (l'enchère avec offre reste)", Sell.CancelNext() == false and #cancelled == 1)
setAuctions({ { id = 2, qty = 3, unit = 20500, sold = false, left = 3 * 3600, aid = 22 } })
cancelCost = 500
check("coût d'annulation > 0 : sautée", Sell.CancelNext() == false and #cancelled == 1)
cancelCost = 0
cancelError = true
check("erreur du jeu : pas de faux succès", Sell.CancelNext() == false and #cancelled == 1 and Sell.session.cancelled == 1)
check("erreur du jeu : l'enchère reste dans tes enchères", #Sell.MyUnits(2) == 1)
cancelError = false
check("CancelNext réussie", Sell.CancelNext() == true and cancelled[2] == 22 and Sell.session.cancelled == 2)
check("enchère annulée : plus comptée", #Sell.MyUnits(2) == 0)

------------------------------------------------------------------------
-- Commandes
------------------------------------------------------------------------
local function cmd(s) SlashCmdList.AHLEDGER("vendre " .. s) end
cmd("regle undercut 300")
check("/ahl vendre regle undercut 300", Sell.Rules(1).undercutCopper == 300 and Sell.Rules(1).undercutPct == nil)
cmd("regle undercut 2%")
check("… 2 %", Sell.Rules(1).undercutPct == 0.02)
cmd("regle undercut off")
check("… off : retour au défaut", Sell.Rules(1).undercutCopper == 100 and Sell.Rules(1).undercutPct == nil)
cmd("regle plancher 80%")
check("règle plancher 80 %", Sell.Rules(1).floorPct == 0.8)
cmd("regle plancher 0.7")
check("plancher 0.7 = 70 % (pas 0,7 %)", Sell.Rules(1).floorPct == 0.7, Sell.Rules(1).floorPct)
cmd("regle plancher 65")
check("plancher 65 = 65 %", near(Sell.Rules(1).floorPct, 0.65), Sell.Rules(1).floorPct)
cmd("regle plancher 0")
check("plancher 0 refusé", near(Sell.Rules(1).floorPct, 0.65), Sell.Rules(1).floorPct)
cmd("regle plancher off")
cmd("regle plafond 0.5")
check("plafond < 1 refusé", Sell.Rules(1).ceilMult == 1.2, Sell.Rules(1).ceilMult)
cmd("regle objet |cffffffff|Hitem:1::::|h[Alpha Item]|h|r sous pnj")
check("règle objet par lien (nom avec espace)", Sell.DB().item[1] and Sell.DB().item[1].belowFloor == "vendor", Sell.DB().item[1] and Sell.DB().item[1].belowFloor)
cmd("regle objet 1 sous off")
cmd("regle cat 7 plafond 1.5")
check("règle de catégorie", Sell.DB().cat[7] and Sell.DB().cat[7].ceilMult == 1.5)
cmd("regle duree 12")
check("durée 12 h", Sell.Rules(1).duration == 12)
cmd("regle duree 7")
check("durée 7 h refusée", Sell.Rules(1).duration == 12, Sell.Rules(1).duration)
cmd("regle duree off")
cmd("regle pile 4")
check("règle pile", Sell.Rules(1).stackSize == 4)
cmd("regle pile 0")
check("pile 0 refusée", Sell.Rules(1).stackSize == 4, Sell.Rules(1).stackSize)
cmd("regle pile -3")
check("pile négative refusée", Sell.Rules(1).stackSize == 4, Sell.Rules(1).stackSize)
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
Sell.pending = {}
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
-- montants à l'échelle des prix en argent entier (STATS, dépôts : ×100 depuis l'arrondi à 1 pa)
local L = ns.Ledger.DB().ledger
L[#L + 1] = { id = 1, k = "sold", c = 10, g = 500000, cut = 25000, t = time() + 5 }
L[#L + 1] = { id = 2, k = "sold", c = 4, g = 80000, cut = 4000, t = time() + 6 }
L[#L + 1] = { id = 1, k = "sold", c = 99, g = 99999, cut = 99, t = Sell.session.start - 100 }
L[#L + 1] = { id = 1, k = "bought", c = 5, g = 700, t = time() + 7 }
local ss = Sell.SessionSold()
check("session : ventes depuis le début seulement", ss.units == 14 and ss.gross == 580000 and ss.cut == 29000 and ss.net == 551000, ss.units .. "/" .. ss.gross .. "/" .. ss.net)
check("session : texte au pied de page", plain(Sell.SessionText()):find("encaissé 14 u., commission 2g 90s, net 55g 10s", 1, true) ~= nil, plain(Sell.SessionText()))
-- dépôts perdus : 5 Beta expirées (dépôt 200/u) + une annulation (3 Alpha, dépôt 1000/u)
L[#L + 1] = { id = 2, k = "expired", c = 5, t = time() + 8 }
Sell.session.cancels[1] = { t = time(), id = 1, qty = 3, dep = 3000 }
local sd = Sell.SalesSummary()
check("résumé : dépôts perdus (expirés + annulés)", sd.expired == 5 and sd.cancelled == 1 and near(sd.depLost, 4000) and near(sd.net, 547000), sd.depLost .. "/" .. sd.net)
check("résumé : or net par heure", near(sd.perHour, 547000 / (sd.secs / 3600)), sd.perHour)
check("pied de page : dépôts perdus", plain(Sell.SessionText()):find("dépôts perdus 40s 00c, net 54g 70s", 1, true) ~= nil, plain(Sell.SessionText()))
-- annulation depuis l'addon : dépôt perdu noté
local saveCancel = C_AuctionHouse.CancelAuction
C_AuctionHouse.CancelAuction = function() end
-- enchère battue à l'échelle du carnet LV1 (50000…) : à 520 elle ne serait pas battue et rien ne serait annulé
setAuctions({ { id = 1, qty = 10, unit = 52000, sold = false, left = 30 * 3600, aid = 11 } })
book(1, LV1)
Sell.CancelNext()
local lastC = Sell.session.cancels[#Sell.session.cancels]
check("annulation : dépôt perdu estimé (10 × 1000)", #Sell.session.cancels == 2 and lastC.id == 1 and near(lastC.dep, 10000), lastC and lastC.dep)
table.remove(Sell.session.cancels)
C_AuctionHouse.CancelAuction = saveCancel
-- session /ahl farm en cours : ventes depuis son début seulement (la vente de Beta, son expiration)
ns.Farm.current = { start = time() + 6, zone = "Tanaris", loot = { [2] = 20 }, money0 = GetMoney() }
local fc = Sell.FarmCompare()
check("farm : ventes pendant le farm", fc.farmSales and fc.farmSales.units == 4 and near(fc.farmSales.net, 75000), fc.farmSales and fc.farmSales.net)
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
Sell.pending = {}
Sell.failed = {}
Sell.last = nil
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
check("file : première ligne = Alpha", rows[1] and rows[1]:find("Alpha") and rows[1]:find("Poster"), rows[1])
check("file : ligne bloquée signalée", rows[3] and rows[3]:find("Gamma") and rows[3]:find("Garder"), rows[3])
check("file : bouton Poster suivant visible", UI.sellButton.shown == true and UI.sellButton.text == "Poster suivant", UI.sellButton.text)
check("file : pied de page = session (court)", plain(UI.footer.text):find("session :") ~= nil and #plain(UI.footer.text) < 70, plain(UI.footer.text))
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
  { id = 1, qty = 10, unit = 52000, sold = false, left = 30 * 3600, aid = 11 },
  { id = 2, qty = 3, unit = 20500, sold = false, left = 3 * 3600, aid = 22 },
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
