-- AHLedger - Analyse : prix, volume, tendances, signaux d'anticipation
local _, ns = ...

local Analysis = {}
ns.Analysis = Analysis

Analysis.AH_CUT = 0.05          -- commission HV : 5 % (mesuré sur Forever le 23/11/2026) ; remplacée par la mesure de Ledger.Calibrate
Analysis.TREND_DAYS = 7         -- fenêtre de la régression de prix
Analysis.MIN_SOLD_FOR_REAL = 5  -- unités vendues mini pour faire confiance au prix réel de vente
Analysis.DEPOSIT_RATE = 0.15    -- dépôt par mise en vente, en part du prix PNJ : valeur par défaut, remplacée par la mesure
                                -- de Ledger.Calibrate dès 5 ventes (Forever : ~43 % mesuré sur 18 ventes le 24/11/2026,
                                -- selon la durée de mise en vente choisie)
Analysis.HEAVY_STOCK_DAYS = 7   -- au-delà de 7 jours de ventes déjà en rayon, le marché est saturé
-- Flip HV : acheter les enchères trop basses et les remettre au prix du marché
Analysis.FLIP_HOLD_DAYS = 2     -- on n'achète pas plus que ce qui se revend en 2 jours
Analysis.FLIP_MIN_ROI = 0.15    -- marge mini de 15 % après commission et dépôts
Analysis.FLIP_MIN_PROFIT = 2000 -- 20 pa mini par opération
-- Flip à stocker : le marché entier est bas, on achète et on attend que le prix remonte
Analysis.FLIP_STORE_MIN_ROI = 0.25  -- l'or reste immobilisé et le prix peut ne pas remonter : marge mini plus haute
Analysis.FLIP_STORE_GAP = 0.10      -- le prix habituel doit dépasser d'au moins 10 % la revente possible tout de suite
Analysis.FLIP_TEST_DAYS = 0.5       -- rebonds encore inconnus : on n'achète qu'une demi-journée de ventes
Analysis.FLIP_TEST_MAX_QTY = 20     -- ... sans dépasser 20 unités (le volume estimé peut être gonflé par les annulations)
Analysis.FLIP_TEST_MAX_COST = 200000 -- ... ni 20 po d'achat

local History = ns.History

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Pente d'une régression linéaire y = a + b.x
local function slope(pts)
  local n = #pts
  if n < 3 then return nil end
  local sx, sy, sxx, sxy = 0, 0, 0, 0
  for _, p in ipairs(pts) do
    sx, sy = sx + p[1], sy + p[2]
    sxx, sxy = sxx + p[1] * p[1], sxy + p[1] * p[2]
  end
  local den = n * sxx - sx * sx
  if den == 0 then return nil end
  return (n * sxy - sx * sy) / den
end

-- Comme slope(), mais accepte 2 points (tendance indicative)
local function slope2(pts)
  if #pts == 2 then
    local dx = pts[2][1] - pts[1][1]
    return dx ~= 0 and (pts[2][2] - pts[1][2]) / dx or nil
  end
  return slope(pts)
end

