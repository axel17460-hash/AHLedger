-- AHLedger - Core : base de données, événements, commandes
local ADDON, ns = ...

ns.DB_VERSION = 1
ns.MAX_SCANS = 300          -- snapshots horodatés gardés (≈ 7 j à 2 scans/h de jeu) ; importer puis /ahl prune pour alléger
ns.listeners = {}

-- Compatibilité : le client Forever tourne sur un moteur récent, certaines fonctions
-- globales peuvent n'exister que sous C_Item / C_MerchantFrame.
ns.GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

function ns.GetMerchantItem(i)
  if GetMerchantItemInfo then
    local name, _, price, quantity, numAvailable, _, _, extendedCost = GetMerchantItemInfo(i)
    return name, price, quantity, numAvailable, extendedCost
  elseif C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local info = C_MerchantFrame.GetItemInfo(i)
    if info then return info.name, info.price, info.stackCount, info.numAvailable, info.hasExtendedCost end
  end
end

local frame = CreateFrame("Frame")
ns.frame = frame

function ns.print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffAHLedger|r " .. tostring(msg))
end

-- Exécute fn en affichant toute erreur dans le chat (le jeu masque les erreurs Lua par défaut)
ns.errors = {}
function ns.safe(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    ns.print("|cffff5050Erreur (" .. label .. ") :|r " .. tostring(err))
    ns.errors[#ns.errors + 1] = label .. " : " .. tostring(err)
    if #ns.errors > 20 then table.remove(ns.errors, 1) end
  end
  return ok
end

-- Abonnement simple aux événements : ns.on("EVENT", fn)
function ns.on(event, fn)
  if not ns.listeners[event] then
    ns.listeners[event] = {}
    -- un client récent refuse les événements qu'il ne connaît pas : on les note pour /ahl diag
    local valid = not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event)
    if not valid or not pcall(frame.RegisterEvent, frame, event) then
      ns.invalidEvents = ns.invalidEvents or {}
      ns.invalidEvents[event] = true
    end
  end
  table.insert(ns.listeners[event], fn)
end

function ns.off(event, fn)
  local list = ns.listeners[event]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == fn then table.remove(list, i) end
  end
  if #list == 0 then
    ns.listeners[event] = nil
    frame:UnregisterEvent(event)
  end
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = ns.listeners[event]
  if not list then return end
  -- copie : un listener peut se désabonner pendant l'itération
  local copy = { unpack(list) }
  for _, fn in ipairs(copy) do ns.safe(event, fn, ...) end
end)

function ns.realmName()
  local r = GetRealmName and GetRealmName() or ""
  if r == "" and GetNormalizedRealmName then r = GetNormalizedRealmName() or "" end
  if r == "" then r = "Forever" end
  return r
end

function ns.realmKey()
  local faction = UnitFactionGroup("player") or "Neutral"
  return ns.realmName() .. "-" .. faction
end

-- L'HV est-il ouvert ? On suit les événements plutôt qu'un nom de fenêtre,
-- car la fenêtre d'HV de Forever n'est pas celle du Classic.
ns.ahOpen = false
function ns.ahFrame()
  -- (pas d'ipairs : il s'arrêterait au premier nom absent)
  if AuctionFrame and AuctionFrame:IsShown() then return AuctionFrame end
  if AuctionHouseFrame and AuctionHouseFrame:IsShown() then return AuctionHouseFrame end
end
function ns.isAHOpen() return ns.ahOpen or ns.ahFrame() ~= nil end

function ns.realmDB()
  local key = ns.realmKey()
  -- migration : données enregistrées avant la correction du nom de royaume vide
  local faction = UnitFactionGroup("player") or "Neutral"
  local old = AHLedgerDB.realms["-" .. faction]
  if old and key ~= "-" .. faction and not AHLedgerDB.realms[key] then
    AHLedgerDB.realms[key] = old
    AHLedgerDB.realms["-" .. faction] = nil
  end
  local r = AHLedgerDB.realms[key]
  if not r then
    r = { scans = {}, lastSigs = nil, lastScanTime = nil, vendor = {}, farm = {}, hist = {}, days = {} }
    AHLedgerDB.realms[key] = r
  end
  r.hist = r.hist or {}
  r.days = r.days or {}
  return r
end

function ns.itemIdFromLink(link)
  if not link then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end

-- Métadonnées objets (nom, prix de revente PNJ), remplies au fil des scans
function ns.rememberItem(itemId, name)
  local meta = AHLedgerDB.items[itemId]
  if not meta then
    meta = {}
    AHLedgerDB.items[itemId] = meta
  end
  -- "" est vrai en Lua : l'API Retail renvoie un nom vide tant que l'objet n'est pas en cache,
  -- on ne le stocke jamais (sinon le nom reste vide pour toujours)
  if name and name ~= "" and not meta.n then meta.n = name end
  if not meta.s or not meta.n then
    local iname, _, quality, _, _, _, _, _, _, _, sellPrice, classID = ns.GetItemInfo(itemId)
    if sellPrice and not meta.s then
      meta.s = sellPrice
      meta.q = quality
      meta.c = classID
    end
    if iname and iname ~= "" and not meta.n then meta.n = iname end
  end
end

