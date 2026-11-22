-- AHLedger - Pont avec Auctionator
--
-- 1. Quand Auctionator termine un scan complet, il diffuse la liste brute des enchères
--    (événement interne "get_all_scan_complete"). AHLedger l'exploite directement :
--    un seul scan pour les deux addons, un seul délai de 15 min.
-- 2. L'historique de prix d'Auctionator (jusqu'à ~21 jours) sert à calculer les tendances
--    tant qu'AHLedger n'a pas encore 3 jours de scans à lui.
-- Ces deux points utilisent des fonctions internes d'Auctionator : tout est protégé,
-- si une mise à jour d'Auctionator les change, AHLedger retombe sur son propre scan.
local _, ns = ...

local Bridge = {}
ns.Bridge = Bridge

function Bridge.HasAuctionator()
  return Auctionator ~= nil and Auctionator.EventBus ~= nil
end

function Bridge.CanScan()
  return Auctionator and Auctionator.State and Auctionator.State.FullScanFrameRef
    and Auctionator.State.FullScanFrameRef.InitiateScan ~= nil
end

-- Lance le scan complet d'Auctionator (le résultat nous revient via l'événement)
function Bridge.StartScan()
  ns.print("Scan complet lancé via Auctionator…")
  Auctionator.State.FullScanFrameRef:InitiateScan()
end

local listener = {}
function listener:ReceiveEvent(eventName, raw)
  if eventName == Bridge.scanCompleteEvent and type(raw) == "table" then
    ns.safe("scan Auctionator", ns.Scan.FromAuctionator, raw)
  end
end

function Bridge.Hook()
  if Bridge.hooked or not Bridge.HasAuctionator() then return end
  local ev = Auctionator.FullScan and Auctionator.FullScan.Events and Auctionator.FullScan.Events.ScanComplete
  if not ev then return end
  Bridge.scanCompleteEvent = ev
  Auctionator.EventBus:Register(listener, { ev })
  Bridge.hooked = true
end

ns.on("PLAYER_LOGIN", function() Bridge.Hook() end)
ns.on("AUCTION_HOUSE_SHOW", function() Bridge.Hook() end)

-- Historique Auctionator d'un objet : liste de { jourRelatif, prixMin, quantité }
-- (jourRelatif = 0 pour aujourd'hui, -1 pour hier…)
function Bridge.History(itemId, maxDays)
  if not (Auctionator and Auctionator.Database and Auctionator.Database.db and Auctionator.Constants) then
    return nil
  end
  local entry = Auctionator.Database.db[tostring(itemId)]
  if type(entry) ~= "table" or type(entry.h) ~= "table" then return nil end
  local day0 = Auctionator.Constants.SCAN_DAY_0
  if not day0 then return nil end
  local today = math.floor((time() - day0) / 86400)
  local out = {}
  for d = today - (maxDays or 14) + 1, today do
    local k = tostring(d)
    local price = (entry.l and entry.l[k]) or entry.h[k]
    if price and price > 0 then
      out[#out + 1] = { d - today, price, entry.a and entry.a[k] }
    end
  end
  return out
end
