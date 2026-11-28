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
-- Scan tronqué (liste reçue en partie : 1 839 enchères au lieu de ~40 000 le 25/11) : ses rares
-- enchères chères passaient pour les prix du jour, et toutes les autres pour des ventes.
-- Un scan sous 35 % de la taille habituelle (médiane des 5 derniers) est refusé.
Scan.COMPLETE_SHARE = 0.35
Scan.SIZE_REF = 5
Scan.ACCEPT_AFTER = 3       -- 3 scans refusés de suite, de taille voisine (±30 %) : le marché a rétréci,
Scan.SAME_SIZE = 0.30       -- on les croit et cette taille devient la référence
-- Scan reçu à moitié (35 à 60 % de la taille habituelle) ou dont des lignes ne se sont pas chargées :
-- ses prix sont gardés, mais il n'est pas comparé au précédent (ses enchères absentes passeraient
-- pour des ventes)
Scan.DIFF_SHARE = 0.60
Scan.MISSING_SHARE = 0.02   -- plus de 2 % de lignes illisibles (et plus de 20)

-- Une erreur pendant la lecture d'un paquet laissait « Scan en cours… » jusqu'au /reload : on
-- l'affiche (ns.safe) et on arrête le scan proprement
local function guarded(label, fn)
  return function(...)
    if not ns.safe(label, fn, ...) and Scan.running then Scan.Abort("erreur pendant la lecture (détail : /ahl diag)") end
  end
end

-- timeLeft : 1 = court (<30 min), 2 = moyen (30 min-2 h), 3 = long (2-12 h), 4 = très long (>12 h)

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
  C_Timer.After(30, guarded("scan (délai)", function()
    if Scan.running and Scan.startTime == token and not Scan.rows then
      Scan.Abort("le serveur n'a pas répondu en 30 s (scan complet refusé ou délai de 15 min pas écoulé ?)")
    end
  end))
end