-- Pente robuste (Theil-Sen) : médiane des pentes entre toutes les paires de points.
-- Une seule enchère aberrante (pile à 1 pc, ou à 1000 po) ne fait plus exploser la tendance.
-- Exige au moins 3 points répartis sur au moins minSpan jours.
local function robustSlope(pts, minSpan)
  if #pts < 3 then return nil end
  local lo, hi = math.huge, -math.huge
  for _, p in ipairs(pts) do lo, hi = math.min(lo, p[1]), math.max(hi, p[1]) end
  if hi - lo < (minSpan or 0) then return nil end
  local s = {}
  for i = 1, #pts - 1 do
    for j = i + 1, #pts do
      local dx = pts[j][1] - pts[i][1]
      if dx ~= 0 then s[#s + 1] = (pts[j][2] - pts[i][2]) / dx end
    end
  end
  if #s == 0 then return nil end
  table.sort(s)
  local m = (#s + 1) / 2
  return (s[math.floor(m)] + s[math.ceil(m)]) / 2
end
Analysis.robustSlope = robustSlope

-- Tendance courte : régression sur les scans des dernières 24 h (%/jour), et variation sur la période
function Analysis.ShortTrend(db, id, now)
  local pts, first, last = {}, nil, nil
  for _, p in ipairs(History.Recent(db, id)) do
    if p[1] >= now - 86400 then
      pts[#pts + 1] = { (p[1] - now) / 86400, math.log(p[2]) }
      first = first or p
      last = p
    end
  end
  if #pts < 2 or (last[1] - first[1]) < 2 * 3600 then return nil end
  local b = slope2(pts)
  return b and (math.exp(b) - 1), last[2] / first[2] - 1, #pts, (last[1] - first[1]) / 3600
end

-- Statistiques d'un objet sur les 14 derniers jours
function Analysis.ItemStats(db, id, today)
  local h = db.hist and db.hist[id]
  if not h then return nil end
  today = today or History.today()

  local pts = {}
  local w = { sold = 0, amb = 0, val = 0, obs = 0, exp = 0, can = 0 }   -- 7 derniers jours
  local recent = { sold = 0, obs = 0, q = 0, qn = 0 }          -- 0-2 jours
  local prior = { sold = 0, obs = 0, q = 0, qn = 0 }           -- 3-9 jours
  local priceNow, priceDay, days = nil, nil, 0

  for d = today - 13, today do
    local dr = db.days[d]
    if dr then
      local age = today - d
      local r = History.parse(h[d])
      if r and r.pN > 0 then
        local p = r.pSum / r.pN
        if age < Analysis.TREND_DAYS then pts[#pts + 1] = { d - today, math.log(p) } end
        if not priceDay or d > priceDay then priceNow, priceDay = p, d end
        days = days + 1
      end
      local sold = r and (r.sold + 0.5 * r.amb) or 0
      local stock = (r and r.qSum or 0) / math.max(dr.scans, 1)
      if age < 7 then
        w.sold = w.sold + (r and r.sold or 0)
        w.amb = w.amb + (r and r.amb or 0)
        w.val = w.val + (r and r.soldVal or 0)
        w.exp = w.exp + (r and r.exp or 0)
        w.can = w.can + (r and r.can or 0)
        w.obs = w.obs + dr.obs
      end
      local b = (age < 3 and recent) or (age < 10 and prior) or nil
      if b then
        b.sold = b.sold + sold
        b.obs = b.obs + dr.obs
        b.q = b.q + stock
        b.qn = b.qn + 1
      end
    end
  end

  if not priceNow or priceDay < today - 3 then return nil end -- objet absent récemment

  local s = { id = id, listPrice = priceNow, days = days, obsHours = w.obs / 3600 }
  -- Prix réel de vente : valeur des enchères disparues / unités. Une enchère très chère annulée (ou
  -- achetée) le fausse : hors de 0,4 à 1,5 fois le prix affiché, on garde le prix affiché.
  if w.sold >= Analysis.MIN_SOLD_FOR_REAL then
    local rp = w.val / w.sold
    if rp >= 0.4 * priceNow and rp <= 1.5 * priceNow then s.realPrice = rp end
  end
  s.price = s.realPrice or priceNow
  -- Prix affiché sans ventes pour le confirmer : on ne compte pas plus que le plus haut prix vu vendu
  -- (scans, historique, tes courriers). Voir Trust.lua.
  if ns.Trust then
    s.ev = ns.Trust.Evidence(db, id, today)
    if not s.realPrice and s.ev.maxSold and s.price > s.ev.maxSold then
      s.listedPrice, s.price, s.capped = s.price, s.ev.maxSold, true
    end
  end
  s.perDay = w.obs > 0 and (w.sold + 0.5 * w.amb) / w.obs * 86400 or nil
  -- annulations et relistes écartées des ventes (Scan.Diff), pour le rapport et l'infobulle
  s.relistPerDay = w.obs > 0 and w.can > 0 and w.can / w.obs * 86400 or nil
  s.stock = recent.qn > 0 and recent.q / recent.qn or nil

  local b = robustSlope(pts, 2)
  s.trend = b and (math.exp(b) - 1) or nil          -- variation de prix par jour (0.04 = +4 %/j)

  -- Pas encore 3 jours de données AHLedger : on s'appuie sur l'historique d'Auctionator
  if not s.trend and ns.Bridge then
    local ah = ns.Bridge.History(id, 14)
    if ah and #ah >= 2 then
      local apts, rq, rn, pq, pn = {}, 0, 0, 0, 0
      for _, e in ipairs(ah) do
        if e[1] > -Analysis.TREND_DAYS then apts[#apts + 1] = { e[1], math.log(e[2]) } end
        if e[3] then
          if e[1] > -3 then rq, rn = rq + e[3], rn + 1 elseif e[1] > -10 then pq, pn = pq + e[3], pn + 1 end
        end
      end
      -- au moins 4 jours d'Auctionator sur 3 jours d'écart, pente robuste : ses prix du jour sont des
      -- minimums (une seule enchère bradée suffit), 2 ou 3 points donnaient +190 à +13 000 %/j
      local ab = #apts >= 4 and robustSlope(apts, 3) or nil
      if ab then s.trend = math.exp(ab) - 1; s.trendSrc = "Auctionator" end
      if not s.stockChg and rn > 0 and pn > 0 and pq > 0 then s.stockChg = (rq / rn) / (pq / pn) - 1 end
    end
  end

  if recent.obs > 0 and prior.obs > 0 and prior.sold > 0 then
    s.demandChg = (recent.sold / recent.obs) / (prior.sold / prior.obs) - 1
  end
  if recent.qn > 0 and prior.qn > 0 and prior.q > 0 then
    s.stockChg = (recent.q / recent.qn) / (prior.q / prior.qn) - 1
  end

  s.minNow = db.lastMin and db.lastMin[id] -- prix d'achat le plus bas à l'unité (dernier scan)
  s.trend24, s.change24, s.n24, s.span24 = Analysis.ShortTrend(db, id, time())
  -- prix d'achat actuel comparé au prix moyen des 7 derniers jours
  local sum, n = 0, 0
  for d = today - 6, today do
    local r = History.parse(h[d])
    if r and r.pN > 0 then sum, n = sum + r.pSum / r.pN, n + 1 end
  end
  s.avg7 = n > 0 and sum / n or nil
  if s.minNow and s.avg7 and s.avg7 > 0 then s.vsAvg = s.minNow / s.avg7 - 1 end
  local meta = AHLedgerDB.items[id]
  if not meta or not meta.s then ns.rememberItem(id); meta = AHLedgerDB.items[id] end
  s.vendorSell = meta and meta.s
  s.name = meta and meta.n
  s.quality = meta and meta.q
  s.class = meta and meta.c

  -- Taux d'écoulement : part des enchères qui partent avant d'expirer (avec un a priori de 2 sur 3,
  -- pour ne pas conclure sur 2 ou 3 enchères)
  if w.sold + w.exp > 0 then s.sellThrough = (w.sold + 2) / (w.sold + w.exp + 3) end
  -- Ce que rapporte vraiment une unité mise en vente : prix - commission - dépôts perdus sur les
  -- mises en vente qui expirent (en moyenne (1 - écoulement) / écoulement remises en vente)
  s.net = s.price * (1 - Analysis.AH_CUT)
  s.deposit = (s.vendorSell or 0) * Analysis.DEPOSIT_RATE
  local st = math.max(s.sellThrough or 0.67, 0.1)
  s.netExp = s.net - s.deposit * (1 - st) / st
  s.gpd = s.perDay and math.max(s.netExp, 0) * s.perDay or 0   -- or que ce marché rapporte par jour

  -- Concurrence (dernier scan)
  local book = db.book and ns.Scan.UnpackBook(db.book[id])
  if book then s.sellers, s.topShare = book.sellers, book.top end
  if s.stock and s.perDay and s.perDay > 0 then s.stockDays = s.stock / s.perDay end

  -- Signaux
  local sig, mult = {}, 1
  if s.trend and s.trend >= 0.03 then sig[#sig + 1] = "hausse" end
  if s.trend and s.trend <= -0.03 then sig[#sig + 1] = "baisse" end
  if s.stockChg and s.stockChg <= -0.3 and (not s.demandChg or s.demandChg > -0.2) then
    sig[#sig + 1] = "pénurie"; mult = mult * 1.2
  end
  if s.demandChg and s.demandChg >= 0.3 then sig[#sig + 1] = "demande+"; mult = mult * 1.1 end
  if s.stockChg and s.stockChg >= 0.5 then sig[#sig + 1] = "afflux"; mult = mult * 0.8 end
  if s.vendorSell and s.vendorSell > 0 and s.net < s.vendorSell then sig[#sig + 1] = "PNJ>HV" end
  if s.stockDays and s.stockDays > Analysis.HEAVY_STOCK_DAYS then
    sig[#sig + 1] = "stock lourd"; mult = mult * 0.75             -- ta pile attendra derrière les autres
  end
  if s.topShare and s.sellers and s.sellers >= 2 and s.topShare >= 0.6 then
    sig[#sig + 1] = "dominé"; mult = mult * 0.85                  -- un gros vendeur fait la loi : guerre de prix
  end
  if s.sellThrough and s.sellThrough < 0.4 then sig[#sig + 1] = "invendus" end
  if ns.Prof and ns.Prof.Tag(id) then sig[#sig + 1] = ns.Prof.Tag(id) end
  if s.obsHours < 6 then sig[#sig + 1] = "peu de données" end
  s.signals = sig

  -- Confiance dans le volume : une seule vente vue en 5 h ne vaut pas « 5 vendus/j ».
  -- Les ventes observées (ambiguës pour moitié) pèsent v / (v + 3) : 1 vente → 25 %, 12 → 80 %.
  local seen = w.sold + 0.5 * w.amb
  s.confidence = seen / (seen + 3)
  if ns.Trust then s.trust, s.trustWhy = ns.Trust.Check(s, s.price) end
  if s.trust == "bad" then sig[#sig + 1] = "prix non tenu"; mult = mult * 0.5 end
  -- Score "à farmer" : or/jour, boosté si le prix monte ou si le stock s'assèche
  s.score = s.gpd * clamp(1 + 3 * (s.trend or 0), 0.5, 1.5) * mult * s.confidence
  return s
end

-- Cache recalculé après chaque scan
local cache, cacheVersion, cacheRealm
function Analysis.All()
  local key = ns.realmKey()
  if cache and cacheVersion == ns.dataVersion and cacheRealm == key then return cache end
  local db = ns.realmDB()
  local today = History.today()
  if ns.Rebound then ns.Rebound.Update(db, today) end
  local list, byId = {}, {}
  for id in pairs(db.hist or {}) do
    local s = Analysis.ItemStats(db, id, today)
    if s then
      list[#list + 1] = s
      byId[id] = s
    end
  end
  cache = { list = list, byId = byId }
  cacheVersion, cacheRealm = ns.dataVersion, key
  return cache
end

function Analysis.Get(id)
  return Analysis.All().byId[id]
end

-- Achat chez un PNJ -> revente HV
-- Un objet vendu par un PNJ a un plafond naturel : tout acheteur peut aller le chercher au marchand.
-- On ne retient donc que ce qui a vraiment été vu partir à ce prix, et on reste prudent sur le volume.
Analysis.VENDOR_SHARE = 0.25     -- part du marché qu'on peut espérer prendre face aux autres vendeurs
Analysis.VENDOR_MARKUP_WARN = 5  -- revente à plus de 5× le prix PNJ : peu d'acheteurs, à tester petit
Analysis.VENDOR_MIN_DAYS = 3     -- jours de données mini avant de faire confiance au volume

-- Ventes réelles (courriers d'HV) par objet, pour confirmer ou démentir une estimation
function Analysis.RealSales()
  local by = {}
  if not (ns.Ledger and ns.Ledger.Summary) then return by end
  for _, r in ipairs((ns.Ledger.Summary())) do if r.id then by[r.id] = r end end
  return by
end

function Analysis.VendorFlip(id, s, v, real)
  if not (s and v and v.p and v.p > 0) then return nil end  -- relevé PNJ absent ou arrondi à 0c (ancienne version)
  local margin = s.netExp - v.p                             -- commission et dépôts perdus déduits
  if margin < 1 then return nil end
  local cap = (v.lim and v.lim > 0) and v.lim or math.huge
  local vol = math.min((s.perDay or 0) * Analysis.VENDOR_SHARE, cap)
  local e = { id = id, s = s, buy = v.p, margin = margin, roi = margin / v.p, markup = s.price / v.p,
              perDay = s.perDay, vol = vol, npc = v.npc, zone = v.zone, lim = v.lim }
  local why = {}
  if not s.realPrice then why[#why + 1] = "aucune vente vue à ce prix" end
  if (s.days or 0) < Analysis.VENDOR_MIN_DAYS then why[#why + 1] = ("%d j de données"):format(s.days or 0) end
  if s.sellThrough and s.sellThrough < 0.5 then why[#why + 1] = ("écoulement %.0f%%"):format(s.sellThrough * 100) end
  if e.markup >= Analysis.VENDOR_MARKUP_WARN then
    why[#why + 1] = ("%.0f× le prix PNJ, acheteurs rares ?"):format(e.markup)
  end
  local r = real and real[id]
  if r and r.sold > 0 then
    e.realSold, e.realAvg, e.realExpired = r.sold, r.avgSale, r.expired
    -- tes propres ventes tranchent : confirmé si au moins 2/3 de tes mises en vente sont parties
    if r.sold >= 2 * r.expired then why = {} else why[#why + 1] = ("%d expirés chez toi"):format(r.expired) end
  end
  e.reliable = #why == 0
  e.why = table.concat(why, ", ")
  if not e.reliable then e.testQty = math.max(1, math.min(20, math.ceil(vol))) end
  e.gpd = margin * vol * (s.confidence or 1) * (e.reliable and 1 or 0.5)
  return e
end

function Analysis.VendorFlips()
  local db, out = ns.realmDB(), {}
  local all = Analysis.All().byId
  local real = Analysis.RealSales()
  for id, v in pairs(db.vendor or {}) do
    local e = Analysis.VendorFlip(id, all[id], v, real)
    if e then out[#out + 1] = e end
  end
  return out
end

-- Sessions de farm regroupées par zone, valorisées aux prix actuels
function Analysis.FarmZones()
  local db, zones = ns.realmDB(), {}
  local all = Analysis.All().byId
  for _, f in ipairs(db.farm) do
    local z = zones[f.zone]
    if not z then z = { zone = f.zone, secs = 0, money = 0, loot = {}, sessions = 0 }; zones[f.zone] = z end
    z.secs = z.secs + math.max((f.stop or f.start) - f.start, 60)
    z.money = z.money + math.max(f.money or 0, 0)
    z.sessions = z.sessions + 1
    for id, q in pairs(f.loot) do z.loot[id] = (z.loot[id] or 0) + q end
  end
  local out = {}
  for _, z in pairs(zones) do
    local hours = z.secs / 3600
    local value, best, bestVal = 0, nil, 0
    for id, q in pairs(z.loot) do
      local s = all[id]
      local unit = s and s.net or (AHLedgerDB.items[id] and AHLedgerDB.items[id].s) or 0
      -- au-delà de ce que le marché absorbe en une journée, on valorise au prix PNJ
      local perHourQty = q / hours
      local liquid = s and s.perDay and math.min(perHourQty, s.perDay / 4) or perHourQty
      local vsell = AHLedgerDB.items[id] and AHLedgerDB.items[id].s or 0
      local v = (liquid * unit + (perHourQty - liquid) * vsell)
      value = value + v
      if v > bestVal then best, bestVal = id, v end
    end
    out[#out + 1] = { zone = z.zone, hours = hours, sessions = z.sessions, itemsPerHour = value,
                      moneyPerHour = z.money / hours, total = value + z.money / hours, best = best }
  end
  return out
end

-- Parcourt le carnet d'ordres du moins cher au plus cher, jusqu'à cap unités. Pour chaque quantité :
-- fn(quantité, coût, prix max payé, prochaine enchère qui restera en vente après nos achats)
-- (et sans dépasser maxCost d'achat au total, s'il est donné)
local function walkBook(levels, cap, fn, maxCost)
  local qty, cost = 0, 0
  for k, l in ipairs(levels) do
    local take = math.min(l[2], cap - qty)
    if maxCost and l[1] > 0 then take = math.min(take, math.floor((maxCost - cost) / l[1])) end
    if take <= 0 then break end
    qty, cost = qty + take, cost + take * l[1]
    fn(qty, cost, l[1], take < l[2] and l[1] or (levels[k + 1] and levels[k + 1][1]))
  end
end

-- Flip HV : enchères sous le prix de vente, à racheter puis remettre en vente. Deux cas :
-- * kind = "now" (tout de suite) : un vendeur brade, mais il reste en vente des enchères au prix
--   habituel. Acheter plus de niveaux remonte le prix auquel on pourra revendre (juste sous la prochaine
--   enchère restante), mais coûte plus cher : on garde la quantité qui maximise le bénéfice.
-- * kind = "stock" (à stocker) : tout le marché est bas, la revente possible tout de suite ne paie pas.
--   On achète pour revendre au prix habituel d'avant le creux quand il remonte. Bénéfice espéré =
--   chance de remonter × revente au prix habituel + chance de ne pas remonter × revente au prix d'aujourd'hui,
--   d'après les creux passés de l'objet (ns.Rebound). Tant qu'ils sont inconnus : une chance sur deux,
--   et on n'achète qu'une demi-journée de ventes (20 unités et 20 po au plus), pour apprendre.
-- Revendre tout de suite passe avant stocker quand les deux sont possibles.
function Analysis.FlipFor(s, book, odds)
  if not (s and book and s.realPrice and s.perDay and s.perDay >= 1) then return nil end
  local target = s.realPrice
  if s.avg7 and s.avg7 < target then target = s.avg7 end -- prudence : on ne revend pas au-dessus du prix affiché moyen
  local st = math.max(s.sellThrough or 0.67, 0.1)
  local depLoss = s.deposit * (1 - st) / st
  local function net(p) return p * (1 - Analysis.AH_CUT) - depLoss end
  local levels = book.levels

  local now
  walkBook(levels, math.floor(s.perDay * Analysis.FLIP_HOLD_DAYS), function(qty, cost, maxBuy, nextP)
    local resale = math.min(target, nextP and (nextP - 1) or target)
    local profit = net(resale) * qty - cost
    if profit > 0 and (not now or profit > now.profit) then
      now = { kind = "now", id = s.id, s = s, qty = qty, cost = cost, maxBuy = maxBuy, resale = resale,
              profit = profit, roi = profit / math.max(cost, 1), days = qty / s.perDay, name = s.name }
    end
  end)
  if now and now.roi >= Analysis.FLIP_MIN_ROI and now.profit >= Analysis.FLIP_MIN_PROFIT then return now end

  if odds == nil and ns.Rebound then odds = ns.Rebound.Now(ns.realmDB(), s.id) end
  if not (odds and odds.ref) then return nil end
  -- un marché qui baisse régulièrement n'est pas un creux, sauf si l'objet a prouvé qu'il remonte
  -- (tendance des 7 derniers jours, ou pente depuis le début du creux : la plus basse des deux)
  local trend = s.trend
  if odds.dipTrend and (not trend or odds.dipTrend < trend) then trend = odds.dipTrend end
  if trend and trend <= -0.03 and not (odds.known and odds.rate >= 0.6) then return nil end
  local storeAt = odds.ref * (1 - ns.Rebound.RECOVER)
  -- rebonds inconnus : petit achat pour apprendre, plafonné en unités et en or
  local cap = odds.known and math.floor(s.perDay * Analysis.FLIP_HOLD_DAYS)
    or math.min(Analysis.FLIP_TEST_MAX_QTY, math.max(1, math.floor(s.perDay * Analysis.FLIP_TEST_DAYS)))
  local maxCost = not odds.known and Analysis.FLIP_TEST_MAX_COST or nil
  local stock
  walkBook(levels, cap, function(qty, cost, maxBuy, nextP)
    local nowAt = math.min(target, nextP and (nextP - 1) or target)
    if storeAt < nowAt * (1 + Analysis.FLIP_STORE_GAP) then return end
    local ifUp, ifDown = net(storeAt) * qty - cost, net(nowAt) * qty - cost
    local profit = odds.rate * ifUp + (1 - odds.rate) * ifDown
    if profit > 0 and (not stock or profit > stock.profit) then
      stock = { kind = "stock", id = s.id, s = s, qty = qty, cost = cost, maxBuy = maxBuy, resale = storeAt,
                resaleNow = nowAt, ifUp = ifUp, ifDown = ifDown, profit = profit, roi = profit / math.max(cost, 1),
                rate = odds.rate, wait = odds.wait, slow = odds.slow, events = odds.n, recovered = odds.ok, known = odds.known,
                weekday = odds.weekday, ref = odds.ref, name = s.name,
                days = (odds.wait or 0) + qty / s.perDay }
    end
  end, maxCost)
  if stock and stock.roi >= Analysis.FLIP_STORE_MIN_ROI and stock.profit >= Analysis.FLIP_MIN_PROFIT then return stock end
end

-- « Revendre tout de suite » / « Stocker ~3 j (70 %) » / « Stocker ? (à tester) »
function Analysis.FlipWhen(f)
  if f.kind ~= "stock" then return "tout de suite" end
  if not f.known then return "stocker ? (à tester)" end
  return ("stocker ~%s j (%.0f%%)"):format(f.wait and tostring(f.wait) or "?", f.rate * 100)
end

function Analysis.Flips()
  local db, out = ns.realmDB(), {}
  if not db.book then return out end
  local mine = ns.Ledger and ns.Ledger.Holds and ns.Ledger.Holds() or {}
  for id, s in pairs(Analysis.All().byId) do
    local f = Analysis.FlipFor(s, ns.Scan.UnpackBook(db.book[id]))
    if f then
      f.mine = mine[id]
      out[#out + 1] = f
    end
  end
  return out
end

-- Coût d'achat d'un composant : le moins cher entre le PNJ (si connu) et l'HV (enchère la moins chère,
-- sinon prix de marché)
function Analysis.ReagentCost(id)
  local db = ns.realmDB()
  local v = db.vendor and db.vendor[id]
  local s = Analysis.Get(id)
  local ah = s and (s.minNow or s.price)
  if v and (not ah or v.p <= ah) then return v.p, "PNJ" end
  if ah then return ah, "HV" end
end

-- Artisanat : recettes relevées à l'ouverture de tes fenêtres de métier
Analysis.CRAFT_VENDOR_PER_DAY = 20 -- fabrications par jour qu'on compte pour une recette revendue au PNJ
function Analysis.Crafts()
  local out = {}
  for prof, list in pairs(ns.Prof and ns.Prof.Recipes() or {}) do
    for outId, r in pairs(list) do
      local s = Analysis.Get(outId)
      local cost, missing, fromAH = 0, 0, 0
      for rid, n in pairs(r.r) do
        local c, src = Analysis.ReagentCost(rid)
        if c then cost = cost + c * n; if src == "HV" then fromAH = fromAH + 1 end else missing = missing + 1 end
      end
      local made = r.m or 1
      local value = s and math.max(s.netExp, 0) * made
      local vsell = (AHLedgerDB.items[outId] and AHLedgerDB.items[outId].s or 0) * made
      local e = { id = outId, s = s, prof = prof, name = r.n, made = made, cost = missing == 0 and cost or nil, missing = missing,
                  value = value, vendorValue = vsell, perDay = s and s.perDay, diff = r.d }
      if e.cost then
        local best = math.max(value or 0, vsell)
        e.profit = best - e.cost
        e.roi = e.profit / math.max(e.cost, 1)
        e.sellTo = (value or 0) >= vsell and "HV" or "PNJ"
        -- ce que la recette peut te rapporter par jour : à l'HV, ta part des ventes du marché
        -- (une recette rentable que personne n'achète ne rapporte rien) ; au PNJ, une quantité fixe
        e.vol = e.sellTo == "HV" and (s and s.perDay or 0) * Analysis.VENDOR_SHARE / made or Analysis.CRAFT_VENDOR_PER_DAY
        e.daily = math.max(e.profit, 0) * e.vol
      end
      out[#out + 1] = e
    end
  end
  return out
end

-- Fabriquer plutôt que vendre brut ? Pour un composant, ce que rapporte chaque unité transformée :
-- (valeur de l'objet fabriqué − autres composants) / quantité de ce composant, comparé à sa vente brute
-- (le mieux entre l'HV nette et le PNJ). Recettes connues, plus celles que tu peux apprendre à ton niveau.
Analysis.CRAFT_UP_MIN_GAIN = 0.10      -- fabriquer doit rapporter au moins 10 % de plus par composant…
Analysis.CRAFT_UP_MIN_PER_CRAFT = 20   -- …et au moins 20c de plus par fabrication
local CRAFT_UP_SLOW = 0.5              -- comme Bags.SLOW_PER_DAY : l'HV risque de ne rien vendre

local function rawValue(id)
  local s = Analysis.Get(id)
  local meta = AHLedgerDB.items[id]
  local vsell = meta and meta.s or 0
  local ah = s and math.max(s.netExp or 0, 0) or 0
  if ah > vsell then return ah, "HV" end
  return vsell, vsell > 0 and "PNJ" or nil
end

local function craftUpEntry(id, raw, rec, learned, learnCost)
  local q = rec.r[id]
  local others = 0
  for rid, n in pairs(rec.r) do
    if rid ~= id then
      local c = Analysis.ReagentCost(rid)
      if not c then return nil end
      others = others + c * n
    end
  end
  local made = rec.made or 1
  local so = Analysis.Get(rec.out)
  local meta = AHLedgerDB.items[rec.out]
  local vend = (meta and meta.s or 0) * made
  local ah = so and math.max(so.netExp or 0, 0) * made or 0
  local sellTo, value = "HV", ah
  if vend >= ah then sellTo, value = "PNJ", vend end
  if value <= 0 then return nil end
  local perUnit = (value - others) / q
  local gain = perUnit - raw
  local e = { id = id, out = rec.out, name = rec.name or (meta and meta.n), prof = rec.prof, q = q, made = made,
              others = others, value = value, perUnit = perUnit, raw = raw, gain = gain,
              gainPct = raw > 0 and gain / raw or nil, sellTo = sellTo, learned = learned, learnCost = learnCost }
  if sellTo == "HV" then
    e.unsure = so.realPrice == nil
    e.slow = so.perDay == nil or so.perDay < CRAFT_UP_SLOW
    -- composants que l'HV absorbe par jour sous forme d'objet fabriqué (ta part du marché)
    e.unitsPerDay = (so.perDay or 0) * Analysis.VENDOR_SHARE / made * q
  end
  return e
end

-- Meilleure transformation d'un composant, ou nil si vendre brut est aussi bien.
-- 2e retour : la meilleure trouvée même si elle ne vaut pas la peine (pour l'affichage détaillé)
function Analysis.CraftUp(id)
  if not (ns.Prof and id) then return nil end
  local raw = rawValue(id)
  local best, seen = nil, {}
  local function consider(e)
    if e and (not best or e.perUnit > best.perUnit) then best = e end
  end
  for prof, list in pairs(ns.Prof.Recipes() or {}) do
    for outId, r in pairs(list) do
      if r.r and r.r[id] then
        seen[outId] = true
        consider(craftUpEntry(id, raw, { out = outId, prof = prof, r = r.r, made = r.m, name = r.n }, true))
      end
    end
  end
  -- recettes non apprises (base de recettes externe) accessibles à ton niveau
  if ns.RecipeDB then
    for prof, rank in pairs(ns.Prof.Char().skills or {}) do
      for _, rec in ipairs(ns.RecipeDB.All(prof)) do
        if rec.r[id] and not seen[rec.out] and not rec.learned and rec.source and rec.source.cost
          and rec.levels and rec.levels[1] and rank >= rec.levels[1] then
          consider(craftUpEntry(id, raw, rec, false, rec.source.cost))
        end
      end
    end
  end
  if not best then return nil end
  local worth = best.gain * best.q >= Analysis.CRAFT_UP_MIN_PER_CRAFT
    and (not best.gainPct or best.gainPct >= Analysis.CRAFT_UP_MIN_GAIN)
  return worth and best or nil, best
end
