-- AHLedger - Analyse : prix, volume, tendances, signaux d'anticipation
local _, ns = ...

local Analysis = {}
ns.Analysis = Analysis

Analysis.AH_CUT = 0.05          -- commission HV (Classic : 5 %, à vérifier sur Forever)
Analysis.TREND_DAYS = 7         -- fenêtre de la régression de prix
Analysis.MIN_SOLD_FOR_REAL = 5  -- unités vendues mini pour faire confiance au prix réel de vente
Analysis.DEPOSIT_RATE = 0.15    -- dépôt d'une mise en vente de 12 h, en part du prix PNJ (à vérifier sur Forever)
Analysis.HEAVY_STOCK_DAYS = 7   -- au-delà de 7 jours de ventes déjà en rayon, le marché est saturé
-- Flip HV : acheter les enchères trop basses et les remettre au prix du marché
Analysis.FLIP_HOLD_DAYS = 2     -- on n'achète pas plus que ce qui se revend en 2 jours
Analysis.FLIP_MIN_ROI = 0.15    -- marge mini de 15 % après commission et dépôts
Analysis.FLIP_MIN_PROFIT = 2000 -- 20 pa mini par opération
-- Flip à stocker : le marché entier est bas, on achète et on attend que le prix remonte
Analysis.FLIP_STORE_MIN_ROI = 0.25  -- l'or reste immobilisé et le prix peut ne pas remonter : marge mini plus haute
Analysis.FLIP_STORE_GAP = 0.10      -- le prix habituel doit dépasser d'au moins 10 % la revente possible tout de suite
Analysis.FLIP_TEST_DAYS = 0.5       -- rebonds encore inconnus : on n'achète qu'une demi-journée de ventes

local History = ns.History

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- LE prix net d'une unité vendue à post /u (seule formule de l'addon) : commission, et dépôts perdus
-- sur les mises en vente qui expirent (en moyenne (1 − p) / p remises en vente par vente).
-- p = chance qu'une mise en vente parte (défaut : écoulement mesuré, sinon 2 sur 3) ; vendor = rachat
-- PNJ /u, qui fixe le dépôt. Retourne le net /u et le dépôt d'une mise en vente /u.
Analysis.DEFAULT_SELL_P = 0.67
function Analysis.NetAt(post, s, vendor, p)
  if not post then return nil end
  local v = vendor or (s and s.vendorSell) or 0
  local deposit = math.max(s and s.deposit or 0, v * Analysis.DEPOSIT_RATE)
  if not p then p = s and s.stReliable and s.sellThrough or Analysis.DEFAULT_SELL_P end
  p = math.max(p, 0.1)
  return post * (1 - Analysis.AH_CUT) - deposit * (1 - p) / p, deposit
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

