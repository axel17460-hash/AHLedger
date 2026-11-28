-- AHLedger - Recherches à l'HV : l'enchère la moins chère vue quand le joueur cherche un objet,
-- après le dernier scan. Si elle est moins chère que le plancher du scan, le conseil (fait sur ce
-- scan) est périmé : l'infobulle le dit. Lecture seule : rien n'est cherché, acheté ni mis en vente
-- à la place du joueur ; on lit seulement les résultats des recherches qu'il lance.
local _, ns = ...
local Live = {}
ns.Live = Live

Live.MAX_AGE = 6 * 3600 -- au-delà, une recherche ne dit plus rien du marché

-- [id] = { min = prix /u, qty = unités à ce prix, t = heure } ; pour la session seulement
local seen = {}

-- rows : { { unit = prix /u, qty = unités }, ... } sans tes enchères. partial : une page seulement
-- (Classic) : on garde le plus bas déjà vu depuis le dernier scan au lieu de le remplacer.
function Live.Record(id, rows, partial)
  if not id then return end
  local best
  for _, r in ipairs(rows or {}) do
    if r.unit and r.unit > 0 and r.qty and r.qty > 0 then
      if not best or r.unit < best.min then
        best = { min = r.unit, qty = r.qty }
      elseif r.unit == best.min then
        best.qty = best.qty + r.qty
      end
    end
  end
  if ns.Undercut then ns.safe("sous-cotes", ns.Undercut.Observe, id, best and best.min, time(), partial) end
  if not best then return end -- aucune enchère d'un autre : rien à comparer
  local old = partial and Live.Get(id)
  if old and old.min < best.min then return end
  if old and old.min == best.min then best.qty = math.max(best.qty, old.qty) end
  best.t = time()
  seen[id] = best
end

-- Dernière recherche de l'objet, si elle est plus récente que le dernier scan et pas trop vieille
function Live.Get(id)
  local e = id and seen[id]
  if not e then return nil end
  local scan = ns.realmDB().lastScanTime or 0
  if e.t < scan or time() - e.t > Live.MAX_AGE then return nil end
  return e
end

local function ago(sec)
  if sec < 60 then return "<1 min" end
  if sec < 3600 then return ("%d min"):format(math.floor(sec / 60)) end
  return ("%.0f h"):format(sec / 3600)
end

-- Avertissement de l'infobulle, ou nil si la recherche ne contredit pas le scan
function Live.Warning(id)
  local e = Live.Get(id)
  if not e then return nil end
  local _, _, floor = ns.Decide.PostPrice(id, ns.Analysis.Get(id))
  if floor and e.min >= floor then return nil end
  local head = ("Recherche il y a %s : %d à %s"):format(ago(time() - e.t), e.qty, ns.money(e.min))
  if floor then
    return ("%s, moins cher que le dernier scan (%s) : conseil périmé, rescanne ou vise %s/u"):format(
      head, ns.money(floor), ns.money(math.max(e.min - 1, 1)))
  end
  return ("%s, absent du dernier scan : conseil périmé, rescanne"):format(head)
end

-- Objets « commodités » (API Retail) : tous les résultats, du moins cher au plus cher
ns.on("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
  local AH = C_AuctionHouse
  if not (itemID and AH and AH.GetNumCommoditySearchResults and AH.GetCommoditySearchResultInfo) then return end
  local rows = {}
  for i = 1, AH.GetNumCommoditySearchResults(itemID) or 0 do
    local r = AH.GetCommoditySearchResultInfo(itemID, i)
    if type(r) == "table" and r.unitPrice then
      rows[#rows + 1] = { unit = r.unitPrice, qty = (r.quantity or 0) - (r.numOwnerItems or 0) }
    end
  end
  Live.Record(itemID, rows)
end)

-- Autres objets (API Retail) : prix de rachat de l'enchère, divisé par sa quantité (même lecture
-- que Positions.lua ; à vérifier en jeu sur une pile de plus d'une unité)
ns.on("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
  local AH = C_AuctionHouse
  if type(itemKey) ~= "table" or not itemKey.itemID then return end
  if not (AH and AH.GetNumItemSearchResults and AH.GetItemSearchResultInfo) then return end
  local rows = {}
  for i = 1, AH.GetNumItemSearchResults(itemKey) or 0 do
    local r = AH.GetItemSearchResultInfo(itemKey, i)
    if type(r) == "table" and r.buyoutAmount and r.buyoutAmount > 0 and not r.containsOwnerItem then
      local q = math.max(r.quantity or 1, 1)
      rows[#rows + 1] = { unit = math.floor(r.buyoutAmount / q), qty = q }
    end
  end
  Live.Record(itemKey.itemID, rows)
end)

-- API Classic : pages de 50 résultats au plus, plusieurs objets par page
ns.on("AUCTION_ITEM_LIST_UPDATE", function()
  if ns.Scan and ns.Scan.running then return end
  if not (GetNumAuctionItems and GetAuctionItemInfo) then return end
  local batch = GetNumAuctionItems("list")
  if not batch or batch == 0 or batch > 50 then return end -- ignore les résultats d'un scan complet
  local me = UnitName and UnitName("player")
  local byId = {}
  for i = 1, batch do
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemId = GetAuctionItemInfo("list", i)
    if itemId and buyout and buyout > 0 and (not me or owner ~= me) then
      local q = math.max(count or 1, 1)
      byId[itemId] = byId[itemId] or {}
      table.insert(byId[itemId], { unit = math.floor(buyout / q), qty = q })
    end
  end
  for id, rows in pairs(byId) do Live.Record(id, rows, true) end
end)
