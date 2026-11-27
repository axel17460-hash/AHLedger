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

local function onLoot(msg)
  local s = Farm.current
  if not s then return end
  local id, qty = Farm.ParseLoot(msg)
  if id then
    ns.rememberItem(id)
    s.loot[id] = (s.loot[id] or 0) + qty
  end
end

function Farm.Start()
  if Farm.current then ns.print("Session déjà en cours.") return end
  Farm.current = {
    start = time(),
    zone = GetZoneText() or "?",
    level = UnitLevel("player"),
    class = select(2, UnitClass("player")),
    money0 = GetMoney(),
    loot = {},
  }
  ns.on("CHAT_MSG_LOOT", onLoot)
  ns.print("Session de farm démarrée à " .. Farm.current.zone .. ".")
end

function Farm.Stop()
  local s = Farm.current
  if not s then ns.print("Aucune session en cours.") return end
  ns.off("CHAT_MSG_LOOT", onLoot)
  s.stop = time()
  s.money = GetMoney() - s.money0   -- or brut ramassé (attention : inclut ventes/achats PNJ)
  s.money0 = nil
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

-- Session en cours : { zone, hours, lootPerHour, moneyPerHour (or ramassé, ventes du courrier comprises), total }
function Farm.CurrentStats()
  local s = Farm.current
  if not s then return nil end
  local hours = math.max(time() - s.start, 60) / 3600
  local money = s.money0 and (GetMoney() - s.money0) or 0
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

-- Coût d'opportunité à l'unité de chaque objet farmé : le temps passé à le looter × ton or/h de référence.
-- Une session loote beaucoup d'objets à la fois : son temps est réparti entre eux au prorata de
-- quantité × prix PNJ (stable, indépendant du cours de l'HV : le coût ne s'effondre pas avec le marché,
-- et le butin gris absorbe sa part du temps). coût/u = or/h de référence × heures attribuées ÷ unités.
-- Sessions enregistrées et session en cours. { [id] = cuivre/u }, vide sans or/h de référence.
local costT, costK
function Farm.CostTable()
  local db = ns.realmDB()
  local list = db.farm or {}
  local cur = Farm.current
  local curN = 0
  if cur then for _, q in pairs(cur.loot) do curN = curN + q end end
  local key = ("%s:%d:%d"):format(tostring(ns.dataVersion), #list, curN)
  if costT and costK == key then return costT end
  costT, costK = {}, key
  local ref = Farm.RefRate()
  if not ref then return costT end
  local hrs, units = {}, {}
  local function add(f, stop)
    local hours = math.max((stop or f.start) - f.start, 60) / 3600
    local W, w = 0, {}
    for id, q in pairs(f.loot or {}) do
      local meta = AHLedgerDB.items[id]
      w[id] = q * math.max(meta and meta.s or 0, 1)
      W = W + w[id]
    end
    if W <= 0 then return end
    for id, q in pairs(f.loot) do
      hrs[id] = (hrs[id] or 0) + hours * w[id] / W
      units[id] = (units[id] or 0) + q
    end
  end
  for _, f in ipairs(list) do add(f, f.stop) end
  if cur then add(cur, time()) end
  for id, h in pairs(hrs) do
    if units[id] > 0 then costT[id] = ref * h / units[id] end
  end
  return costT
end

function Farm.UnitCost(id) return Farm.CostTable()[id] end

-- Si on se déconnecte en pleine session, on la clôture proprement
ns.on("PLAYER_LOGOUT", function()
  if Farm.current then Farm.Stop() end
end)