function Scan.OnListUpdate()
  -- Le premier événement après la requête getAll contient tout le résultat
  ns.off("AUCTION_ITEM_LIST_UPDATE", Scan.OnListUpdate)
  local _, total = GetNumAuctionItems("list")
  Scan.total = total or 0
  Scan.rows = {}
  Scan.pending = {}
  Scan.index = 0 -- certains clients indexent le résultat getAll à partir de 0 ; une ligne vide est ignorée
  guarded("scan (lecture)", Scan.ReadChunk)()
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
    C_Timer.After(0, guarded("scan (lecture)", Scan.ReadChunk))
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
  C_Timer.After(RETRY_DELAY, guarded("scan (relecture)", function()
    local still = {}
    for _, i in ipairs(Scan.pending) do
      local row = readRow(i)
      if row then Scan.rows[#Scan.rows + 1] = row else still[#still + 1] = i end
    end
    Scan.pending = still
    Scan.Retry()
  end))
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
  local rows, unread = {}, {}
  for _, e in ipairs(raw) do
    local info = e.replicateInfo or e.auctionInfo
    local tl = e.timeLeft and (e.timeLeft + 1) or 0 -- 0 = inconnu
    local r = info and rowFromInfo(info, tl)
    if r then rows[#rows + 1] = r else unread[#unread + 1] = true end
  end
  Scan.startTime = time()
  Scan.total = #raw
  Scan.pending = unread -- lignes illisibles : comptées par Scan.Finish
  Scan.rows = rows
  Scan.source = "Auctionator"
  Scan.Finish()
end

-- Snapshot compact : une seule chaîne par scan
-- champs : nb,qté,min,p25,médiane,vendu,expiré,ambigu,posté,valeurVendue,p75,vendeurs,partTop‰,annulé
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
      C_Timer.After(0, guarded("scan (lecture)", chunk))
    else
      -- relecture des objets pas encore chargés
      C_Timer.After(2, guarded("scan (relecture)", function()
        if not Scan.running then return end
        local still = {}
        for _, i in ipairs(Scan.pending) do
          local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
          local tl = C_AuctionHouse.GetReplicateItemTimeLeft(i)
          local r = rowFromInfo(info, tl and tl + 1)
          if r then Scan.rows[#Scan.rows + 1] = r else still[#still + 1] = i end
        end
        Scan.pending = still -- lignes toujours illisibles : comptées par Scan.Finish
        Scan.Finish()
      end))
    end
  end
  guarded("scan (lecture)", chunk)()
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

-- Temps restant possible (secondes) selon la tranche affichée par le jeu, pour des enchères de 12, 24 ou 48 h
local TL_RANGE = { [1] = { 0, 1800 }, [2] = { 1800, 7200 }, [3] = { 7200, 43200 }, [4] = { 43200, 172800 } }

-- Chance qu'une enchère vue dans la tranche tl ait expiré pendant gap secondes (temps restant supposé
-- uniforme dans la tranche). nil si la tranche est inconnue.
function Scan.ExpireOdds(tl, gap)
  local r = TL_RANGE[tl]
  if not r then return nil end
  if gap <= r[1] then return 0 end
  if gap >= r[2] then return 1 end
  return (gap - r[1]) / (r[2] - r[1])
end

-- Compare avec le scan précédent. Renvoie par objet les unités disparues, classées en :
--   sold : parties avant de pouvoir expirer (le temps restant dépassait l'écart entre les scans) → achetées
--   exp  : expirées (en partie estimé : une enchère qui pouvait expirer compte pour sa chance d'avoir expiré)
--   amb  : le reste des disparitions incertaines (achetée ou annulée, on ne sait pas)
--   can  : annulées, pas achetées (voir plus bas)
-- et posted : nouvelles unités apparues.
--
-- Objets qui s'empilent (tissu, cuir, minerai…) : un acheteur prend toujours le moins cher d'abord.
--  * Une enchère qui disparaît alors qu'une enchère moins chère, déjà là au scan précédent, est toujours
--    en vente n'a pas été achetée : c'est une annulation (souvent pour se remettre en vente plus bas).
--    Sans ce filtre, les relistes comptaient comme des ventes (Runecloth « 5 459 vendus/j ») et
--    gonflaient le prix réel (tes ventes réelles étaient 7 à 50 % plus basses).
--  * Un achat partiel réduit la pile : la même enchère réapparaît au même prix unitaire avec moins
--    d'unités. On compte la différence, pas la pile entière vendue plus une nouvelle pile.
-- Équipement (une même fiche d'objet regroupe plusieurs suffixes « of the Monkey »…) : l'acheteur
-- choisit, le filtre ne s'applique pas.
--
-- b.ev (journal du marché, Market.Record) : les enchères au sort sûr, une par groupe disparu :
-- { sold = true/false, unit, n (unités), life (heures en rayon, si on l'a vue arriver) }.
-- now (facultatif) sert à dater leur départ : au milieu de l'écart entre les deux scans.
function Scan.Diff(prevSigs, sigs, gap, now)
  local out = {}
  local function bucket(id)
    local b = out[id]
    if not b then b = { sold = 0, exp = 0, amb = 0, can = 0, posted = 0, soldVal = 0 }; out[id] = b end
    return b
  end
  local function parse(sig)
    local id, count, buyout = sig:match("^(%d+):(%d+):(%d+):")
    id, count, buyout = tonumber(id), tonumber(count), tonumber(buyout)
    return id, count, buyout, buyout > 0 and math.floor(buyout / count) or nil
  end

  -- par objet : enchères disparues, unités postées et unités restées, par prix unitaire
  local items = {}
  local function item(id)
    local it = items[id]
    if not it then it = { gone = {}, posted = {}, stay = {}, stack = false }; items[id] = it end
    return it
  end
  for sig, prev in pairs(prevSigs) do
    local id, count, buyout, unit = parse(sig)
    local it = item(id)
    if count > 1 then it.stack = true end
    local cur = sigs[sig]
    local kept = math.min(prev.c, cur and cur.c or 0)
    if kept > 0 and unit then it.stay[unit] = (it.stay[unit] or 0) + kept * count end
    local gone = prev.c - (cur and cur.c or 0)
    if gone > 0 then
      it.gone[#it.gone + 1] = { units = gone * count, unit = unit, tl = prev.tl or 0, buyout = buyout, f = prev.f }
    end
  end
  for sig, cur in pairs(sigs) do
    local id, count, _, unit = parse(sig)
    local it = item(id)
    if count > 1 then it.stack = true end
    local prev = prevSigs[sig]
    local added = cur.c - (prev and prev.c or 0)
    if added > 0 then
      local k = unit or -1
      it.posted[k] = (it.posted[k] or 0) + added * count
    end
  end

  for id, it in pairs(items) do
    local b = bucket(id)
    local cheapestStay
    if it.stack then
      -- achat partiel ou remise au même prix : disparu et réapparu au même prix unitaire = même stock
      for _, g in ipairs(it.gone) do
        local back = g.unit and it.posted[g.unit]
        if back and back > 0 then
          local m = math.min(back, g.units)
          g.units, it.posted[g.unit] = g.units - m, back - m
          it.stay[g.unit] = (it.stay[g.unit] or 0) + m
        end
      end
      for unit, q in pairs(it.stay) do
        if q > 0 and (not cheapestStay or unit < cheapestStay) then cheapestStay = unit end
      end
    end
    local function event(g, sold)
      if not g.unit then return end
      local life
      if now and g.f then life = math.max(0, (now - gap / 2 - g.f) / 3600) end
      b.ev = b.ev or {}
      b.ev[#b.ev + 1] = { sold = sold, unit = g.unit, n = g.units, life = life }
    end
    for _, g in ipairs(it.gone) do
      if g.units > 0 then
        local p = Scan.ExpireOdds(g.tl, gap)
        if p == nil then
          b.amb = b.amb + g.units                      -- temps restant inconnu
        elseif p >= 1 then
          b.exp = b.exp + g.units
          event(g, false)
        elseif cheapestStay and g.unit and g.unit > cheapestStay then
          b.exp = b.exp + g.units * p                  -- moins cher resté en vente : pas acheté
          b.can = b.can + g.units * (1 - p)
        elseif p <= 0 and g.unit then
          b.sold = b.sold + g.units
          b.soldVal = b.soldVal + g.units * g.unit
          event(g, true)
        else
          b.exp = b.exp + g.units * p
          b.amb = b.amb + g.units * (1 - p)
        end
      end
    end
    for _, q in pairs(it.posted) do b.posted = b.posted + q end
    -- l'historique stocke des entiers
    b.exp, b.amb, b.can = math.floor(b.exp + 0.5), math.floor(b.amb + 0.5), math.floor(b.can + 0.5)
    if b.sold == 0 and b.exp == 0 and b.amb == 0 and b.can == 0 and b.posted == 0 then out[id] = nil end
  end
  return out
end

-- Taille habituelle d'un scan complet : médiane des derniers scans acceptés (nil sous 2 scans)
function Scan.UsualSize(db)
  local sizes = {}
  for _, n in ipairs(db.scanSizes or {}) do sizes[#sizes + 1] = n end
  if #sizes < 2 then
    -- juste après la mise à jour : les tailles des scans enregistrés avant (sans le plus récent,
    -- déjà compté dans scanSizes s'il y est)
    local skip = #sizes
    for i = #(db.scans or {}) - skip, math.max(1, #(db.scans or {}) - Scan.SIZE_REF + 1), -1 do
      local n = db.scans[i].total
      if n and n > 0 then sizes[#sizes + 1] = n end
    end
  end
  if #sizes < 2 then return nil end
  table.sort(sizes)
  local m = (#sizes + 1) / 2
  return (sizes[math.floor(m)] + sizes[math.ceil(m)]) / 2
end

function Scan.IsTruncated(db, n)
  local usual = Scan.UsualSize(db)
  return usual ~= nil and n < usual * Scan.COMPLETE_SHARE, usual
end

local function rememberSize(db, n)
  db.scanSizes = db.scanSizes or {}
  table.insert(db.scanSizes, n)
  while #db.scanSizes > Scan.SIZE_REF do table.remove(db.scanSizes, 1) end
end

function Scan.Finish()
  local rows = Scan.rows
  Scan.Unmute()
  Scan.running = false
  Scan.rows = nil
  Scan.pending = Scan.pending or {}
  local db = ns.realmDB()
  local now = time()

  -- liste reçue en partie : on n'en garde rien (prix, ventes, carnet d'ordres restent ceux d'avant)
  local truncated, usual = Scan.IsTruncated(db, #rows)
  local run = db.rejectRun
  local newRef -- le marché a rétréci : ce scan devient la référence (taille et comparaison)
  if truncated then
    if run and math.abs(#rows - run.size) <= run.size * Scan.SAME_SIZE then
      run.count, run.size = run.count + 1, (run.size * run.count + #rows) / (run.count + 1)
    else
      run = { count = 1, size = #rows }
    end
    db.rejectRun = run
    if run.count >= Scan.ACCEPT_AFTER then
      truncated, usual, newRef = false, nil, true -- nouvelle référence : ce scan n'est pas « partiel » non plus
      -- la taille de la série devient la référence (avec ce scan : 2 valeurs, pas de repli sur les
      -- anciens totaux de db.scans qui ramèneraient l'ancienne taille)
      -- et il n'est pas comparé au dernier grand scan : ses enchères absentes passeraient pour des ventes
      db.scanSizes, db.rejectRun, db.lastSigs, db.sigsTime = { math.floor(run.size) }, nil, nil, nil
      ns.print(("%d scans de suite à ~%d enchères : le marché a rétréci, ce scan est gardé."):format(run.count, run.size))
    end
  else
    db.rejectRun = nil
  end
  if truncated then
    Scan.pending = nil
    db.rejected = { t = now, n = #rows, usual = math.floor(usual), src = Scan.source }
    ns.print(("|cffff9900Scan incomplet ignoré|r : %d enchères lues au lieu de ~%d d'habitude. Les prix restent ceux du scan précédent ; relance un scan complet."):format(#rows, usual))
    if ns.UI then ns.UI.OnData() end
    return
  end
  -- Scan partiel : sa taille n'entre pas dans la référence (sinon, après quelques scans partiels, la
  -- médiane baisse et les suivants ne sont plus repérés). Plusieurs de suite de taille voisine : le
  -- marché a vraiment rétréci, cette taille devient la référence.
  local half = usual and #rows < usual * Scan.DIFF_SHARE
  if half then
    local pr = db.partialRun
    if pr and math.abs(#rows - pr.size) <= pr.size * Scan.SAME_SIZE then
      pr.count, pr.size = pr.count + 1, (pr.size * pr.count + #rows) / (pr.count + 1)
    else
      pr = { count = 1, size = #rows }
    end
    db.partialRun = pr
    if pr.count >= Scan.ACCEPT_AFTER then
      db.scanSizes, db.partialRun, newRef = { math.floor(pr.size) }, nil, true
      rememberSize(db, #rows)
      ns.print(("%d scans de suite à ~%d enchères : le marché a rétréci, c'est la nouvelle taille de référence."):format(pr.count, pr.size))
    end
  else
    db.partialRun = nil
    rememberSize(db, #rows)
  end

  local items, sigs = Scan.Aggregate(rows)
  -- écart avec le scan de comparaison (db.sigsTime : le dernier scan complet, pas forcément le dernier scan)
  local base = db.sigsTime or db.lastScanTime
  local gap = base and (now - base) or nil
  local diff
  local missing = #(Scan.pending or {})
  local holes = missing > math.max(20, (#rows + missing) * Scan.MISSING_SHARE)
  if half or holes then
    db.partial = { t = now, n = #rows, usual = usual and math.floor(usual), missing = missing, src = Scan.source }
    ns.print(("|cffff9900Scan partiel|r (%s) : prix mis à jour, mais pas de ventes comptées pour ce scan."):format(
      half and ("%d enchères au lieu de ~%d"):format(#rows, usual) or ("%d lignes illisibles"):format(missing)))
  elseif db.lastSigs and gap and gap <= MAX_DIFF_GAP then
    diff = Scan.Diff(db.lastSigs, sigs, gap, now)
  end
  -- Arrivée de chaque enchère (temps en rayon, journal du marché) : déjà vue, on garde la date ;
  -- nouvelle depuis un scan comparable, elle est arrivée entre les deux (on prend le milieu) ;
  -- sinon on ne sait pas.
  for sig, cur in pairs(sigs) do
    local prev = db.lastSigs and db.lastSigs[sig]
    if prev then cur.f = prev.f
    elseif diff then cur.f = math.floor(now - gap / 2) end
  end
  if diff and ns.Market then
    for id, b in pairs(diff) do
      if b.ev then ns.safe("journal du marché", ns.Market.Record, db, id, b.ev, now) end
      b.ev = nil
    end
    ns.safe("journal du marché", ns.Market.Prune, db, now)
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
    if items[id] then stats[id] = { med = med, q = it.q, min = minP } end
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
      d and d.can or 0,
    }, ",")
  end

  if ns.Undercut then ns.safe("sous-cotes", ns.Undercut.ObserveScan, db.lastMin, now) end
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
  -- repère pour Scan.Repair : ce scan petit est voulu (marché rétréci), il ne faut pas le retirer
  if newRef and db.scans[#db.scans] and db.scans[#db.scans].t == now then db.scans[#db.scans].acc = true end
  while #db.scans > ns.MAX_SCANS do table.remove(db.scans, 1) end
  -- Un scan partiel ne sert pas de comparaison au suivant : ses enchères manquantes y passeraient pour
  -- de nouvelles mises en vente, arrivées entre les deux. On garde le dernier scan complet.
  if not ((half or holes) and not newRef) then
    db.lastSigs, db.sigsTime = sigs, now
  end
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

-- Réparation des scans tronqués enregistrés avant ce garde-fou : on retire de l'historique ce que
-- chacun y a ajouté (ses champs gardés dans db.scans), puis le scan lui-même. Si c'était le dernier,
-- les prix du jour reviennent au scan précédent (sans son carnet d'ordres, pas gardé) et le prochain
-- scan n'est pas comparé à lui. Les retraits « annulés » ne sont gardés par scan que depuis ce
-- garde-fou (14e champ) : ceux des scans plus anciens restent comptés.
local function sub0(a, b) return math.max(0, (a or 0) - (b or 0)) end
function Scan.UndoScan(db, i)
  local sc = db.scans[i]
  local H = ns.History
  local day = H.today(sc.t)
  local dayRec = db.days and db.days[day]
  if dayRec then
    dayRec.scans = sub0(dayRec.scans, 1)
    if sc.gap then dayRec.obs, dayRec.o9 = sub0(dayRec.obs, sc.gap), dayRec.o9 and sub0(dayRec.o9, sc.gap) end
  end
  for id, rest in tostring(sc.items or ""):gmatch("(%d+)=([^;]*)") do
    id = tonumber(id)
    local f = {}
    for v in rest:gmatch("[^,]+") do f[#f + 1] = tonumber(v) or 0 end
    local q, minP, med, sold, exp, amb, soldVal, can = f[2], f[3], f[5], f[6], f[7], f[8], f[10], f[14]
    local h = db.hist and db.hist[id]
    local r = h and H.parse(h[day])
    if r then
      if med and med > 0 and r.pN > 0 then
        r.pSum, r.pN = sub0(r.pSum, med), r.pN - 1
        if r.mSum then r.mSum = sub0(r.mSum, minP and minP > 0 and minP or med) end
      end
      r.qSum, r.sold, r.amb = sub0(r.qSum, q), sub0(r.sold, sold), sub0(r.amb, amb)
      r.soldVal, r.exp = sub0(r.soldVal, soldVal), sub0(r.exp, exp)
      if can then r.can = sub0(r.can, can) end
      h[day] = H.Pack(r)
    end
    local str = db.recent and db.recent[id]
    if str then db.recent[id] = str:gsub(sc.t .. ",%d+,%d+;", "") end
  end
  local wasLast = db.lastScanTime == sc.t
  table.remove(db.scans, i)
  -- c'était le scan de comparaison (un scan partiel a pu venir après) : le prochain n'est comparé à rien
  if db.sigsTime == sc.t then db.lastSigs, db.sigsTime = nil, nil end
  if wasLast then
    local prev = db.scans[#db.scans]
    db.lastSigs, db.sigsTime, db.book, db.lastMin, db.snipes = nil, nil, {}, {}, nil
    db.lastScanTime = prev and prev.t or nil
    for id, rest in tostring(prev and prev.items or ""):gmatch("(%d+)=([^;]*)") do
      local minP = tonumber(rest:match("^%d+,%d+,(%d+)"))
      if minP and minP > 0 then db.lastMin[tonumber(id)] = minP end
    end
  end
end

function Scan.Repair(db)
  db = db or ns.realmDB()
  local fixed = 0
  local i = 2
  local refFrom = 1 -- dernier scan gardé exprès petit (marché rétréci) : la référence repart de lui
  while db.scans and i <= #db.scans do
    local sc = db.scans[i]
    if sc.acc then refFrom = i end
    local sizes = {}
    for j = i - 1, math.max(refFrom, i - Scan.SIZE_REF), -1 do
      if db.scans[j].total and db.scans[j].total > 0 then sizes[#sizes + 1] = db.scans[j].total end
    end
    table.sort(sizes)
    local usual = #sizes >= 2 and (sizes[math.floor((#sizes + 1) / 2)] + sizes[math.ceil((#sizes + 1) / 2)]) / 2
    if not sc.acc and usual and sc.total and sc.total < usual * Scan.COMPLETE_SHARE then
      Scan.UndoScan(db, i)
      fixed = fixed + 1
    else
      i = i + 1
    end
  end
  if fixed > 0 then
    ns.dataVersion = (ns.dataVersion or 0) + 1
    ns.print(("%d scan(s) incomplet(s) retiré(s) de l'historique : les prix et les ventes qu'ils faussaient sont corrigés."):format(fixed))
  end
  return fixed
end
ns.on("PLAYER_LOGIN", function() ns.safe("réparation des scans", Scan.Repair) end)
