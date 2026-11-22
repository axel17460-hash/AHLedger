-- AHLedger - Analyse : prix, volume, tendances, signaux d'anticipation
local _, ns = ...

local Analysis = {}
ns.Analysis = Analysis

Analysis.AH_CUT = 0.05          -- commission HV (Classic : 5 %, à vérifier sur Forever)
Analysis.TREND_DAYS = 7         -- fenêtre de la régression de prix
Analysis.MIN_SOLD_FOR_REAL = 5  -- unités vendues mini pour faire confiance au prix réel de vente

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

-- Statistiques d'un objet sur les 14 derniers jours
function Analysis.ItemStats(db, id, today)
  local h = db.hist and db.hist[id]
  if not h then return nil end
  today = today or History.today()

  local pts = {}
  local w = { sold = 0, amb = 0, val = 0, obs = 0 }            -- 7 derniers jours
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
  if w.sold >= Analysis.MIN_SOLD_FOR_REAL then s.realPrice = w.val / w.sold end
  s.price = s.realPrice or priceNow
  s.perDay = w.obs > 0 and (w.sold + 0.5 * w.amb) / w.obs * 86400 or nil
  s.stock = recent.qn > 0 and recent.q / recent.qn or nil

  local b = slope(pts)
  s.trend = b and (math.exp(b) - 1) or nil          -- variation de prix par jour (0.04 = +4 %/j)

  -- Pas encore 3 jours de données AHLedger : on s'appuie sur l'historique d'Auctionator
  if not s.trend and ns.Bridge then
    local ah = ns.Bridge.History(id, 14)
    if ah and #ah >= 3 then
      local apts, rq, rn, pq, pn = {}, 0, 0, 0, 0
      for _, e in ipairs(ah) do
        if e[1] > -Analysis.TREND_DAYS then apts[#apts + 1] = { e[1], math.log(e[2]) } end
        if e[3] then
          if e[1] > -3 then rq, rn = rq + e[3], rn + 1 elseif e[1] > -10 then pq, pn = pq + e[3], pn + 1 end
        end
      end
      local ab = slope(apts)
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

  s.net = s.price * (1 - Analysis.AH_CUT)
  s.gpd = s.perDay and s.net * s.perDay or 0           -- or échangeable par jour sur ce marché

  local meta = AHLedgerDB.items[id]
  if not meta or not meta.s then ns.rememberItem(id); meta = AHLedgerDB.items[id] end
  s.vendorSell = meta and meta.s
  s.name = meta and meta.n
  s.quality = meta and meta.q
  s.class = meta and meta.c

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
  if s.obsHours < 6 then sig[#sig + 1] = "peu de données" end
  s.signals = sig

  -- Score "à farmer" : or/jour, boosté si le prix monte ou si le stock s'assèche
  s.score = s.gpd * clamp(1 + 3 * (s.trend or 0), 0.5, 1.5) * mult
  return s
end

-- Cache recalculé après chaque scan
local cache, cacheVersion, cacheRealm
function Analysis.All()
  local key = ns.realmKey()
  if cache and cacheVersion == ns.dataVersion and cacheRealm == key then return cache end
  local db = ns.realmDB()
  local today = History.today()
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
function Analysis.VendorFlips()
  local db, out = ns.realmDB(), {}
  local all = Analysis.All().byId
  for id, v in pairs(db.vendor) do
    local s = all[id]
    if s then
      local margin = s.net - v.p
      if margin > 0 then
        local cap = (v.lim and v.lim > 0) and v.lim or math.huge
        local vol = math.min(s.perDay or 0, cap)
        out[#out + 1] = { id = id, s = s, buy = v.p, margin = margin, roi = margin / math.max(v.p, 1),
                          perDay = s.perDay, gpd = margin * vol, npc = v.npc, zone = v.zone, lim = v.lim }
      end
    end
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
