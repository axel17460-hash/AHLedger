-- AHLedger - Mes enchères en cours : ce que tu as en vente à l'HV, relu à chaque mise à jour de ta
-- liste d'enchères (à l'ouverture de l'HV, après une mise en vente, une vente ou une annulation).
--
-- * Rien n'est demandé au serveur sans toi : la liste vient de l'événement que le jeu envoie quand
--   l'HV, Auctionator ou Daylight UI l'affiche. Si personne ne l'a demandée quelques secondes après
--   l'ouverture de l'HV, on la demande une fois, comme le fait la fenêtre d'HV du jeu.
-- * Chaque enchère est comparée au dernier scan : sous-cotée, trop chère, temps de vente estimé.
local _, ns = ...

local Auctions = {}
ns.Auctions = Auctions

Auctions.ASK_DELAY = 4          -- secondes après l'ouverture de l'HV avant de demander la liste soi-même

Auctions.CLASSIC_LEFT = { 30 * 60, 2 * 3600, 12 * 3600, 48 * 3600 } -- durée restante max des catégories Classic 1 à 4

local visitReads = 0 -- listes relues depuis l'ouverture de l'HV (au chargement : 0, la liste sauvée n'est qu'une référence)

local function store(list)
  local c = ns.Prof.Char()
  -- mises en vente : seulement par rapport à une liste relue pendant la même visite à l'HV. Une liste
  -- d'une visite d'avant ne connaît pas ce que tu as posté depuis : tout y paraîtrait neuf.
  local prev = c.auctions
  if ns.Undercut then
    ns.safe("sous-cotes", ns.Undercut.OnOwned, prev and prev.list, list, prev ~= nil and visitReads > 0)
  end
  visitReads = visitReads + 1
  c.auctions = { t = time(), list = list }
  for _, a in ipairs(list) do ns.rememberItem(a.id) end
  ns.dataVersion = (ns.dataVersion or 0) + 1
  if ns.UI then ns.UI.OnData() end
end

-- API moderne (Forever, Retail). Le prix de rachat d'une enchère en cours est celui d'UNE unité ;
-- celui d'une enchère vendue est le total de la vente (relevé en jeu par Daylight UI).
function Auctions.ReadModern()
  local a = C_AuctionHouse
  local list = {}
  local SOLD = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1
  for i = 1, a.GetNumOwnedAuctions() or 0 do
    local r = a.GetOwnedAuctionInfo(i)
    if type(r) == "table" then
      local id = type(r.itemKey) == "table" and r.itemKey.itemID or ns.itemIdFromLink(r.itemLink)
      if id then
        local qty = tonumber(r.quantity) or 1
        local sold = r.status == SOLD
        local unit = tonumber(r.buyoutAmount)
        if unit and unit <= 0 then unit = nil end
        if unit and sold then unit = unit / qty end
        list[#list + 1] = { id = id, qty = qty, unit = unit, bid = tonumber(r.bidAmount) or 0, sold = sold,
                            left = not sold and tonumber(r.timeLeftSeconds) or nil }
      end
    end
  end
  store(list)
  return list
end

-- API Classic : GetAuctionItemInfo("owner", i) donne le rachat de la pile entière.
function Auctions.ReadClassic()
  local list = {}
  for i = 1, GetNumAuctionItems("owner") or 0 do
    local _, _, count, _, _, _, _, minBid, _, buyout, bidAmount, _, _, _, _, saleStatus, id = GetAuctionItemInfo("owner", i)
    id = id or ns.itemIdFromLink(GetAuctionItemLink and GetAuctionItemLink("owner", i))
    if id then
      local qty = math.max(count or 1, 1)
      local tl = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("owner", i)
      list[#list + 1] = { id = id, qty = qty, unit = (buyout and buyout > 0) and buyout / qty or nil,
                          bid = bidAmount and bidAmount > 0 and bidAmount or (minBid or 0), sold = saleStatus == 1,
                          left = tl and Auctions.CLASSIC_LEFT[tl] or nil }
    end
  end
  store(list)
  return list
end

local readThisVisit = false
ns.on("OWNED_AUCTIONS_UPDATED", function()
  if C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions then
    readThisVisit = true
    Auctions.ReadModern()
  end
end)
ns.on("AUCTION_OWNED_LIST_UPDATE", function()
  if GetNumAuctionItems and GetAuctionItemInfo then
    readThisVisit = true
    Auctions.ReadClassic()
  end
end)
ns.on("AUCTION_HOUSE_SHOW", function()
  readThisVisit = false
  visitReads = 0
  C_Timer.After(Auctions.ASK_DELAY, function() ns.safe("mes enchères", function()
    if readThisVisit or not ns.isAHOpen() then return end
    if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then C_AuctionHouse.QueryOwnedAuctions({}) end
  end) end)
end)

-- Tes enchères regroupées par objet et par prix, comparées au marché.
-- { id, s, qty, unit, sold (quantité vendue), left (secondes, la plus courte), value (net si tout part),
--   status = "vendu" | "sous-coté" | "ok" | "enchère seule" | "pas de marché vu", gap (ton prix / moins cher − 1), days }
function Auctions.Summary()
  local c = ns.Prof.Char()
  local data = c.auctions
  if not data then return nil end
  local groups, order = {}, {}
  for _, a in ipairs(data.list) do
    local key = a.id .. "|" .. (a.sold and "v" or "") .. "|" .. tostring(a.unit and math.floor(a.unit + 0.5) or "bid")
    local gr = groups[key]
    if not gr then
      gr = { id = a.id, unit = a.unit, bid = a.bid, qty = 0, auctions = 0, isSold = a.sold }
      groups[key] = gr
      order[#order + 1] = gr
    end
    gr.qty, gr.auctions = gr.qty + a.qty, gr.auctions + 1
    if a.left and (not gr.left or a.left < gr.left) then gr.left = a.left end
  end
  local A = ns.Analysis
  for _, gr in ipairs(order) do
    local s = A.Get(gr.id)
    gr.s = s
    local unit = gr.unit or (gr.bid > 0 and gr.bid / gr.qty) or 0
    gr.value = unit * gr.qty * (1 - A.AH_CUT)
    if gr.isSold then
      gr.status = "vendu"
    elseif not gr.unit then
      gr.status = "enchère seule"
    elseif s then
      -- la moins chère qui n'est pas à toi (Decide.PostPrice, la règle de tout l'addon) : sous-coté
      -- seulement si elle est plus basse que ton prix
      local _, _, floor = ns.Decide.PostPrice(gr.id, s)
      if floor and floor < gr.unit - 0.5 then
        gr.status, gr.gap = "sous-coté", gr.unit / floor - 1
      else
        gr.status = "ok"
      end
      local share = (s.surePerDay or 0) * A.VENDOR_SHARE
      if share > 0 then gr.days = gr.qty / share end
    else
      gr.status = "pas de marché vu"
    end
  end
  return order, data.t
end

-- "11 h", "35 min"
function Auctions.LeftText(sec)
  if not sec then return "-" end
  if sec >= 3600 then return ("%d h"):format(math.floor(sec / 3600 + 0.5)) end
  return ("%d min"):format(math.max(1, math.floor(sec / 60 + 0.5)))
end
