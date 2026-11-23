-- AHLedger - Creux et rebonds : quand le prix d'un objet tombe nettement sous son niveau habituel,
-- combien de fois remonte-t-il, et en combien de jours ? Sert au Flip HV « à stocker ».
--
-- Série de prix journalière : moyenne des prix médians relevés par AHLedger, complétée par
-- l'historique d'Auctionator (des prix minimums, ramenés au niveau des médianes par le rapport
-- observé les jours où les deux existent).
-- Un creux commence le jour où le prix passe DIP sous la médiane des 7 jours précédents. Il est
-- « remonté » le premier jour où le prix revient à RECOVER près de cette référence, « raté » s'il ne
-- l'a pas fait en MAX_WAIT jours. Les creux terminés sont comptés une seule fois dans db.rebound[id],
-- qui n'est pas purgé avec l'historique : la connaissance s'accumule au fil des mois.
local _, ns = ...

local Rebound = {}
ns.Rebound = Rebound

Rebound.DIP = 0.15          -- creux : 15 % sous le prix habituel
Rebound.RECOVER = 0.05      -- remonté : revenu à 5 % près du prix habituel
Rebound.MAX_WAIT = 14       -- au-delà de 14 jours sans remonter, le creux est raté
Rebound.REF_DAYS = 7        -- prix habituel = médiane des 7 jours précédents
Rebound.MIN_REF = 3         -- ... dont au moins 3 jours avec un prix
Rebound.MIN_EVENTS = 3      -- creux terminés avant de faire confiance au taux et au délai
Rebound.KEEP_WAITS = 20     -- délais gardés par objet
Rebound.SERIES_DAYS = 45    -- jours d'historique Auctionator lus
Rebound.WEEK_MIN_DAYS = 21  -- jours de prix avant de parler du jour de la semaine
Rebound.WEEK_MIN_GAIN = 0.05
Rebound.WEEKDAYS = { [0] = "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi" }

local History = ns.History

