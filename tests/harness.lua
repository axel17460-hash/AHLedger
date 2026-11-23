-- Simulation de l'API WoW (Classic) pour tester AHLedger hors jeu
local clock = 19700 * 86400 + 12 * 3600
function time() return clock end
function advance(sec) clock = clock + sec end
function date(fmt, t) return os.date(fmt, t) end
unpack = unpack or table.unpack
tinsert = table.insert

LOG = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) LOG[#LOG + 1] = m end }

-- Objets d'interface factices : toute méthode inconnue est un no-op renvoyant un autre objet factice
local frames = {}
function mock()
  local o = { events = {}, scripts = {}, shown = false, text = "" }
  setmetatable(o, { __index = function() return function() return mock() end end })
  function o:RegisterEvent(e) self.events[e] = true end
  function o:UnregisterEvent(e) self.events[e] = nil end
  function o:SetScript(n, fn) self.scripts[n] = fn end
  function o:HookScript(n, fn) self.scripts[n] = fn end
  function o:Show() self.shown = true end
  function o:Hide() self.shown = false end
  function o:IsShown() return self.shown end
  function o:SetText(t) self.text = t end
  function o:GetText() return self.text end
  function o:CreateFontString() return mock() end
  function o:CreateTexture() return mock() end
  return o
end
function CreateFrame()
  local f = mock()
  frames[#frames + 1] = f
  return f
end
function GetFramesRegisteredForEvent(e)
  local out = {}
  for _, f in ipairs(frames) do if f.events[e] then out[#out + 1] = f end end
  return unpack(out)
end
BlizzBrowse = CreateFrame(); BlizzBrowse:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
function fire(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
UIParent = mock()
UISpecialFrames = {}
GameTooltip = mock()
ItemRefTooltip = mock()
ITEM_QUALITY_COLORS = { [1] = { hex = "|cffffffff" }, [2] = { hex = "|cff1eff00" } }

local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
function runTimers()
  local guard = 0
  while #timers > 0 and guard < 100000 do
    local fn = table.remove(timers, 1); fn(); guard = guard + 1
  end
end

function GetRealmName() return "Testrealm" end
function UnitFactionGroup() return "Horde" end
function UnitName() return "Vendeur Bob" end
function UnitLevel() return 42 end
function UnitClass() return "Chasseur", "HUNTER" end
function GetZoneText() return "Tanaris" end
local money = 0
function GetMoney() return money end
function addMoney(m) money = money + m end

-- id = { nom, prix de revente PNJ, classID }
ITEMS = {
  [2589] = { "Linen Cloth", 13, 7 },
  [4306] = { "Silk Cloth", 150, 7 },
  [4338] = { "Mageweave Cloth", 250, 7 },
  [2678] = { "Mild Spices", 1, 7 },
  [3371] = { "Empty Vial", 1, 7 },
  [929]  = { "Healing Potion", 250, 0 },
  [2592] = { "Wool Cloth", 33, 7 },
}
function GetItemInfo(id)
  local i = ITEMS[id]; if not i then return nil end
  return i[1], "|cffffffff|Hitem:" .. id .. "::::|h[" .. i[1] .. "]|h|r", 1, nil, nil, nil, nil, nil, nil, nil, i[2], i[3]
end

-- Hôtel des ventes
AUCTIONS = {}
AuctionFrame = nil; AuctionHouseFrame = mock(); AuctionHouseFrame.shown = true
local canAll = true
function CanSendAuctionQuery() return true, canAll end
function QueryAuctionItems() fire("AUCTION_ITEM_LIST_UPDATE") end
function GetNumAuctionItems() return #AUCTIONS, #AUCTIONS end
function GetAuctionItemInfo(_, i)
  local a = AUCTIONS[i]
  if not a then return nil end
  return ITEMS[a.id][1], nil, a.count, 1, true, 1, nil, a.minBid or a.buyout * 0.8, 1, a.buyout, a.bid or 0, false, nil,
    a.owner, a.owner, 0, a.id, true
end
function GetAuctionItemTimeLeft(_, i) return AUCTIONS[i] and AUCTIONS[i].tl end
function GetAuctionItemLink(_, i) return "|cffffffff|Hitem:" .. AUCTIONS[i].id .. "::::|h[" .. ITEMS[AUCTIONS[i].id][1] .. "]|h|r" end
BrowseName = mock()
AuctionFrameTab1 = mock()
function AuctionFrameTab_OnClick() end

-- Marchand
MERCHANT = {
  { "Mild Spices", 10, 1, -1, 2678 },
  { "Empty Vial", 20, 1, -1, 3371 },
}
function GetMerchantNumItems() return #MERCHANT end
function GetMerchantItemInfo(i) local m = MERCHANT[i]; return m[1], nil, m[2], m[3], m[4], true, true, nil end
function GetMerchantItemLink(i) return "|cffffffff|Hitem:" .. MERCHANT[i][5] .. "::::|h[x]|h|r" end

LOOT_ITEM_SELF = "You receive loot: %s."
LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
SlashCmdList = {}

------------------------------------------------------------------------
-- Marché simulé : chaque heure, des ventes (les moins chères partent),
-- des expirations et de nouvelles mises en vente.
------------------------------------------------------------------------
-- Générateur portable (Park-Miller) : le rand() de la libc, utilisé par math.random,
-- ne donne pas la même suite sous Windows et sous Linux, ce qui changeait le marché simulé.
local seed = 7
math.random = function(a, b)
  seed = (seed * 16807) % 2147483647
  local r = (seed - 1) / 2147483646
  if not a then return r end
  if not b then a, b = 1, a end
  return a + math.floor(r * (b - a + 1))
end
MARKET = {
  -- base: prix/unité jour 0, drift: variation /jour, sell: unités vendues /h, post: unités postées /h (fonction du jour)
  { id = 2589, base = 100,  drift = 0,     sell = 40, post = function(d) return 40 end, stack = 20 },
  { id = 4306, base = 600,  drift = 0.05,  sell = 15, post = function(d) return d < 9 and 22 or 8 end, stack = 20 },
  { id = 4338, base = 1500, drift = -0.04, sell = 6,  post = function(d) return d < 9 and 9 or 20 end, stack = 20 },
  { id = 3371, base = 60,   drift = 0,     sell = 10, post = function(d) return 10 end, stack = 5 },
  { id = 929,  base = 2500, drift = 0.01,  sell = 3,  post = function(d) return 3 end, stack = 5 },
}
local live, seq = {}, 0
local startDay = math.floor(clock / 86400)

function simHour()
  advance(3600)
  local day = math.floor(clock / 86400) - startDay
  for _, m in ipairs(MARKET) do
    local price = m.base * (1 + m.drift) ^ day
    -- ventes : les enchères les moins chères partent en premier
    local mine = {}
    for k, a in pairs(live) do if a.id == m.id then mine[#mine + 1] = k end end
    table.sort(mine, function(x, y) return live[x].buyout / live[x].count < live[y].buyout / live[y].count end)
    local toSell = m.sell * (0.7 + math.random() * 0.6)
    for _, k in ipairs(mine) do
      if toSell <= 0 then break end
      toSell = toSell - live[k].count
      live[k] = nil
    end
    -- mises en vente
    local toPost = m.post(day) * (0.7 + math.random() * 0.6)
    while toPost > 0 do
      seq = seq + 1
      live[seq] = { id = m.id, count = m.stack,
                    buyout = math.floor(price * m.stack * (0.92 + math.random() * 0.2)),
                    owner = "P" .. math.random(1, 30), expires = clock + 24 * 3600 }
      toPost = toPost - m.stack
    end
  end
  for k, a in pairs(live) do if a.expires <= clock then live[k] = nil end end
end

function buildAuctions()
  AUCTIONS = {}
  for _, a in pairs(live) do
    local left = a.expires - clock
    local tl = left < 1800 and 1 or (left < 7200 and 2 or (left < 43200 and 3 or 4))
    AUCTIONS[#AUCTIONS + 1] = { id = a.id, count = a.count, buyout = a.buyout, owner = a.owner, tl = tl }
  end
end

function clockHour() return math.floor(clock / 3600) % 24 end

-- Sérialisation façon SavedVariables
local function ser(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "string" then return string.format("%q", v)
  elseif t == "number" or t == "boolean" then return tostring(v)
  elseif t == "table" then
    local out = { "{\n" }
    for k, val in pairs(v) do
      local key = type(k) == "string" and ("[" .. string.format("%q", k) .. "]") or ("[" .. k .. "]")
      out[#out + 1] = indent .. "\t" .. key .. " = " .. ser(val, indent .. "\t") .. ",\n"
    end
    out[#out + 1] = indent .. "}"
    return table.concat(out)
  end
  return "nil"
end
function serializeDB() return "AHLedgerDB = " .. ser(AHLedgerDB) .. "\n" end
