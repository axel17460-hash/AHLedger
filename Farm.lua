-- AHLedger - Sessions de farm : ce que tu loots réellement, par zone et par heure
local _, ns = ...

local Farm = {}
ns.Farm = Farm

-- Transforme une chaîne globale localisée ("Vous recevez le butin : %sx%d.") en motif Lua
local function toPattern(fmt)
  local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
  return "^" .. p .. "$"
end

local PATTERNS
local function patterns()
  if not PATTERNS then
    PATTERNS = {
      { toPattern(LOOT_ITEM_SELF_MULTIPLE), true },
      { toPattern(LOOT_ITEM_SELF), false },
      { toPattern(LOOT_ITEM_PUSHED_SELF_MULTIPLE), true },
      { toPattern(LOOT_ITEM_PUSHED_SELF), false },
    }
  end
  return PATTERNS
end

function Farm.ParseLoot(msg)
  for _, entry in ipairs(patterns()) do
    local link, qty = msg:match(entry[1])
    if link then
      return ns.itemIdFromLink(link), entry[2] and tonumber(qty) or 1
    end
  end
end

-- Génération du farm : change à chaque ramassage, mouvement d'or, début ou fin de session (cache de CostTable)
Farm.gen = 0
local function bump() Farm.gen = Farm.gen + 1 end

local function onLoot(msg)
  local s = Farm.current
  if not s then return end
  local id, qty = Farm.ParseLoot(msg)
  if id then
    ns.rememberItem(id)
    s.loot[id] = (s.loot[id] or 0) + qty
    bump()
  end
end

-- Or du courrier : boîte aux lettres ouverte, chaque mouvement d'or (or retiré d'un courrier : ventes de
-- l'HV, envois d'un reroll ; aussi port et contre-remboursement payés) est noté dans s.mail et retiré de
-- l'or ramassé. Ce n'est pas du farm.
Farm.mailOpen = false
local function onMoney()
  local s = Farm.current
  if not (s and GetMoney) then return end
  local m = GetMoney()
  if Farm.mailOpen and s.lastMoney then s.mail = (s.mail or 0) + (m - s.lastMoney) end
  s.lastMoney = m
  bump()
end
ns.on("MAIL_SHOW", function() Farm.mailOpen = true end)
ns.on("MAIL_CLOSED", function() Farm.mailOpen = false end)
ns.on("PLAYER_MONEY", function() onMoney() end)

-- Or ramassé d'une session en cours, hors or du courrier
local function sessionMoney(s)
  if not s.money0 then return s.money or 0 end
  local m = GetMoney()
  if m == 0 and s.lastMoney then m = s.lastMoney end -- au logout, GetMoney() peut renvoyer 0
  return m - s.money0 - (s.mail or 0)
end

function Farm.Start()
  if Farm.current then ns.print("Session déjà en cours.") return end
  Farm.current = {
    start = time(),
    zone = GetZoneText() or "?",
    level = UnitLevel("player"),
    class = select(2, UnitClass("player")),
    money0 = GetMoney(),
    lastMoney = GetMoney(),
    mail = 0,
    loot = {},
  }
  bump()
  ns.on("CHAT_MSG_LOOT", onLoot)
  ns.print("Session de farm démarrée à " .. Farm.current.zone .. ".")
end

