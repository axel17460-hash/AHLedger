-- AHLedger - Détecteur "revente PNJ" : enchères moins chères que le prix de rachat du marchand
--
-- Deux sources :
--  * le scan complet : toutes les opportunités du moment, listées dans l'onglet "Revente PNJ" ;
--  * la navigation normale à l'HV : alerte dans le chat dès qu'une page affichée en contient une.
-- L'achat reste manuel (un clic du joueur dans l'interface Blizzard) : rien n'est acheté automatiquement.
local _, ns = ...

local Snipe = {}
ns.Snipe = Snipe

Snipe.MIN_PROFIT = 20      -- cuivre minimum de bénéfice par enchère
Snipe.MAX_KEEP = 150
Snipe.BID_MAX_TL = 2       -- enchères (sans achat immédiat) signalées seulement si elles finissent sous 2 h

local function vendorValue(id)
  local meta = AHLedgerDB.items[id]
  if not meta or not meta.s then ns.rememberItem(id); meta = AHLedgerDB.items[id] end
  return meta and meta.s or 0
end

-- row : { id, count, buyout, minBid, bid, minInc, tl, owner, name }
-- Renvoie une opportunité ou nil
function Snipe.Evaluate(row)
  local unit = vendorValue(row.id)
  if unit <= 0 then return nil end
  local value = unit * row.count
  if row.buyout > 0 and value - row.buyout >= Snipe.MIN_PROFIT then
    return { kind = "achat", cost = row.buyout, value = value, profit = value - row.buyout }
  end
  local nextBid = (row.bid and row.bid > 0) and (row.bid + (row.minInc or 0)) or row.minBid
  if nextBid and nextBid > 0 and row.tl <= Snipe.BID_MAX_TL and value - nextBid >= Snipe.MIN_PROFIT then
    return { kind = "enchère", cost = nextBid, value = value, profit = value - nextBid }
  end
end

-- Appelé à la fin d'un scan complet
function Snipe.FromScan(rows, now)
  local list = {}
  for _, r in ipairs(rows) do
    local o = Snipe.Evaluate(r)
    if o then
      o.id, o.name, o.count, o.owner, o.t = r.id, r.name, r.count, r.owner, now
      o.unitCost, o.unitValue = o.cost / r.count, o.value / r.count
      list[#list + 1] = o
    end
  end
  table.sort(list, function(a, b) return a.profit > b.profit end)
  while #list > Snipe.MAX_KEEP do table.remove(list) end
  ns.realmDB().snipes = list
  if #list > 0 then
    local total = 0
    for _, o in ipairs(list) do total = total + o.profit end
    ns.print(("|cff40ff40%d objets à revendre au PNJ|r pour %s de bénéfice au total (onglet Marché, vue Revente PNJ).")
      :format(#list, ns.money(total)))
  end
  return list
end

-- Lance une recherche normale pour afficher l'objet dans l'onglet "Parcourir" de Blizzard
-- Affiche un objet à l'achat dans l'HV ouverte, sur l'écran que le joueur voit. Une seule recherche,
-- lancée par son clic ; l'achat reste à faire à la main. Renvoie le chemin pris, ou nil.
function Snipe.ShowOnAH(name)
  if not name or name == "" then return nil end
  local ah = AuctionHouseFrame
  local box = type(ah) == "table" and type(ah.SearchBar) == "table" and ah.SearchBar.SearchBox
  -- Daylight UI : sa fenêtre HV remplace celle du jeu et lance sur Achat ce qui arrive dans la case de
  -- recherche du jeu (comme un Maj-clic sur un objet des sacs)
  local dl = ns.UI and ns.UI.dlMain
  if box and dl and type(dl.frame) == "table" and dl.frame.IsShown and dl.frame:IsShown() then
    box:SetText("")
    box:SetText(name)
    return "daylight"
  end
  -- Auctionator : son API publique de recherche (onglet Achats)
  if not QueryAuctionItems and Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.MultiSearch then
    Auctionator.API.v1.MultiSearch("AHLedger", { name })
    return "auctionator"
  end
  -- Fenêtre HV moderne du jeu
  if box and ah.IsShown and ah:IsShown() then
    if ah.SetDisplayMode and AuctionHouseFrameDisplayMode and AuctionHouseFrameDisplayMode.Buy then
      ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
    end
    box:SetText(name)
    if ah.SearchBar.StartSearch then ah.SearchBar:StartSearch() end
    return "jeu"
  end
  return nil
end

function Snipe.Search(o, msg)
  if not ns.isAHOpen() then
    ns.print("Ouvre l'HV pour rechercher " .. (o.name or "l'objet") .. ".")
    return
  end
  if not QueryAuctionItems then
    local route = Snipe.ShowOnAH(o.name)
    if not route then
      ns.print("Cherche « " .. (o.name or "?") .. " » dans l'HV pour l'acheter.")
    elseif msg ~= false then
      ns.print(msg or ("Recherche : %s — pile de %d à %s (revente PNJ %s)."):format(
        o.name or "?", o.count or 1, ns.money(o.cost or 0), ns.money(o.value or 0)))
    end
    return route
  end
  if not CanSendAuctionQuery() then
    ns.print("Recherche impossible pour l'instant (limite serveur), réessaie dans quelques secondes.")
    return
  end
  if AuctionFrameTab1 and AuctionFrameTab_OnClick then AuctionFrameTab_OnClick(AuctionFrameTab1) end
  if BrowseName then BrowseName:SetText(o.name or "") end
  QueryAuctionItems(o.name or "", nil, nil, 0, false, -1, false, true, nil)
  if msg ~= false then
    ns.print(msg or ("Recherche : %s — cherche la pile de %d à %s (revente PNJ %s)."):format(
      o.name or "?", o.count or 1, ns.money(o.cost or 0), ns.money(o.value or 0)))
  end
  return "classique"
end

-- Alerte en direct pendant la navigation à l'HV (pages de 50 résultats maxi)
local seen = {}
ns.on("AUCTION_ITEM_LIST_UPDATE", function()
  if ns.Scan.running then return end
  if not GetNumAuctionItems then return end
  local batch = GetNumAuctionItems("list")
  if not batch or batch == 0 or batch > 50 then return end -- ignore les résultats d'un scan complet
  for i = 1, batch do
    local name, _, count, _, _, _, _, minBid, minInc, buyout, bid, _, _, owner, ownerFull, _, itemId, hasAll =
      GetAuctionItemInfo("list", i)
    if hasAll and itemId then
      local row = { id = itemId, name = name, count = count or 1, buyout = buyout or 0, minBid = minBid or 0,
                    bid = bid or 0, minInc = minInc or 0, tl = GetAuctionItemTimeLeft("list", i) or 4,
                    owner = ownerFull or owner or "?" }
      local o = Snipe.Evaluate(row)
      if o then
        local key = itemId .. ":" .. row.count .. ":" .. o.cost .. ":" .. row.owner
        if not seen[key] then
          seen[key] = true
          local link = GetAuctionItemLink("list", i) or name
          ns.print(("|cff40ff40Revente PNJ|r %s x%d : %s %s - PNJ %s (|cff40ff40+%s|r)"):format(
            link, row.count, o.kind == "achat" and "achat immédiat" or "enchère",
            ns.money(o.cost), ns.money(o.value), ns.money(o.profit)))
          if PlaySound and SOUNDKIT and SOUNDKIT.MONEY_FRAME_OPEN then PlaySound(SOUNDKIT.MONEY_FRAME_OPEN) end
        end
      end
    end
  end
end)

ns.on("AUCTION_HOUSE_CLOSED", function() seen = {} end)
