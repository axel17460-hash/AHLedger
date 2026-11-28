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
  ns.print(("Session enregistrée : %d min. Résultats dans /ahl, onglet Opérations, vue Mes sessions."):format(math.floor((s.stop - s.start) / 60)))
end

-- Si on se déconnecte en pleine session, on la clôture proprement
ns.on("PLAYER_LOGOUT", function()
  if Farm.current then Farm.Stop() end
end)