local function median(t)
  if #t == 0 then return nil end
  local s = {}
  for i, v in ipairs(t) do s[i] = v end
  table.sort(s)
  local m = (#s + 1) / 2
  return (s[math.floor(m)] + s[math.ceil(m)]) / 2
end
Rebound.median = median

-- Série { [jour] = prix } jusqu'au jour last inclus (par défaut : hier, la journée en cours n'est pas finie)
function Rebound.Series(db, id, today, last)
  last = last or today - 1
  local out = {}
  local h = db.hist and db.hist[id]
  if h then
    for d, str in pairs(h) do
      d = tonumber(d)
      if d and d <= last then
        local r = History.parse(str)
        if r and r.pN > 0 then out[d] = r.pSum / r.pN end
      end
    end
  end
  local auc = ns.Bridge and ns.Bridge.History(id, Rebound.SERIES_DAYS)
  if auc and #auc > 0 then
    local ratios = {}
    for _, e in ipairs(auc) do
      local d = today + e[1]
      if out[d] and e[2] > 0 then ratios[#ratios + 1] = out[d] / e[2] end
    end
    local k = #ratios >= 2 and math.max(0.8, math.min(3, median(ratios))) or 1
    for _, e in ipairs(auc) do
      local d = today + e[1]
      if d <= last and not out[d] then out[d] = e[2] * k end
    end
  end
  return out
end

-- Prix habituel au jour d : médiane des REF_DAYS jours précédents
function Rebound.RefAt(series, d)
  local p = {}
  for x = d - Rebound.REF_DAYS, d - 1 do if series[x] then p[#p + 1] = series[x] end end
  if #p < Rebound.MIN_REF then return nil end
  return median(p)
end

-- Creux d'une série : liste des creux terminés { start, ref, ok, wait }, et le creux en cours s'il y en a un
function Rebound.Events(series, last)
  local days = {}
  for d in pairs(series) do days[#days + 1] = d end
  table.sort(days)
  local events, dip = {}, nil
  for _, d in ipairs(days) do
    local p, closed = series[d], false
    if dip then
      if p >= dip.ref * (1 - Rebound.RECOVER) then
        dip.ok, dip.wait = true, d - dip.start
        events[#events + 1] = dip
        dip, closed = nil, true
      elseif d - dip.start >= Rebound.MAX_WAIT then
        dip.ok = false
        events[#events + 1] = dip
        dip, closed = nil, true
      end
    end
    if not dip then
      local ref = not closed and Rebound.RefAt(series, d)
      if ref and p <= ref * (1 - Rebound.DIP) then dip = { start = d, ref = ref, low = p } end
    elseif p < dip.low then
      dip.low = p
    end
  end
  if dip and last and last - dip.start >= Rebound.MAX_WAIT then
    dip.ok = false
    events[#events + 1] = dip
    dip = nil
  end
  return events, dip
end

-- Une fois par jour : compte les creux qui se sont terminés depuis la dernière fois
function Rebound.Update(db, today)
  if db.reboundDay == today then return end
  db.rebound = db.rebound or {}
  for id in pairs(db.hist or {}) do
    local events = Rebound.Events(Rebound.Series(db, id, today), today - 1)
    local r = db.rebound[id]
    for _, e in ipairs(events) do
      if not r or e.start > (r.seen or -math.huge) then
        if not r then r = { n = 0, ok = 0, w = "" }; db.rebound[id] = r end
        r.n = r.n + 1
        if e.ok then
          r.ok = r.ok + 1
          local w = {}
          for x in (r.w or ""):gmatch("%d+") do w[#w + 1] = x end
          w[#w + 1] = tostring(e.wait)
          while #w > Rebound.KEEP_WAITS do table.remove(w, 1) end
          r.w = table.concat(w, ",")
        end
        r.seen = e.start
      end
    end
  end
  db.reboundDay = today
end

-- Ce qu'on sait des rebonds d'un objet :
-- { n = creux terminés, ok = remontés, rate = chance de remonter (a priori 1 sur 2), wait = délai médian (j),
--   slow = délai lent (8 creux remontés sur 10 l'ont fait avant), known = assez de creux pour y croire }
function Rebound.Get(db, id)
  local r = db.rebound and db.rebound[id]
  local n, ok = r and r.n or 0, r and r.ok or 0
  local w = {}
  for x in (r and r.w or ""):gmatch("%d+") do w[#w + 1] = tonumber(x) end
  table.sort(w)
  return { n = n, ok = ok, rate = (ok + 1) / (n + 2), wait = median(w),
           slow = #w > 0 and w[math.max(1, math.ceil(#w * 0.8))] or nil, known = n >= Rebound.MIN_EVENTS }
end

-- Meilleur jour de la semaine pour vendre : écart moyen du prix à son prix habituel, par jour de la semaine
function Rebound.Weekday(series)
  local by, all, n, lo, hi = {}, 0, 0, math.huge, -math.huge
  for d, p in pairs(series) do
    local ref = Rebound.RefAt(series, d)
    if ref and ref > 0 then
      local wd = tonumber(date("%w", d * 86400 + 43200))
      local b = by[wd] or { s = 0, n = 0 }
      by[wd] = b
      b.s, b.n = b.s + p / ref, b.n + 1
      all, n = all + p / ref, n + 1
      lo, hi = math.min(lo, d), math.max(hi, d)
    end
  end
  if n == 0 or hi - lo + 1 < Rebound.WEEK_MIN_DAYS then return nil end
  local best, gain
  for wd, b in pairs(by) do
    if b.n >= 2 then
      local g = b.s / b.n - all / n
      if not gain or g > gain then best, gain = wd, g end
    end
  end
  if gain and gain >= Rebound.WEEK_MIN_GAIN then return { day = best, name = Rebound.WEEKDAYS[best], gain = gain } end
end

-- Situation actuelle d'un objet pour un achat à stocker : prix habituel d'avant le creux (celui du
-- creux en cours s'il y en a un), rebonds connus, meilleur jour de vente
function Rebound.Now(db, id, today)
  today = today or History.today()
  local series = Rebound.Series(db, id, today, today)
  local done = {}
  for d, p in pairs(series) do if d < today then done[d] = p end end
  local _, dip = Rebound.Events(done, today - 1)
  local ref = dip and dip.ref or Rebound.RefAt(series, today)
  if not ref then return nil end
  local out = Rebound.Get(db, id)
  out.ref = ref
  out.dipSince = dip and dip.start and (today - dip.start) or nil
  out.weekday = Rebound.Weekday(series)
  return out
end
