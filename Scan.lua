-- AHLedger - Scan complet de l'HV (API "getAll" des clients Classic)
--
-- Principe :
--  1. QueryAuctionItems(..., getAll=true) renvoie toutes les enchères d'un coup
--     (autorisé environ toutes les 15 min, cf. CanSendAuctionQuery()).
--  2. On lit les résultats par paquets (pour ne pas figer le jeu).
--  3. On agrège par objet ET on compare avec le scan précédent pour estimer
--     ce qui a disparu (vendu / annulé / expiré) et ce qui a été posté.
local _, ns = ...

local Scan = {}
ns.Scan = Scan

local CHUNK = 400            -- enchères lues par frame
local RETRY_PASSES = 4       -- relectures des lignes incomplètes (hasAllInfo == false)
local RETRY_DELAY = 0.5
local MAX_DIFF_GAP = 12 * 3600 -- au-delà, la comparaison avec le scan précédent n'a plus de sens

-- timeLeft : 1 = court (<30 min), 2 = moyen (30 min-2 h), 3 = long (2-12 h), 4 = très long (>12 h)
local TL_MIN_SECONDS = { [1] = 0, [2] = 1800, [3] = 7200, [4] = 43200 }

local function weightedPercentile(prices, p)
  -- prices : liste de {unit, qty} triée par unit
  local total = 0
  for _, e in ipairs(prices) do total = total + e[2] end
  if total == 0 then return 0 end
  local target, acc = total * p, 0
  for _, e in ipairs(prices) do
    acc = acc + e[2]
    if acc >= target then return e[1] end
  end
  return prices[#prices][1]
end

function Scan.Start()
  ns.print("Demande de scan…")
  if Scan.running then ns.print("Scan déjà en cours.") return end
  if not ns.isAHOpen() then
    ns.print("Ouvre l'hôtel des ventes d'abord.")
    return
  end
  if ns.Bridge and ns.Bridge.CanScan() then
    ns.Bridge.StartScan() -- le résultat revient via Scan.FromAuctionator
    return
  end
  if not QueryAuctionItems then
    if C_AuctionHouse and C_AuctionHouse.ReplicateItems then return Scan.StartReplicate() end
    ns.print("|cffff5050Aucune API de scan complet disponible.|r")
    return
  end
  local _, canQueryAll = CanSendAuctionQuery()
  if not canQueryAll then
    ns.print("Scan complet pas encore disponible (limite serveur ~15 min). Réessaie plus tard.")
    return
  end
  Scan.running = true
  Scan.startTime = time()
  Scan.source = nil
  -- Comme Auctionator : on coupe les autres cadres (dont l'onglet Parcourir de Blizzard)
  -- pendant le scan complet, sinon ils traitent des dizaines de milliers de lignes et le jeu rame.
  if GetFramesRegisteredForEvent then
    Scan.muted = {}
    for _, f in ipairs({ GetFramesRegisteredForEvent("AUCTION_ITEM_LIST_UPDATE") }) do
      if f ~= ns.frame then
        f:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
        Scan.muted[#Scan.muted + 1] = f
      end
    end
  end
  if ITEM_QUALITY_COLORS and not ITEM_QUALITY_COLORS[-1] then
    ITEM_QUALITY_COLORS[-1] = { r = 0, g = 0, b = 0 } -- contournement d'une erreur Blizzard (repris d'Auctionator)
  end
  ns.on("AUCTION_ITEM_LIST_UPDATE", Scan.OnListUpdate)
  ns.print("Scan complet lancé, ne ferme pas l'HV…")
  QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil) -- mêmes arguments qu'Auctionator
  local token = Scan.startTime
  C_Timer.After(30, function()
    if Scan.running and Scan.startTime == token and not Scan.rows then
      Scan.Abort("le serveur n'a pas répondu en 30 s (scan complet refusé ou délai de 15 min pas écoulé ?)")
    end
  end)
end

function Scan.OnListUpdate()
  -- Le premier événement après la requête getAll contient tout le résultat
  ns.off("AUCTION_ITEM_LIST_UPDATE", Scan.OnListUpdate)
  local _, total = GetNumAuctionItems("list")
  Scan.total = total or 0
  Scan.rows = {}
  Scan.pending = {}
  Scan.index = 0 -- certains clients indexent le résultat getAll à partir de 0 ; une ligne vide est ignorée
  Scan.ReadChunk()
end

local function readRow(i)
  local name, _, count, _, _, _, _, minBid, minInc, buyout, bid, _, _, owner, ownerFull, _, itemId, hasAllInfo =
    GetAuctionItemInfo("list", i)
  if not itemId or itemId == 0 or not name then return nil end
  if hasAllInfo == false then return nil end
  return {
    id = itemId,
    name = name,
    count = count or 1,
    buyout = buyout or 0,
    minBid = minBid or 0,
    minInc = minInc or 0,
    bid = bid or 0,
    owner = ownerFull or owner or "?",
    tl = GetAuctionItemTimeLeft("list", i) or 0,
  }
end

function Scan.ReadChunk()
  if not Scan.running then return end
  local last = math.min(Scan.index + CHUNK - 1, Scan.total)
  for i = Scan.index, last do
    local row = readRow(i)
    if row then Scan.rows[#Scan.rows + 1] = row elseif i > 0 then Scan.pending[#Scan.pending + 1] = i end
  end
  Scan.index = last + 1
  if Scan.index <= Scan.total then
    C_Timer.After(0, Scan.ReadChunk)
  else
    Scan.retryPass = 0
    Scan.Retry()
  end
end

function Scan.Retry()
  if #Scan.pending == 0 or Scan.retryPass >= RETRY_PASSES then
    Scan.Finish()
    return
  end
  Scan.retryPass = Scan.retryPass + 1
  C_Timer.After(RETRY_DELAY, function()
    local still = {}
    for _, i in ipairs(Scan.pending) do
      local row = readRow(i)
      if row then Scan.rows[#Scan.rows + 1] = row else still[#still + 1] = i end
    end
    Scan.pending = still
    Scan.Retry()
  end)
end

-- Convertit une ligne d'infos d'enchère (format GetAuctionItemInfo / GetReplicateItemInfo)
local function rowFromInfo(info, tl)
  local itemId = info[17]
  if not itemId or itemId == 0 or not info[1] then return nil end
  return {
    id = itemId, name = info[1], count = info[3] or 1, minBid = info[8] or 0, minInc = info[9] or 0,
    buyout = info[10] or 0, bid = info[11] or 0, owner = info[15] or info[14] or "?", tl = tl or 0,
  }
end

-- Résultat d'un scan complet d'Auctionator (version moderne : replicateInfo + timeLeft 0-3,
-- version Classic : auctionInfo sans temps restant)
function Scan.FromAuctionator(raw)
  -- déjà lu directement via REPLICATE_ITEM_LIST_UPDATE ? on évite le doublon
  if Scan.running or Scan.RecentlyDone() then return end
  local rows = {}
  for _, e in ipairs(raw) do
    local info = e.replicateInfo or e.auctionInfo
    local tl = e.timeLeft and (e.timeLeft + 1) or 0 -- 0 = inconnu
    local r = info and rowFromInfo(info, tl)
    if r then rows[#rows + 1] = r end
  end
  Scan.startTime = time()
  Scan.total = #raw
  Scan.pending = {}
  Scan.rows = rows
  Scan.source = "Auctionator"
  Scan.Finish()
end

-- Snapshot compact : une seule chaîne par scan
-- champs : nb,qté,min,p25,médiane,vendu,expiré,ambigu,posté,valeurVendue,p75,vendeurs,partTop‰
function Scan.PackItems(packed)
  local parts = {}
  for id, s in pairs(packed) do parts[#parts + 1] = id .. "=" .. s end
  return table.concat(parts, ";")
end

-- Carnet d'ordres compact : "vendeurs,partTop‰|prix:qté;prix:qté;…" (prix unitaires croissants,
-- quantités cumulées par prix, BOOK_LEVELS niveaux au plus)
Scan.BOOK_LEVELS = 15
function Scan.PackBook(prices, sellers, topPermille)
  local levels = {}
  for _, e in ipairs(prices) do
    local last = levels[#levels]
    if last and last[1] == e[1] then
      last[2] = last[2] + e[2]
    elseif #levels < Scan.BOOK_LEVELS then
      levels[#levels + 1] = { e[1], e[2] }
    else
      break
    end
  end
  local parts = {}
  for i, l in ipairs(levels) do parts[i] = l[1] .. ":" .. l[2] end
  return sellers .. "," .. topPermille .. "|" .. table.concat(parts, ";")
end

function Scan.UnpackBook(str)
  if not str then return nil end
  local sellers, top, rest = str:match("^(%d+),(%d+)|(.*)$")
  if not sellers then return nil end
  local levels = {}
  for p, q in rest:gmatch("(%d+):(%d+)") do levels[#levels + 1] = { tonumber(p), tonumber(q) } end
  sellers = tonumber(sellers)
  return { sellers = sellers > 0 and sellers or nil, top = sellers > 0 and tonumber(top) / 1000 or nil, levels = levels }
end

function Scan.RecentlyDone()
  local db = ns.realmDB()
  return db.lastScanTime and time() - db.lastScanTime < 120
end

-- Scan complet avec l'API Retail, quand Auctionator n'est pas là pour le lancer
function Scan.StartReplicate()
  ns.print("Scan complet lancé (API Retail), ne ferme pas l'HV…")
  C_AuctionHouse.ReplicateItems()
end

-- Le jeu diffuse REPLICATE_ITEM_LIST_UPDATE à tous les addons quand un scan complet
-- (lancé par Auctionator ou par nous) est prêt : on lit la liste nous-mêmes.
ns.on("REPLICATE_ITEM_LIST_UPDATE", function()
  if Scan.running or Scan.RecentlyDone() then return end
  local n = C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
  if n == 0 then return end
  Scan.running = true
  Scan.startTime = time()
  Scan.source = "Auctionator"
  Scan.OnReplicate()
end)

function Scan.OnReplicate()
  Scan.total = C_AuctionHouse.GetNumReplicateItems()
  Scan.rows, Scan.pending, Scan.index = {}, {}, 0
  local function chunk()
    if not Scan.running then return end
    local last = math.min(Scan.index + CHUNK - 1, Scan.total - 1)
    for i = Scan.index, last do
      local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
      local tl = C_AuctionHouse.GetReplicateItemTimeLeft(i)
      local r = info[18] ~= false and rowFromInfo(info, tl and tl + 1)
      if r then Scan.rows[#Scan.rows + 1] = r elseif info[17] then Scan.pending[#Scan.pending + 1] = i end
    end
    Scan.index = last + 1
    if Scan.index < Scan.total then
      C_Timer.After(0, chunk)
    else
      -- relecture des objets pas encore chargés
      C_Timer.After(2, function()
        if not Scan.running then return end
        for _, i in ipairs(Scan.pending) do
          local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
          local tl = C_AuctionHouse.GetReplicateItemTimeLeft(i)
          local r = rowFromInfo(info, tl and tl + 1)
          if r then Scan.rows[#Scan.rows + 1] = r end
        end
        Scan.pending = {}
        Scan.Finish()
      end)
    end
  end
  chunk()
end

function Scan.Unmute()
  for _, f in ipairs(Scan.muted or {}) do f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE") end
  Scan.muted = nil
end

function Scan.Abort(reason)
  if not Scan.running then return end
  Scan.Unmute()
  Scan.running = false
  ns.off("AUCTION_ITEM_LIST_UPDATE", Scan.OnListUpdate)
  Scan.rows, Scan.pending = nil, nil
  ns.print("Scan interrompu : " .. reason)
  if ns.UI then ns.UI.OnData() end -- le bouton « Scan en cours… » redevient « Scanner l'HV »
end

-- Construit l'agrégat par objet + les signatures d'enchères pour le diff
function Scan.Aggregate(rows)
  local items, sigs = {}, {}
  for _, r in ipairs(rows) do
    local it = items[r.id]
    if not it then
      it = { n = 0, q = 0, prices = {}, owners = {} }
      items[r.id] = it
      ns.rememberItem(r.id, r.name)
    end
    it.n = it.n + 1
    it.owners[r.owner] = (it.owners[r.owner] or 0) + r.count
    it.q = it.q + r.count
    if r.buyout > 0 then
      it.prices[#it.prices + 1] = { math.floor(r.buyout / r.count), r.count }
    end
    -- signature d'une enchère : même objet, même pile, même prix, même vendeur
    local sig = r.id .. ":" .. r.count .. ":" .. r.buyout .. ":" .. r.owner
    local s = sigs[sig]
    if s then
      s.c = s.c + 1
      if r.tl < s.tl then s.tl = r.tl end
    else
      sigs[sig] = { c = 1, tl = r.tl }
    end
  end
  return items, sigs
end

-- Compare avec le scan précédent.
-- Renvoie par objet : unités disparues classées en
--   sold  : avaient au moins 2 h restantes ET l'écart entre scans est plus court → vendues (ou annulées)
--   exp   : étaient en "court" → très probablement expirées
--   amb   : cas ambigus
-- et posted : nouvelles unités apparues.
function Scan.Diff(prevSigs, sigs, gap)
  local out = {}
  local function bucket(id)
    local b = out[id]
    if not b then b = { sold = 0, exp = 0, amb = 0, posted = 0, soldVal = 0 }; out[id] = b end
    return b
  end
  for sig, prev in pairs(prevSigs) do
    local cur = sigs[sig]
    local gone = prev.c - (cur and cur.c or 0)
    if gone > 0 then
      local id, count, buyout = sig:match("^(%d+):(%d+):(%d+):")
      id, count, buyout = tonumber(id), tonumber(count), tonumber(buyout)
      local units = gone * count
      local b = bucket(id)
      if prev.tl == 0 then
        b.amb = b.amb + units -- temps restant inconnu
      elseif prev.tl <= 1 then
        b.exp = b.exp + units
      elseif TL_MIN_SECONDS[prev.tl] and gap < TL_MIN_SECONDS[prev.tl] and buyout > 0 then
        b.sold = b.sold + units
        b.soldVal = b.soldVal + gone * buyout
      else
        b.amb = b.amb + units
      end
    end
  end
  for sig, cur in pairs(sigs) do
    local prev = prevSigs[sig]
    local added = cur.c - (prev and prev.c or 0)
    if added > 0 then
      local id, count = sig:match("^(%d+):(%d+):")
      local b = bucket(tonumber(id))
      b.posted = b.posted + added * tonumber(count)
    end
  end
  return out
end

function Scan.Finish()
  local rows = Scan.rows
  Scan.Unmute()
  Scan.running = false
  Scan.rows = nil
  Scan.pending = Scan.pending or {}
  local db = ns.realmDB()
  local now = time()

  local items, sigs = Scan.Aggregate(rows)
  local gap = db.lastScanTime and (now - db.lastScanTime) or nil
  local diff
  if db.lastSigs and gap and gap <= MAX_DIFF_GAP then
    diff = Scan.Diff(db.lastSigs, sigs, gap)
  end

  -- Format compact par objet : "nb,qté,min,p25,médiane,vendu,expiré,ambigu,posté,valeurVendue"
  local packed, stats = {}, {}
  db.lastMin = {} -- prix d'achat le plus bas à l'unité, au dernier scan
  db.book = {}    -- carnet d'ordres du dernier scan (onglet Flip HV, concurrence)
  local ids = {}
  for id in pairs(items) do ids[id] = true end
  if diff then for id in pairs(diff) do ids[id] = true end end
  for id in pairs(ids) do
    local it = items[id] or { n = 0, q = 0, prices = {} }
    table.sort(it.prices, function(a, b) return a[1] < b[1] end)
    local minP = it.prices[1] and it.prices[1][1] or 0
    if minP > 0 then db.lastMin[id] = minP end
    local d = diff and diff[id]
    local med = weightedPercentile(it.prices, 0.5)
    if items[id] then stats[id] = { med = med, q = it.q } end
    -- structure du marché : nombre de vendeurs et part du plus gros (en ‰ des unités).
    -- Forever ne transmet pas le nom des vendeurs (comme le Retail moderne) : vendeur inconnu
    -- = non compté, et 0 vendeur connu = structure du marché inconnue.
    local sellers, top = 0, 0
    for owner, q in pairs(it.owners or {}) do
      if owner ~= "?" and owner ~= "" then
        sellers = sellers + 1
        if q > top then top = q end
      end
    end
    if items[id] and it.q > 0 then db.book[id] = Scan.PackBook(it.prices, sellers, math.floor(top * 1000 / it.q)) end
    packed[id] = table.concat({
      it.n, it.q, minP,
      weightedPercentile(it.prices, 0.25),
      med,
      d and d.sold or 0, d and d.exp or 0, d and d.amb or 0, d and d.posted or 0,
      d and d.soldVal or 0,
      weightedPercentile(it.prices, 0.75),
      sellers,
      it.q > 0 and math.floor(top * 1000 / it.q) or 0,
    }, ",")
  end

  ns.History.Record(db, now, stats, diff, diff and gap or nil)
  ns.History.RecordRecent(db, now, stats)
  ns.Snipe.FromScan(rows, now)

  -- Snapshots bruts : seulement pour l'export Python (/ahl raw on), car volumineux
  if AHLedgerDB.keepRaw ~= false then
    db.scans[#db.scans + 1] = {
      t = now,
      dur = now - Scan.startTime,
      total = Scan.total,
      missing = #Scan.pending,
      gap = diff and gap or nil,   -- présent seulement si le diff est exploitable
      v = 2,               -- format : une chaîne "id=champs;id=champs…" (plus léger à charger)
      src = Scan.source or "AHLedger",
      items = Scan.PackItems(packed),
    }
  end
  while #db.scans > ns.MAX_SCANS do table.remove(db.scans, 1) end
  db.lastSigs = sigs
  db.lastScanTime = now
  Scan.pending = nil

  ns.print(("Scan %sterminé : %d enchères lues%s. /ahl pour voir le classement.")
    :format(Scan.source == "Auctionator" and "Auctionator " or "", #rows, diff and (", comparées au scan d'il y a " .. math.floor(gap / 60) .. " min") or ""))
  if ns.UI then ns.UI.OnData() end
  if ns.Export then ns.safe("rapport", ns.Export.Save) end -- toujours à jour dans les SavedVariables
end

ns.on("AUCTION_HOUSE_CLOSED", function()
  if Scan.running then Scan.Abort("HV fermé") end
end)
