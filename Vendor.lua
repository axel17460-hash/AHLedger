-- AHLedger - Relevé des prix vendeurs PNJ, à la demande (/ahl pnj, marchand ouvert)
local _, ns = ...

-- Pas de relevé automatique des prix : hors de l'HV, AHLedger ne fait rien de lui-même. Seul un achat
-- que tu fais chez le marchand est noté (plus bas), au moment où tu cliques.
local Vendor = {}
ns.Vendor = Vendor
function Vendor.Record()
  if not (GetMerchantNumItems and GetMerchantItemLink) then return 0 end
  local db = ns.realmDB()
  local npc = UnitName("npc") or "?"
  local zone = GetZoneText() or "?"
  local n = 0
  for i = 1, GetMerchantNumItems() do
    local name, price, quantity, numAvailable, extendedCost = ns.GetMerchantItem(i)
    local id = ns.itemIdFromLink(GetMerchantItemLink(i))
    -- on ignore les objets payés en monnaie spéciale (insignes, tokens…)
    if id and price and price > 0 and not extendedCost then
      ns.rememberItem(id, name)
      -- prix à l'unité sans arrondi : 10c les 200 flèches font 0,05c, pas 0c
      local per = price / math.max(quantity or 1, 1)
      local v = db.vendor[id]
      -- garde le vendeur le moins cher connu (un ancien relevé arrondi à 0c est remplacé)
      if not v or not v.p or v.p <= 0 or per <= v.p then
        db.vendor[id] = { p = per, lim = numAvailable or -1, npc = npc, zone = zone, t = time() }
      end
      n = n + 1
    end
  end
  if n > 0 then ns.dataVersion = (ns.dataVersion or 0) + 1 end
  return n
end

-- Achats chez le marchand (1.0 phase 3) : relevés quand TU achètes, dans le même journal que tes
-- achats à l'HV (Tracker.LogBuy, marqués « PNJ »). Rien à l'ouverture du marchand : seul ton clic
-- d'achat (BuyMerchantItem) déclenche le relevé. La quantité est celle qui arrive vraiment dans tes
-- sacs (une pile de 5 achetée d'un clic compte 5) ; le prix, celui du marchand à l'unité.
Vendor.BUY_WAIT = 10 -- secondes sans rien recevoir : l'achat n'est pas passé (or, sacs pleins), on oublie
local buying = {}    -- [id] = { unit = prix /u, before = compte dans les sacs, t }

local function onBuy(index)
  local id = GetMerchantItemLink and ns.itemIdFromLink(GetMerchantItemLink(index))
  if not id then return end
  local name, price, stack, _, extendedCost = ns.GetMerchantItem(index)
  -- payé en monnaie spéciale (insignes, jetons) : pas de l'or, pas de prix de revient
  if not price or price <= 0 or extendedCost then return end
  ns.rememberItem(id, name)
  local b = buying[id]
  if not b then
    b = { before = ns.countItem(id) }
    buying[id] = b
  end
  b.unit, b.t = price / math.max(stack or 1, 1), GetTime()
end

-- Après chaque mise à jour des sacs : ce qui est arrivé depuis le clic d'achat
function Vendor.OnBags()
  local now = GetTime()
  for id, b in pairs(buying) do
    local have = ns.countItem(id)
    if now - b.t > Vendor.BUY_WAIT then
      buying[id] = nil
    elseif have > b.before then
      local got = have - b.before
      ns.Tracker.LogBuy(id, got, math.floor(got * b.unit + 0.5), nil, "PNJ")
      b.before, b.t = have, now
    else
      b.before = have -- revendu au marchand entre-temps : on repart de là
    end
  end
end

function Vendor.HookBuys()
  if Vendor.hooked or not (hooksecurefunc and BuyMerchantItem) then return end
  Vendor.hooked = true
  hooksecurefunc("BuyMerchantItem", function(index) ns.safe("achat PNJ", onBuy, index) end)
end
ns.on("PLAYER_LOGIN", function() ns.safe("achat PNJ", Vendor.HookBuys) end)
ns.on("BAG_UPDATE_DELAYED", function() if next(buying) then ns.safe("achat PNJ", Vendor.OnBags) end end)