-- Noms manquants (anciennes données ou objets pas encore en cache) : on les redemande au serveur
-- par paquets de 100 par seconde ; GET_ITEM_INFO_RECEIVED complète la base quand il répond.
function ns.FillMissingNames()
  local missing = {}
  for id, meta in pairs(AHLedgerDB.items) do
    if meta.n == "" then meta.n = nil end
    if not meta.n and type(id) == "number" then missing[#missing + 1] = id end
  end
  local i = 1
  local function batch()
    for j = i, math.min(i + 99, #missing) do ns.rememberItem(missing[j]) end
    i = i + 100
    if i <= #missing then C_Timer.After(1, batch) end
  end
  if #missing > 0 then C_Timer.After(2, batch) end
  return #missing
end

-- 123456 -> "12|cffffd700g|r 34|cffc7c7cfs|r 56|cffeda55fc|r"
function ns.money(c)
  if not c then return "-" end
  -- moins d'un cuivre (prix à l'unité de flèches, balles…) : on garde les décimales
  if c ~= 0 and math.abs(c) < 0.5 then return ("%.2f|cffeda55fc|r"):format(c) end
  c = math.floor(c + 0.5)
  local neg = c < 0
  if neg then c = -c end
  local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local out
  if g > 0 then
    out = ("%d|cffffd700g|r %02d|cffc7c7cfs|r"):format(g, s)
  elseif s > 0 then
    out = ("%d|cffc7c7cfs|r %02d|cffeda55fc|r"):format(s, k)
  else
    out = ("%d|cffeda55fc|r"):format(k)
  end
  return neg and ("-" .. out) or out
end

function ns.pct(v)
  if not v then return "|cff808080—|r" end
  local color = v >= 0.03 and "|cff40ff40" or (v <= -0.03 and "|cffff5050" or "|cffcccccc")
  return ("%s%+.1f%%|r"):format(color, v * 100)
end

-- GetItemInfo renvoie nil tant que l'objet n'est pas dans le cache du client :
-- on complète les métadonnées (dont le prix de rachat PNJ) quand le serveur répond.
ns.on("GET_ITEM_INFO_RECEIVED", function(itemId, success)
  if success ~= false and AHLedgerDB and AHLedgerDB.items and AHLedgerDB.items[itemId] then
    ns.rememberItem(itemId)
  end
end)

ns.on("AUCTION_HOUSE_SHOW", function() ns.ahOpen = true end)
ns.on("AUCTION_HOUSE_CLOSED", function() ns.ahOpen = false end)

ns.on("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  AHLedgerDB = AHLedgerDB or {}
  AHLedgerDB.version = AHLedgerDB.version or ns.DB_VERSION
  AHLedgerDB.realms = AHLedgerDB.realms or {}
  AHLedgerDB.items = AHLedgerDB.items or {}
  ns.dataVersion = 1
  ns.FillMissingNames()
  if ns.onLoad then ns.onLoad() end
  C_Timer.After(5, function()
    ns.print("chargé : onglet « AHLedger » dans l'hôtel des ventes, ou /ahl. Les scans complets d'Auctionator sont lus automatiquement.")
  end)
end)

SLASH_AHLEDGER1 = "/ahl"
local function slash(input)
  local cmd, rest = (input or ""):match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "" then
    ns.UI.Toggle()
  elseif cmd == "debug" then
    local canQ, canAll = CanSendAuctionQuery and CanSendAuctionQuery()
    ns.print(("HV ouvert (événement) : %s | AuctionFrame : %s | AuctionHouseFrame : %s | QueryAuctionItems : %s | requête : %s, scan complet : %s | royaume : %s"):format(
      tostring(ns.ahOpen),
      AuctionFrame and (AuctionFrame:IsShown() and "visible" or "caché") or "absent",
      AuctionHouseFrame and (AuctionHouseFrame:IsShown() and "visible" or "caché") or "absent",
      QueryAuctionItems and "oui" or "non", tostring(canQ), tostring(canAll), ns.realmKey()))
  elseif cmd == "options" or cmd == "opt" then
    ns.Options.Toggle()
  elseif cmd == "raw" then
    ns.Options.Set("keepRaw", rest ~= "off")
    ns.print("Snapshots bruts pour l'export Python : " .. (AHLedgerDB.keepRaw and "activés" or "désactivés"))
  elseif cmd == "scan" then
    ns.Scan.Start()
  elseif cmd == "status" then
    local r = ns.realmDB()
    ns.print(("%s : %d scans stockés, dernier : %s"):format(
      ns.realmKey(), #r.scans,
      r.lastScanTime and date("%d/%m %H:%M", r.lastScanTime) or "jamais"))
    if ns.Farm.current then ns.print("Session de farm en cours.") end
  elseif cmd == "farm" then
    if rest == "start" then ns.Farm.Start()
    elseif rest == "stop" then ns.Farm.Stop()
    else ns.print("/ahl farm start | stop") end
  elseif cmd == "metiers" or cmd == "métiers" or cmd == "prof" then
    ns.Prof.Report()
  elseif cmd == "monter" or cmd == "montee" or cmd == "montée" then
    ns.Plan.Command(rest)
  elseif cmd == "diag" then
    ns.Diag.Print()
  elseif cmd == "claude" or cmd == "export" or cmd == "rapport" then
    ns.Export.Show()
  elseif cmd == "bilan" then
    ns.Ledger.Report()
  elseif cmd == "fiabilite" or cmd == "fiabilité" then
    ns.Track.Report()
  elseif cmd == "prune" then
    local keep = tonumber(rest) or 0
    local r = ns.realmDB()
    while #r.scans > keep do table.remove(r.scans, 1) end
    ns.print(("Scans purgés, %d conservés. Pense à /reload pour écrire le fichier."):format(#r.scans))
  else
    ns.print("Commandes : /ahl (fenêtre) | options | scan | status | metiers | bilan | fiabilite | claude (rapport à copier) | diag | monter <métier> [niveau] | farm start | farm stop | prune <n> | raw on|off | debug")
  end
end
SlashCmdList.AHLEDGER = function(input) ns.safe("/ahl " .. (input or ""), slash, input) end