function Farm.Stop()
  local s = Farm.current
  if not s then ns.print("Aucune session en cours.") return end
  ns.off("CHAT_MSG_LOOT", onLoot)
  s.stop = time()
  s.money = sessionMoney(s)   -- or brut ramassé hors courrier (attention : inclut ventes/achats PNJ)
  s.money0, s.lastMoney = nil, nil
  bump()
  local db = ns.realmDB()
  db.farm[#db.farm + 1] = s
  Farm.current = nil
  ns.print(("Session enregistrée : %d min. Résultats dans /ahl, onglet Farm."):format(math.floor((s.stop - s.start) / 60)))
end

------------------------------------------------------------------------
-- Valeur du loot et coût d'opportunité d'un objet farmé (utilisé par le module Vente)
------------------------------------------------------------------------

-- Valeur par heure d'un loot ramassé en `hours` heures, même règle que Analysis.FarmZones : au-delà
-- de ce que le marché absorbe (un quart des ventes du jour par heure), le loot est compté au prix PNJ.
function Farm.LootValue(loot, hours)
  local all = ns.Analysis and ns.Analysis.All().byId or {}
  hours = math.max(hours or 0, 1 / 60)
  local value = 0
  for id, q in pairs(loot or {}) do
    local s = all[id]
    local vsell = AHLedgerDB.items[id] and AHLedgerDB.items[id].s or 0
    local unit = s and s.net or vsell
    local perHourQty = q / hours
    local liquid = s and s.perDay and math.min(perHourQty, s.perDay / 4) or perHourQty
    value = value + liquid * unit + (perHourQty - liquid) * vsell
  end
  return value
end

-- Session en cours : { zone, hours, lootPerHour, moneyPerHour (or ramassé, hors or retiré du courrier), total }
function Farm.CurrentStats()
  local s = Farm.current
  if not s then return nil end
  local hours = math.max(time() - s.start, 60) / 3600
  local money = s.money0 and sessionMoney(s) or 0
  local loot = Farm.LootValue(s.loot, hours)
  return { zone = s.zone, start = s.start, hours = hours, lootPerHour = loot, moneyPerHour = money / hours,
           money = money, total = loot + money / hours }
end

-- Or/h de référence : ce que vaut une heure de farm pour toi, médiane des « Total /h » de tes zones
-- (zones d'au moins REF_MIN_HOURS). nil sans session assez longue.
Farm.REF_MIN_HOURS = 0.25
function Farm.RefRate()
  if not (ns.Analysis and ns.Analysis.FarmZones) then return nil end
  local rates = {}
  for _, z in ipairs(ns.Analysis.FarmZones()) do
    if z.hours >= Farm.REF_MIN_HOURS and z.total > 0 then rates[#rates + 1] = z.total end
  end
  if #rates == 0 then return nil end
  table.sort(rates)
  local n = #rates
  return n % 2 == 1 and rates[(n + 1) / 2] or (rates[n / 2] + rates[n / 2 + 1]) / 2
end

-- Or/h de chaque zone (« Total /h » de Analysis.FarmZones), seulement pour les zones d'au moins
-- REF_MIN_HOURS : { [zone] = cuivre/h }
function Farm.ZoneRates()
  local out = {}
  if not (ns.Analysis and ns.Analysis.FarmZones) then return out end
  for _, z in ipairs(ns.Analysis.FarmZones()) do
    if z.hours >= Farm.REF_MIN_HOURS and z.total > 0 then out[z.zone] = z.total end
  end
  return out
end

-- Coût d'opportunité à l'unité de chaque objet farmé : le temps passé à le looter × l'or/h de la zone où
-- il a été looté (repli sur la médiane de tes zones, Farm.RefRate, si la zone a moins de REF_MIN_HOURS).
-- Le temps d'une session est d'abord partagé entre le loot et l'or ramassé, au prorata de leur valeur
-- (loot valorisé comme Analysis.FarmZones ; or ramassé hors courrier) : la part de l'or ne pèse sur aucun
-- objet. La part du loot est ensuite répartie entre les objets au prorata de quantité × prix PNJ (stable,
-- indépendant du cours de l'HV : le coût ne s'effondre pas avec le marché, et le butin gris absorbe sa
-- part du temps). coût/u = Σ (or/h de la zone × heures attribuées) ÷ unités.
-- C'est un coût irrécupérable : Sell.Floor ne s'en sert que comme garde-fou souple (coefficient, plafond).
-- Sessions enregistrées et session en cours. { [id] = cuivre/u }, vide sans or/h de référence.
local costT, costK
function Farm.CostTable()
  local db = ns.realmDB()
  local list = db.farm or {}
  local cur = Farm.current
  local curN = 0
  if cur then for _, q in pairs(cur.loot) do curN = curN + q end end
  -- royaume, données, prix PNJ appris, sessions, ramassages et or de la session en cours
  local key = ("%s:%s:%s:%d:%d:%d"):format(ns.realmKey(), tostring(ns.dataVersion), tostring(ns.itemsVersion or 0),
    #list, curN, Farm.gen)
  if costT and costK == key then return costT end
  costT, costK = {}, key
  local ref = Farm.RefRate()
  if not ref then return costT end
  local zoneRate = Farm.ZoneRates()
  local cost, units = {}, {}
  local function add(f, stop, money)
    local hours = math.max((stop or f.start) - f.start, 60) / 3600
    local rate = zoneRate[f.zone] or ref
    local W, w = 0, {}
    for id, q in pairs(f.loot or {}) do
      local meta = AHLedgerDB.items[id]
      w[id] = q * math.max(meta and meta.s or 0, 1)
      W = W + w[id]
    end
    if W <= 0 then return end
    -- part du temps passée à looter des objets (le reste a rapporté l'or ramassé)
    local lootValue = Farm.LootValue(f.loot, hours) * hours
    money = math.max(money or 0, 0)
    local share = (lootValue + money) > 0 and lootValue / (lootValue + money) or 1
    for id, q in pairs(f.loot) do
      cost[id] = (cost[id] or 0) + rate * hours * share * w[id] / W
      units[id] = (units[id] or 0) + q
    end
  end
  for _, f in ipairs(list) do add(f, f.stop, f.money) end
  if cur then add(cur, time(), cur.money0 and sessionMoney(cur) or 0) end
  for id, c in pairs(cost) do
    if units[id] > 0 then costT[id] = c / units[id] end
  end
  return costT
end

function Farm.UnitCost(id) return Farm.CostTable()[id] end

-- Si on se déconnecte en pleine session, on la clôture proprement
ns.on("PLAYER_LOGOUT", function()
  if Farm.current then Farm.Stop() end
end)