-- Tendance courte : régression sur les scans des dernières 24 h (%/jour), et variation sur la période.
-- Il faut au moins 4 scans sur 6 h : avec 2 ou 3 médianes, une seule pile postée ou achetée donnait
-- « +12 305 695 % sur 24 h ». Au-delà de ±100 %/j ce n'est pas une tendance mais du bruit : nil.
Analysis.SHORT_MIN_SCANS = 4
Analysis.SHORT_MIN_HOURS = 6
function Analysis.ShortTrend(db, id, now)
  local pts, first, last = {}, nil, nil
  for _, p in ipairs(History.Recent(db, id)) do
    if p[1] >= now - 86400 then
      pts[#pts + 1] = { (p[1] - now) / 86400, math.log(p[2]) }
      first = first or p
      last = p
    end
  end
  if #pts < Analysis.SHORT_MIN_SCANS or (last[1] - first[1]) < Analysis.SHORT_MIN_HOURS * 3600 then return nil end
  local b = robustSlope(pts, 0)
  if not b then return nil end
  local v = math.exp(b) - 1
  if math.abs(v) > 1 then return nil end
  return v, last[2] / first[2] - 1, #pts, (last[1] - first[1]) / 3600
end

-- Jours de prix nécessaires pour une tendance sur 7 jours (sinon pas de tendance, plutôt qu'un chiffre faux)
Analysis.TREND_MIN_DAYS = 4
Analysis.TREND_MIN_DAYS_AUCTIONATOR = 5
-- Heures de scans au nouveau format (0.9) avant de croire au taux d'écoulement
Analysis.ST_MIN_HOURS = 12

-- Statistiques d'un objet sur les 14 derniers jours
function Analysis.ItemStats(db, id, today)
  local h = db.hist and db.hist[id]
  if not h then return nil end
  today = today or History.today()

  local pts = {}
  local w = { sold = 0, amb = 0, val = 0, obs = 0, exp = 0, can = 0, soldDays = 0 } -- 7 derniers jours
  local w9 = { sold = 0, amb = 0, val = 0, obs = 0, exp = 0, can = 0, soldDays = 0 } -- dont jours 100 % 0.9
  local recent = { sold = 0, obs = 0, q = 0, qn = 0 }          -- 0-2 jours
  local prior = { sold = 0, obs = 0, q = 0, qn = 0 }           -- 3-9 jours
  local priceNow, priceDay, days = nil, nil, 0
  local mins = {}            -- prix le plus bas moyen de chaque jour passé (scans 0.9 et plus)

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
        if r.v9 and r.mSum and r.mSum > 0 and age >= 1 then mins[#mins + 1] = r.mSum / r.pN end
      end
      -- Avant la 0.9, une enchère annulée ou une pile achetée en partie comptait comme vendue :
      -- ces jours-là, la moitié seulement des « ventes » est tenue pour sûre, le reste incertain.
      local k = (r and not r.v9) and 0.5 or 1
      local sure = r and r.sold * k or 0
      local amb = r and (r.amb + r.sold * (1 - k)) or 0
      local sold = sure + 0.5 * amb
      local stock = (r and r.qSum or 0) / math.max(dr.scans, 1)
      if age < 7 then
        w.sold = w.sold + sure
        w.amb = w.amb + amb
        w.val = w.val + (r and r.soldVal * k or 0)
        w.exp = w.exp + (r and r.exp or 0)
        w.can = w.can + (r and r.can or 0)
        w.obs = w.obs + dr.obs
        if sure >= 1 then w.soldDays = w.soldDays + 1 end
        -- jour observé de bout en bout avec la 0.9 : ventes, expirations et retraits bien séparés
        -- (un jour commencé avant la 0.9 garde la moitié de ses anciennes « ventes » : on l'écarte)
        if dr.obs > 0 and (dr.o9 or 0) >= dr.obs then
          w9.obs = w9.obs + dr.obs
          if r then
            w9.sold, w9.amb, w9.val = w9.sold + r.sold, w9.amb + r.amb, w9.val + r.soldVal
            w9.exp, w9.can = w9.exp + r.exp, w9.can + r.can
            if r.sold >= 1 then w9.soldDays = w9.soldDays + 1 end
          end
        end
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

  -- 12 h de scans entièrement 0.9 : on ne compte plus que ceux-là. Avant, une enchère retirée ou une
  -- pile achetée en partie comptait comme vendue (Runecloth « 2 000 ventes/j ») ; même à moitié,
  -- ces anciens jours gonfleraient encore le débit.
  local measured = w9.obs >= Analysis.ST_MIN_HOURS * 3600
  if measured then w = w9 end
  local s = { id = id, listPrice = priceNow, days = days, obsHours = w.obs / 3600, obs9Hours = w9.obs / 3600,
              measured = measured, dailyMins = mins }
  -- Prix réel de vente : valeur des enchères sûrement achetées / unités. Hors de 0,4 à 1,5 fois le
  -- prix affiché (une grosse enchère mal classée), on garde le prix affiché.
  if w.sold >= Analysis.MIN_SOLD_FOR_REAL then
    local rp = w.val / w.sold
    if rp >= 0.4 * priceNow and rp <= 1.5 * priceNow then s.realPrice = rp end
  end
  s.price = s.realPrice or priceNow
  -- Volume. perDay : ventes sûres + moitié des disparitions incertaines (classement du marché).
  -- surePerDay : ventes sûres seulement (décisions). salesDays : jours où une vente sûre a été vue.
  s.perDay = w.obs > 0 and (w.sold + 0.5 * w.amb) / w.obs * 86400 or nil
  s.surePerDay = w.obs > 0 and w.sold / w.obs * 86400 or nil
  s.soldSure, s.salesDays = w.sold, w.soldDays
  s.canPerDay = w.obs > 0 and w.can > 0 and w.can / w.obs * 86400 or nil
  s.stock = recent.qn > 0 and recent.q / recent.qn or nil

  local b = #pts >= Analysis.TREND_MIN_DAYS and robustSlope(pts, Analysis.TREND_MIN_DAYS - 1) or nil
  s.trend = b and (math.exp(b) - 1) or nil          -- variation de prix par jour (0.04 = +4 %/j)

  -- Pas assez de jours AHLedger : historique d'Auctionator (prix mini du jour)
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
      -- ses prix du jour sont des minimums (une seule enchère bradée suffit) : il en faut plus
      local need = Analysis.TREND_MIN_DAYS_AUCTIONATOR
      local ab = #apts >= need and robustSlope(apts, need - 1) or nil
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

  -- Taux d'écoulement : part des enchères qui partent avant d'expirer, les disparitions incertaines
  -- pour moitié, a priori d'une vente et d'une expiration. Avant la 0.9 les expirations n'étaient
  -- presque jamais vues (« 99 % » partout) : stReliable dit si on peut s'y fier.
  local gone = w.sold + 0.5 * w.amb
  if gone + w.exp > 0 then s.sellThrough = (gone + 1) / (gone + w.exp + 2) end
  s.stReliable = measured and (gone + w.exp) >= 5
  -- Ce que rapporte vraiment une unité mise en vente : prix - commission - dépôts perdus sur les
  -- mises en vente qui expirent (en moyenne (1 - écoulement) / écoulement remises en vente)
  s.net = s.price * (1 - Analysis.AH_CUT)
  s.deposit = (s.vendorSell or 0) * Analysis.DEPOSIT_RATE
  s.netExp = Analysis.NetAt(s.price, s)
  s.gpd = s.surePerDay and math.max(s.netExp, 0) * s.surePerDay or 0  -- or par jour (ventes sûres)

  -- Concurrence (dernier scan)
  local book = db.book and ns.Scan.UnpackBook(db.book[id])
  if book then s.sellers, s.topShare = book.sellers, book.top end
  local rate = s.surePerDay and s.surePerDay > 0 and s.surePerDay or s.perDay
  if s.stock and rate and rate > 0 then s.stockDays = s.stock / rate end

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
  if s.stReliable and s.sellThrough < 0.4 then sig[#sig + 1] = "invendus" end
  if ns.Prof and ns.Prof.Tag(id) then sig[#sig + 1] = ns.Prof.Tag(id) end
  if s.obsHours < 12 then sig[#sig + 1] = "peu de données" end
  s.signals = sig

  -- Confiance dans le volume : une seule vente vue en 5 h ne vaut pas « 5 vendus/j ».
  -- Les ventes sûres pèsent v / (v + 3) : 1 vente → 25 %, 12 → 80 %.
  s.confidence = w.sold / (w.sold + 3)
  -- Score "à farmer" : or/jour des ventes sûres, boosté si le prix monte (tendance sur 4 jours mini)
  s.score = s.gpd * clamp(1 + 3 * (s.trend or 0), 0.5, 1.5) * mult * s.confidence
  return s
end

-- Prix le plus bas habituel : médiane des minimums quotidiens (scans AHLedger 0.9+ des jours passés,
-- sinon Auctionator, dont le prix du jour est déjà un minimum). nil sous 4 jours : on ne sait pas.
Analysis.USUAL_MIN_DAYS = 4
function Analysis.UsualMin(id, s)
  s = s or Analysis.Get(id)
  local vals, src = {}, nil
  if s and s.dailyMins and #s.dailyMins >= Analysis.USUAL_MIN_DAYS then
    for i, v in ipairs(s.dailyMins) do vals[i] = v end
    src = "scans"
  elseif ns.Bridge then
    for _, e in ipairs(ns.Bridge.History(id, 14) or {}) do
      if e[1] <= -1 and e[2] and e[2] > 0 then vals[#vals + 1] = e[2] end
    end
    src = "Auctionator"
  end
  if #vals < Analysis.USUAL_MIN_DAYS then return nil end
  table.sort(vals)
  local m = (#vals + 1) / 2
  local usual = (vals[math.floor(m)] + vals[math.ceil(m)]) / 2
  -- le minimum du jour d'Auctionator peut être une seule enchère bradée (ou une autre variante de
  -- l'objet) : s'il contredit de plus de 3× les ventes que les scans ont vraiment vues, on l'écarte
  if src == "Auctionator" and s and s.realPrice and (s.salesDays or 0) >= 2
    and (usual * Analysis.USUAL_MISMATCH < s.realPrice or usual > s.realPrice * Analysis.USUAL_MISMATCH) then
    return nil
  end
  return usual, src, #vals
end
Analysis.USUAL_MISMATCH = 3

-- Cache recalculé après chaque scan
local cache, cacheVersion, cacheRealm
local build -- calcul en cours, par morceaux (voir Analysis.Build)

function Analysis.Ready()
  return cache ~= nil and cacheVersion == ns.dataVersion and cacheRealm == ns.realmKey()
end

-- Avance le calcul ; stop() vrai = rendre la main (on reprendra là, à l'image suivante).
-- Sans stop, va jusqu'au bout. Renvoie vrai quand le cache est prêt.
function Analysis.Build(stop)
  if Analysis.Ready() then return true end
  local key, ver = ns.realmKey(), ns.dataVersion
  if not (build and build.ver == ver and build.key == key) then
    local db = ns.realmDB()
    local today = History.today()
    if ns.Rebound then ns.Rebound.Update(db, today) end
    local ids = {}
    for id in pairs(db.hist or {}) do ids[#ids + 1] = id end
    build = { ver = ns.dataVersion, key = key, db = db, today = today, ids = ids, i = 0, list = {}, byId = {} }
  end
  local b = build
  while b.i < #b.ids do
    b.i = b.i + 1
    local id = b.ids[b.i]
    local s = Analysis.ItemStats(b.db, id, b.today)
    if s then
      b.list[#b.list + 1] = s
      b.byId[id] = s
    end
    if stop and b.i < #b.ids and stop() then return false end
  end
  cache = { list = b.list, byId = b.byId }
  cacheVersion, cacheRealm = b.ver, b.key
  build = nil
  return true
end

function Analysis.All()
  if not Analysis.Ready() then Analysis.Build() end
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
  local vol = math.min((s.surePerDay or 0) * Analysis.VENDOR_SHARE, cap)
  local e = { id = id, s = s, buy = v.p, margin = margin, roi = margin / v.p, markup = s.price / v.p,
              perDay = s.surePerDay, vol = vol, npc = v.npc, zone = v.zone, lim = v.lim }
  local why = {}
  if not s.realPrice then why[#why + 1] = "aucune vente vue à ce prix" end
  if (s.days or 0) < Analysis.VENDOR_MIN_DAYS then why[#why + 1] = ("%d j de données"):format(s.days or 0) end
  if s.stReliable and s.sellThrough < 0.5 then why[#why + 1] = ("écoulement %.0f%%"):format(s.sellThrough * 100) end
  if (s.salesDays or 0) < 2 then why[#why + 1] = "ventes vues moins de 2 jours sur 7" end
  if e.markup >= Analysis.VENDOR_MARKUP_WARN then
    why[#why + 1] = ("%.0f× le prix PNJ, acheteurs rares ?"):format(e.markup)
  end
  local r = real and real[id]
  if r and r.sold > 0 then
    e.realSold, e.realAvg, e.realExpired = r.sold, r.avgSale, r.expired
    -- tes propres ventes tranchent : confirmé si au moins 2/3 de tes mises en vente sont parties
    if r.sold >= 2 * r.expired then why = {} else why[#why + 1] = ("%d expirés chez toi"):format(r.expired) end
  elseif r and r.expired >= 3 then
    why[#why + 1] = ("tes %d mises en vente ont expiré"):format(r.expired)
  end
  e.reliable = #why == 0
  e.why = table.concat(why, ", ")
  if not e.reliable then e.testQty = math.max(1, math.min(20, math.ceil(vol))) end
  e.gpd = margin * vol * (s.confidence or 1) * (e.reliable and 1 or 0.5)
  return e
end

-- Seulement les reventes confirmées (ventes vues à ce prix, plusieurs jours, ou tes propres ventes).
-- 2e retour : combien restent « à tester », pour l'aide de l'onglet.
function Analysis.VendorFlips()
  local db, out, untested = ns.realmDB(), {}, 0
  if Analysis.Stale() then return out, 0, true end
  local all = Analysis.All().byId
  local real = Analysis.RealSales()
  for id, v in pairs(db.vendor or {}) do
    local e = Analysis.VendorFlip(id, all[id], v, real)
    if e and e.reliable then out[#out + 1] = e elseif e then untested = untested + 1 end
  end
  return out, untested
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
      local unit = s and s.netExp or (AHLedgerDB.items[id] and AHLedgerDB.items[id].s) or 0
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
local function walkBook(levels, cap, fn)
  local qty, cost = 0, 0
  for k, l in ipairs(levels) do
    local take = math.min(l[2], cap - qty)
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
--   et on n'achète qu'une demi-journée de ventes, pour apprendre.
-- Revendre tout de suite passe avant stocker quand les deux sont possibles.
function Analysis.FlipFor(s, book, odds)
  local rate = s and s.surePerDay
  if not (s and book and s.realPrice and rate and rate >= 1 and (s.salesDays or 0) >= 2) then return nil end
  local target = s.realPrice
  if s.avg7 and s.avg7 < target then target = s.avg7 end -- prudence : on ne revend pas au-dessus du prix affiché moyen
  local function net(p) return (Analysis.NetAt(p, s)) end
  local levels = book.levels

  local now
  walkBook(levels, math.floor(rate * Analysis.FLIP_HOLD_DAYS), function(qty, cost, maxBuy, nextP)
    local resale = math.min(target, nextP and (nextP - 1) or target)
    local profit = net(resale) * qty - cost
    if profit > 0 and (not now or profit > now.profit) then
      now = { kind = "now", id = s.id, s = s, qty = qty, cost = cost, maxBuy = maxBuy, resale = resale,
              profit = profit, roi = profit / math.max(cost, 1), days = qty / rate, name = s.name }
    end
  end)
  if now and now.roi >= Analysis.FLIP_MIN_ROI and now.profit >= Analysis.FLIP_MIN_PROFIT then return now end

  if odds == nil and ns.Rebound then odds = ns.Rebound.Now(ns.realmDB(), s.id) end
  -- creux dont on ne sait pas encore s'ils remontent : pas de conseil (on apprend sans acheter)
  if not (odds and odds.ref and odds.known) then return nil end
  -- un marché qui baisse régulièrement n'est pas un creux, sauf si l'objet a prouvé qu'il remonte
  if s.trend and s.trend <= -0.03 and not (odds.known and odds.rate >= 0.6) then return nil end
  local storeAt = odds.ref * (1 - ns.Rebound.RECOVER)
  local cap = math.floor(rate * Analysis.FLIP_HOLD_DAYS)
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
                days = (odds.wait or 0) + qty / rate }
    end
  end)
  if stock and stock.roi >= Analysis.FLIP_STORE_MIN_ROI and stock.profit >= Analysis.FLIP_MIN_PROFIT then return stock end
end

-- « Revendre tout de suite » / « Stocker ~3 j (70 %) » / « Stocker ? (à tester) »
function Analysis.FlipWhen(f)
  if f.kind ~= "stock" then return "tout de suite" end
  if not f.known then return "stocker ? (à tester)" end
  return ("stocker ~%s j (%.0f%%)"):format(f.wait and tostring(f.wait) or "?", f.rate * 100)
end

-- Scan périmé (aucun, ou plus vieux que Decide.STALE_HOURS) : aucun achat conseillé nulle part
-- (Conseils, onglets Flip HV et Achat PNJ, infobulle, rapport, Mes flips), car les enchères
-- bradées qu'il montre sont sûrement parties. 2e retour : l'âge du scan en heures (nil si aucun).
function Analysis.Stale()
  local t = ns.realmDB().lastScanTime
  local age = t and (time() - t) / 3600 or nil
  return not age or age > ns.Decide.STALE_HOURS, age
end

function Analysis.Flips()
  local db, out = ns.realmDB(), {}
  if not db.book or Analysis.Stale() then return out end
  local mine = ns.Tracker and ns.Tracker.Holds() or {}
  for id, s in pairs(Analysis.All().byId) do
    local f = Analysis.FlipFor(s, ns.Scan.UnpackBook(db.book[id]))
    if f then
      f.mine = mine[id]
      out[#out + 1] = f
    end
  end
  return out
end

-- Coût d'achat /u de k unités d'un composant : le moins cher entre le PNJ (si connu) et l'HV. À l'HV,
-- on parcourt les enchères du dernier scan de la moins chère à la plus chère pour les k unités (une
-- seule enchère bradée ne fixe pas le prix de 20 composants) ; au-delà du carnet, le prix de marché.
function Analysis.ReagentCost(id, k)
  local db = ns.realmDB()
  local v = db.vendor and db.vendor[id]
  local s = Analysis.Get(id)
  k = math.max(k or 1, 1)
  local ah
  local book = db.book and db.book[id] and ns.Scan.UnpackBook(db.book[id])
  if book and book.levels and book.levels[1] then
    local got, cost = 0, 0
    walkBook(book.levels, k, function(qty, c) got, cost = qty, c end)
    if got < k then cost = cost + (k - got) * (s and s.price or book.levels[#book.levels][1]) end
    ah = cost / k
  else
    ah = s and (s.minNow or s.price)
  end
  if v and v.p and v.p > 0 and (not ah or v.p <= ah) then return v.p, "PNJ" end
  if ah then return ah, "HV" end
end

-- Artisanat : recettes relevées à l'ouverture de tes fenêtres de métier
Analysis.CRAFT_VENDOR_PER_DAY = 20 -- fabrications par jour qu'on compte pour une recette revendue au PNJ
function Analysis.Crafts()
  local out = {}
  for prof, list in pairs(ns.Prof and ns.Prof.Recipes() or {}) do
    for outId, r in pairs(list) do
      local s = Analysis.Get(outId)
      -- le verdict unique de Decide (matière brute ou fabriqué) : composants vendus bruts (raw),
      -- leur coût (les tiens à leur valeur brute, les autres à leur prix d'achat), et l'objet fabriqué
      -- à sa valeur sûre (l'HV seulement s'il s'y vend vraiment, sinon le marchand)
      local rc = ns.Decide.RawOrCraft(outId, r)
      local made = r.m or 1
      local ov, sells = rc.ov, rc.sells
      local hv = ov and ov.to == "HV"
      local vsell = ns.Decide.VendorPrice(outId) * made
      local e = { id = outId, s = s, prof = prof, name = r.n, cost = rc.cost, base = rc.base, missing = rc.missing, own = rc.own,
                  raw = rc.raw, value = rc.craft, vendorValue = vsell, perDay = s and s.surePerDay, diff = r.d,
                  sells = sells and sells.v, ok = rc.ok }
      -- tri de la colonne Conseil : un nombre (Fabriquer, marge faible, brut, prix manquant)
      e.okRank = rc.ok and 3 or (rc.gain and (rc.gain > 0 and 2 or 1)) or 0
      if e.cost then
        e.profit = rc.gain
        e.roi = e.profit / math.max(e.base, 1)
        e.sellTo = rc.to or "PNJ"
        -- prix de mise en vente /u à partir duquel la vente rembourse la fabrication + la marge
        local cc = ns.Decide.CraftCost(outId, s, sells)
        e.minPrice = cc and cc.target
        -- ce que la recette peut te rapporter par jour : à l'HV, ta part des ventes du marché
        -- (une recette rentable que personne n'achète ne rapporte rien) ; au PNJ, une quantité fixe
        -- un objet qui ne se vend pas (ou pas encore prouvé) ne rapporte rien par jour à l'HV
        local ok = s and hv
        e.vol = e.sellTo == "HV" and (ok and (s.surePerDay or 0) * Analysis.VENDOR_SHARE / made or 0)
          or Analysis.CRAFT_VENDOR_PER_DAY
        -- une recette que le verdict ne conseille pas (marge sous CRAFT_MARGIN, objet qui ne se vend
        -- pas) ne rapporte rien par jour : pas la peine
        e.daily = e.ok and e.profit * e.vol or 0
      end
      out[#out + 1] = e
    end
  end
  return out
end
