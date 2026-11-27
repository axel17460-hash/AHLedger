-- AHLedger - Meilleur jour et meilleure heure pour vendre (logique pure, sans interface)
--
-- Les ventes sont repérées en comparant deux scans complets (Scan.Diff) : une enchère partie entre
-- le scan de t0 et celui de t1 a été achetée quelque part dans [t0, t1]. On répartit ces ventes,
-- au prorata du temps, dans des cases « jour de la semaine × tranche de 6 h » (heure locale du PC) :
-- 7 × 4 = 28 cases (nuit 0-6 h, matin 6-12 h, après-midi 12-18 h, soir 18-24 h).
--
-- POINT CLÉ : on ne compare jamais des nombres de ventes bruts, mais des ventes PAR HEURE OBSERVÉE.
-- Une vente n'est vue que si le joueur scanne avant et après : si tu scannes 4 h le dimanche soir et
-- 30 min les autres jours, le dimanche soir « fait » 8 fois plus de ventes sans que le marché y soit
-- plus actif. Chaque intervalle entre deux scans comparables ajoute donc aussi sa durée aux mêmes
-- cases (db.timing.obs), et le taux d'une case = ventes / heures observées dans cette case.
-- Une case jamais observée n'est ni bonne ni mauvaise : elle est inconnue et n'est jamais proposée.
--
-- On compte des ENCHÈRES vendues (événements), pas des unités : une pile de 20 achetée d'un coup
-- ferait un faux pic. Les intervalles de plus de MAX_GAP sont ignorés (trop flous pour situer l'heure).
--
-- STATISTIQUE (v2, relecture de novembre 2026) :
--   1. Test d'homogénéité du χ² (Pearson) sur les cases observées au moins MIN_BUCKET_HOURS : s'il ne
--      rejette pas « même taux partout » au seuil de 5 %, on n'annonce rien (« pas de moment marqué »).
--   2. Surdispersion : les ventes arrivent en grappes (un acheteur prend plusieurs enchères), la loi de
--      Poisson sous-estime alors le hasard. φ = χ² / ddl, plancher 1, et chaque z est divisé par √φ.
--      φ est estimé SANS les cases du groupe testé (sinon un vrai pic gonfle φ et s'étouffe lui-même :
--      z serait plafonné à √ddl, soit 2,4 si le joueur ne scanne que 7 cases), et jamais sous la
--      surdispersion de tout le marché (Σ χ² / Σ ddl de tous les objets, voir Dispersion).
--   3. Comparaisons multiples : 7 jours + 4 tranches + 28 cases = 39 tests. « fiable » exige z ≥ 3
--      (Bonferroni : 39 × 0,13 % ≈ 5 % de fausse alerte au plus par objet), « indicatif » z ≥ 2.
--   4. Lissage : chaque objet est tiré vers le profil global de l'HV (forme jour × tranche de tous les
--      objets), avec un a priori de PRIOR_EVENTS ventes fictives par groupe ; l'HV est tiré vers le plat.
--   5. Un jour ne compte comme vu que s'il l'a été à MIN_DAY_DATES dates, chacune avec MIN_DATE_HOURS.
--   6. Décroissance : demi-vie HALF_LIFE_WEEKS semaines. Au changement de semaine (semaine = numéro
--      de semaine depuis l'époque Unix, du jeudi au jeudi en UTC), obs, all et it sont multipliés par
--      le facteur hebdomadaire ; ce qui arrondit à 0 disparaît (purge naturelle). Les comptes pondérés
--      sont ensuite traités comme des comptes de Poisson : leur vraie variance (Σ w² λ) est plus
--      petite, le test est donc prudent. dn (dates vues) ne décroît pas : c'est une simple condition.
--   7. Conseil : le jour d'abord ; la case (jour × tranche) n'est ajoutée que si elle passe elle-même
--      le seuil. Une case ou une tranche seule n'est annoncée que si aucun jour ne passe.
--
-- Stockage compact (db.timing, sans autre purge que la décroissance) :
--   v     = 2 (format ; v1 est migré : comptes ×10, dates vues plafonnées, voir Migrate)
--   upto  = heure du dernier scan intégré (évite de compter deux fois un scan)
--   first = début du premier intervalle observé ; wk = semaine de la dernière décroissance
--   obs   = "s0,s1,…,s27"  secondes observées par case (case = jour * 4 + tranche, jour 0 = dimanche)
--   all   = "case:n;case:n" enchères vendues tous objets confondus, en centièmes (répartition au prorata)
--   it[id]= "case:n;case:n" enchères vendues de l'objet, en centièmes ; seules les cases non nulles
--   dn    = { [jour] = dates distinctes observées au moins MIN_DATE_HOURS },
--   dl    = { [jour] = dernière date vue }, dh = { [jour] = secondes observées à cette date }
-- Les anciens snapshots bruts (db.scans) ne sont PAS repris : ils ne donnent que les unités vendues
-- par objet, pas le nombre d'enchères, et le ratio enchères / unité n'est pas connu à la première
-- utilisation. Compter « une enchère par objet vendu » (v1) écrasait les heures chargées : exclus.
local _, ns = ...

local Timing = {}
ns.Timing = Timing

Timing.SLOTS = 4                -- tranches de 6 h
Timing.SLOT_HOURS = 6
Timing.CELLS = 7 * Timing.SLOTS
Timing.MAX_GAP = 6 * 3600       -- intervalle entre scans au-delà duquel l'heure des ventes est trop floue
Timing.SCALE = 100              -- comptes stockés en centièmes d'enchère
Timing.WEEK = 7 * 86400
Timing.HALF_LIFE_WEEKS = 5      -- décroissance : une vente d'il y a 5 semaines pèse moitié moins
Timing.DECAY = 0.5 ^ (1 / Timing.HALF_LIFE_WEEKS) -- facteur hebdomadaire (≈ 0,87)
Timing.PRIOR_EVENTS = 5         -- lissage : 5 ventes fictives par groupe, au taux du profil de l'HV
Timing.MIN_EVENTS = 15          -- enchères vendues avant de parler du moment (objet)
Timing.MIN_EVENTS_ALL = 60      -- idem, tous objets confondus
Timing.MIN_HOURS = 12           -- heures de marché observées au total
Timing.MIN_BUCKET_HOURS = 2     -- une case (ou un jour, une tranche) doit avoir été observée 2 h
Timing.MIN_BUCKET_EVENTS = 4    -- ... et compter au moins 4 ventes pour être proposée
Timing.MIN_DAY_DATES = 4        -- un jour de la semaine doit avoir été vu à 4 dates différentes…
Timing.MIN_DATE_HOURS = 1       -- … chacune observée au moins 1 h
Timing.CHI2_Z = 1.645           -- test d'homogénéité au seuil de 5 % (quantile normal, Wilson-Hilferty)
Timing.GAIN_SURE = 0.15         -- fiable : au moins +15 % de ventes par heure
Timing.Z_SURE = 3               -- ... et z ≥ 3 après surdispersion (Bonferroni sur ~39 tests)
Timing.GAIN_HINT = 0.10         -- indicatif : +10 %, z ≥ 2
Timing.Z_HINT = 2

Timing.DAYS = { [0] = "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi" }
Timing.SLOT_NAMES = { [0] = "nuit", "matin", "après-midi", "soir" }
Timing.SLOT_SHORT = { [0] = "la nuit", "le matin", "l'après-midi", "le soir" }
Timing.SLOT_LABELS = { [0] = "la nuit (0-6 h)", "le matin (6-12 h)", "l'après-midi (12-18 h)", "le soir (18-24 h)" }
Timing.RELIABILITY = { sure = "fiable", hint = "indicatif", flat = "pas de moment marqué", low = "pas assez de données" }

-- Chaînes compactes ---------------------------------------------------------------------------

local function parseSparse(str)
  local t = {}
  for c, n in (str or ""):gmatch("(%d+):(%d+)") do t[tonumber(c)] = tonumber(n) end
  return t
end

local function packSparse(t)
  local parts = {}
  for c = 0, Timing.CELLS - 1 do
    if (t[c] or 0) > 0 then parts[#parts + 1] = c .. ":" .. t[c] end
  end
  return table.concat(parts, ";")
end

local function parseDense(str)
  local t, i = {}, 0
  for n in (str or ""):gmatch("%d+") do t[i] = tonumber(n); i = i + 1 end
  for c = 0, Timing.CELLS - 1 do t[c] = t[c] or 0 end
  return t
end

local function packDense(t)
  local parts = {}
  for c = 0, Timing.CELLS - 1 do parts[c + 1] = math.floor((t[c] or 0) + 0.5) end
  return table.concat(parts, ",")
end
Timing.parseSparse, Timing.packSparse, Timing.parseDense = parseSparse, packSparse, parseDense

-- Découpe [t0, t1] en morceaux d'une seule case : fn(case, secondes, clé de date, jour)
function Timing.Split(t0, t1, fn)
  local t, guard = t0, 0
  while t < t1 and guard < 64 do
    guard = guard + 1
    local d = date("*t", t)
    local wd = (d.wday or 1) - 1
    local slot = math.floor((d.hour or 0) / Timing.SLOT_HOURS)
    local nextB = t + (Timing.SLOT_HOURS - (d.hour or 0) % Timing.SLOT_HOURS) * 3600 - (d.min or 0) * 60 - (d.sec or 0)
    if nextB <= t then nextB = t + 3600 end -- changement d'heure : on avance quand même
    local e = math.min(nextB, t1)
    fn(wd * Timing.SLOTS + slot, e - t, (d.year or 0) * 1000 + (d.yday or 0), wd)
    t = e
  end
end

-- Collecte ------------------------------------------------------------------------------------

local function newStore()
  return { v = 2, obs = packDense({}), all = "", it = {}, dn = {}, dl = {}, dh = {} }
end

-- Multiplie des comptes entiers par f ; un compte qui ne baisse pas à l'arrondi perd 1 (sinon les
-- petites valeurs, 1 à 3, resteraient figées) : tout finit par atteindre 0 et disparaît.
local function decayCounts(t, f)
  for c, n in pairs(t) do
    local m = math.floor(n * f + 0.5)
    if m >= n then m = n - 1 end
    t[c] = m > 0 and m or nil
  end
end

-- Décroissance au changement de semaine (obs, all et tous les objets) ; les objets vides sont retirés
local function decayTo(tm, obs, all, cache, wk)
  if tm.wk and wk > tm.wk then
    local f = Timing.DECAY ^ (wk - tm.wk)
    local o = {}
    for c = 0, Timing.CELLS - 1 do if obs[c] > 0 then o[c] = obs[c] end end
    decayCounts(o, f)
    for c = 0, Timing.CELLS - 1 do obs[c] = o[c] or 0 end
    decayCounts(all, f)
    for id, str in pairs(tm.it) do
      local t = cache[id] or parseSparse(str)
      decayCounts(t, f)
      cache[id] = t
    end
  end
  if not tm.wk or wk > tm.wk then tm.wk = wk end
end

-- Ajoute un intervalle observé [t - gap, t] et ses ventes : events[id] = enchères vendues
local function addInterval(tm, obs, all, cache, t, gap, events)
  local t0 = t - gap
  if not tm.first or t0 < tm.first then tm.first = t0 end
  local pieces = {}
  local need = Timing.MIN_DATE_HOURS * 3600
  Timing.Split(t0, t, function(cell, secs, dateKey, wd)
    pieces[#pieces + 1] = { cell, secs }
    obs[cell] = obs[cell] + secs
    -- un jour n'est « vu » à une date que s'il y a été observé au moins MIN_DATE_HOURS
    if tm.dl[wd] ~= dateKey then tm.dl[wd], tm.dh[wd] = dateKey, 0 end
    local before = tm.dh[wd] or 0
    tm.dh[wd] = before + secs
    if before < need and tm.dh[wd] >= need then tm.dn[wd] = (tm.dn[wd] or 0) + 1 end
  end)
  for id, n in pairs(events) do
    if n > 0 then
      local t2 = cache[id]
      if not t2 then t2 = parseSparse(tm.it[id]); cache[id] = t2 end
      -- arrondi du cumul (et non de chaque morceau) : la somme des morceaux = n exactement
      local cum, done = 0, 0
      for _, p in ipairs(pieces) do
        cum = cum + n * Timing.SCALE * p[2] / gap
        local add = math.floor(cum + 0.5) - done
        done = done + add
        if add > 0 then
          t2[p[1]] = (t2[p[1]] or 0) + add
          all[p[1]] = (all[p[1]] or 0) + add
        end
      end
    end
  end
end

local function flush(tm, obs, all, cache)
  tm.obs = packDense(obs)
  tm.all = packSparse(all)
  for id, t in pairs(cache) do
    local s = packSparse(t)
    tm.it[id] = s ~= "" and s or nil
  end
end

-- v1 → v2 : comptes en dixièmes → centièmes. v1 comptait une date dès la 1re seconde observée : on
-- plafonne dn par le nombre d'heures observées ce jour-là (une date valable = au moins 1 h), et la
-- dernière date est réputée déjà comptée. La part reprise des snapshots en v1 est gardée : elle
-- s'efface avec la décroissance.
function Timing.Migrate(tm)
  if tm.v ~= 1 then return tm end
  local function x10(str)
    local t = parseSparse(str)
    for c, n in pairs(t) do t[c] = n * 10 end
    return packSparse(t)
  end
  tm.all = x10(tm.all)
  for id, s in pairs(tm.it or {}) do tm.it[id] = x10(s) end
  local obs = parseDense(tm.obs)
  tm.dn, tm.dl, tm.dh = tm.dn or {}, tm.dl or {}, {}
  for wd = 0, 6 do
    local secs = 0
    for s = 0, Timing.SLOTS - 1 do secs = secs + obs[wd * Timing.SLOTS + s] end
    local cap = math.floor(secs / (Timing.MIN_DATE_HOURS * 3600))
    if tm.dn[wd] then tm.dn[wd] = math.min(tm.dn[wd], cap) end
    if tm.dl[wd] then tm.dh[wd] = Timing.MIN_DATE_HOURS * 3600 end
  end
  if tm.upto then tm.wk = math.floor(tm.upto / Timing.WEEK) end
  tm.backfilled = nil
  tm.v = 2
  return tm
end

function Timing.Store(db)
  local tm = db.timing
  if tm and tm.v == 1 then Timing.Migrate(tm) end
  if not tm or tm.v ~= 2 then
    tm = newStore()
    db.timing = tm
  end
  tm.it, tm.dn, tm.dl, tm.dh = tm.it or {}, tm.dn or {}, tm.dl or {}, tm.dh or {}
  return tm
end

-- Appelé à la fin de chaque scan (Scan.Finish), avec le diff du scan précédent et l'écart en secondes
function Timing.Record(db, now, diff, gap)
  local tm = Timing.Store(db)
  if not (diff and gap and gap > 0 and gap <= Timing.MAX_GAP) then return end
  if tm.upto and now <= tm.upto then return end -- déjà compté
  local events = {}
  for id, d in pairs(diff) do
    local n = d.ns or ((d.sold or 0) > 0 and 1 or 0) -- ns : enchères vendues (Scan.Diff)
    if n > 0 then events[id] = n end
  end
  local obs, all, cache = parseDense(tm.obs), parseSparse(tm.all), {}
  decayTo(tm, obs, all, cache, math.floor(now / Timing.WEEK))
  addInterval(tm, obs, all, cache, now, gap, events)
  flush(tm, obs, all, cache)
  tm.upto = now
end

-- Analyse -------------------------------------------------------------------------------------

local function toEvents(t)
  for c, n in pairs(t) do t[c] = n / Timing.SCALE end
  return t
end

-- Quantile du χ² à ddl degrés de liberté (approximation de Wilson-Hilferty)
function Timing.Chi2Crit(ddl, z)
  local a = 2 / (9 * ddl)
  return ddl * (1 - a + (z or Timing.CHI2_Z) * math.sqrt(a)) ^ 3
end

-- Forme du profil de l'HV : indice par case (taux lissé / taux moyen), 1 si inconnu
local function hvShape(tm, obs)
  local A = toEvents(parseSparse(tm.all))
  local EA, OA = 0, 0
  for c = 0, Timing.CELLS - 1 do EA, OA = EA + (A[c] or 0), OA + obs[c] end
  local g = {}
  local M = OA > 0 and EA / (OA / 3600) or 0
  for c = 0, Timing.CELLS - 1 do
    local h = obs[c] / 3600
    g[c] = (M > 0 and h > 0) and ((A[c] or 0) + Timing.PRIOR_EVENTS) / (h + Timing.PRIOR_EVENTS / M) / M or 1
  end
  return g
end

-- Résidus de Pearson par case observée au moins MIN_BUCKET_HOURS, χ² et degrés de liberté
local function homogeneity(ev, obs, mean)
  local resid, chi2, k = {}, 0, 0
  for c = 0, Timing.CELLS - 1 do
    local h = obs[c] / 3600
    if h >= Timing.MIN_BUCKET_HOURS then
      local ex = mean * h
      local r = ((ev[c] or 0) - ex) / math.sqrt(ex)
      resid[c], chi2, k = r, chi2 + r * r, k + 1
    end
  end
  return resid, chi2, k - 1
end

-- Surdispersion du marché : Σ χ² / Σ ddl sur tous les objets assez vendus (plancher 1). Plancher
-- commun de φ : avec peu de cases observées (10 ddl), l'estimation propre à un objet est trop
-- instable, et un objet vendu en grappes passerait sinon pour « marqué ». Calculé une fois par scan.
local poolCache = setmetatable({}, { __mode = "k" })
function Timing.Dispersion(tm, obs)
  local hit = poolCache[tm]
  if hit and hit.upto == tm.upto and hit.obs == tm.obs and hit.all == tm.all then return hit.phi end
  obs = obs or parseDense(tm.obs)
  local O = 0
  for c = 0, Timing.CELLS - 1 do O = O + obs[c] end
  local X, D = 0, 0
  if O > 0 then
    for _, str in pairs(tm.it) do
      local ev = toEvents(parseSparse(str))
      local E = 0
      for c = 0, Timing.CELLS - 1 do E = E + (ev[c] or 0) end
      if E >= Timing.MIN_EVENTS then
        local _, chi2, ddl = homogeneity(ev, obs, E / (O / 3600))
        if ddl >= 1 then X, D = X + chi2, D + ddl end
      end
    end
  end
  local phi = D > 0 and math.max(1, X / D) or 1
  poolCache[tm] = { upto = tm.upto, obs = tm.obs, all = tm.all, phi = phi }
  return phi
end

-- Taux lissé et écart au hasard d'un groupe de cases (un jour, une tranche ou une case seule)
-- ctx = { mean, g (forme a priori), resid (résidus de Pearson par case testée), chi2, ddl }
local function bucket(ev, obs, cells, ctx)
  local e, o, go = 0, 0, 0
  for _, c in ipairs(cells) do
    e, o = e + (ev[c] or 0), o + (obs[c] or 0)
    go = go + ctx.g[c] * (obs[c] or 0)
  end
  local hours = o / 3600
  local b = { events = e, hours = hours }
  if hours <= 0 then return b end
  local mean = ctx.mean
  local prior = mean * go / o -- taux attendu si l'objet suivait la forme de l'HV
  b.rate = (e + Timing.PRIOR_EVENTS) / (hours + Timing.PRIOR_EVENTS / prior)
  b.gain = b.rate / mean - 1
  local expected = mean * hours
  local z = expected > 0 and (e - expected) / math.sqrt(expected) or 0
  -- surdispersion estimée sans les cases du groupe
  local rb, kb = 0, 0
  for _, c in ipairs(cells) do
    if ctx.resid[c] then rb, kb = rb + ctx.resid[c] ^ 2, kb + 1 end
  end
  local phi = 1
  if ctx.ddl - kb >= 1 then phi = (ctx.chi2 - rb) / (ctx.ddl - kb)
  elseif ctx.ddl >= 1 then phi = ctx.chi2 / ctx.ddl end
  b.phi = math.max(1, phi, ctx.pool or 1)
  b.z0, b.z = z, z / math.sqrt(b.phi)
  b.ok = hours >= Timing.MIN_BUCKET_HOURS and e >= Timing.MIN_BUCKET_EVENTS
  return b
end

local function grade(b)
  if not (b and b.ok and b.gain and b.z) then return nil end
  if b.gain >= Timing.GAIN_SURE and b.z >= Timing.Z_SURE then return "sure" end
  if b.gain >= Timing.GAIN_HINT and b.z >= Timing.Z_HINT then return "hint" end
end

local function cellsOfDay(wd)
  local t = {}
  for s = 0, Timing.SLOTS - 1 do t[#t + 1] = wd * Timing.SLOTS + s end
  return t
end

local function cellsOfSlot(s)
  local t = {}
  for wd = 0, 6 do t[#t + 1] = wd * Timing.SLOTS + s end
  return t
end

local function bestOf(list)
  local best
  for _, b in ipairs(list) do
    if b.ok and b.gain and (not best or b.gain > best.gain) then best = b end
  end
  return best
end

function Timing.CellName(cell)
  local wd, s = math.floor(cell / Timing.SLOTS), cell % Timing.SLOTS
  if s == 0 then return "la nuit du " .. Timing.DAYS[wd] end
  return "le " .. Timing.DAYS[wd] .. " " .. Timing.SLOT_NAMES[s]
end

-- Profil d'un objet (id) ou de tout l'HV (id = nil) :
-- { status = "sure" | "hint" | "flat" | "low", reliability = texte, why = raison si "low",
--   events, hours, perHour, chi2, ddl, crit, marked (homogénéité rejetée), phi, pool (φ du marché),
--   days[0..6], slots[0..3], cells[0..27] (chaque { events, hours, rate, gain, z, phi, ok, grade }),
--   bestDay, bestSlot, bestCell (mêmes champs + day / slot / cell / name),
--   text = « +20 % de ventes le dimanche · +90 % de ventes le dimanche soir » (nil si rien de marqué),
--   chosen = groupes annoncés, gain = gain du premier }
function Timing.Profile(db, id)
  local tm = Timing.Store(db)
  local obs = parseDense(tm.obs)
  local ev = toEvents(parseSparse(id and tm.it[id] or tm.all))
  local E, O = 0, 0
  for c = 0, Timing.CELLS - 1 do E, O = E + (ev[c] or 0), O + obs[c] end
  local out = { events = E, hours = O / 3600, days = {}, slots = {}, cells = {} }
  local minEv = id and Timing.MIN_EVENTS or Timing.MIN_EVENTS_ALL
  if O / 3600 < Timing.MIN_HOURS or E < minEv then
    out.status = "low"
    out.why = ("%.0f vente%s sur %.0f h observées (il en faut %d sur %d h)"):format(E, E >= 2 and "s" or "", O / 3600,
      minEv, Timing.MIN_HOURS)
    out.reliability = Timing.RELIABILITY.low
    return out
  end
  local mean = E / (O / 3600)
  out.perHour = mean

  -- Test d'homogénéité : même taux dans toutes les cases assez observées ?
  local resid, chi2, ddl = homogeneity(ev, obs, mean)
  out.chi2, out.ddl = chi2, ddl
  out.crit = ddl >= 1 and Timing.Chi2Crit(ddl) or nil
  out.marked = out.crit ~= nil and chi2 > out.crit
  out.phi = ddl >= 1 and math.max(1, chi2 / ddl) or 1

  local g
  if id then g = hvShape(tm, obs) else
    g = {}
    for c = 0, Timing.CELLS - 1 do g[c] = 1 end
  end
  out.pool = id and Timing.Dispersion(tm, obs) or 1
  local ctx = { mean = mean, g = g, resid = resid, chi2 = chi2, ddl = ddl, pool = out.pool }

  local dayList, slotList, cellList = {}, {}, {}
  for wd = 0, 6 do
    local b = bucket(ev, obs, cellsOfDay(wd), ctx)
    b.day, b.name = wd, "le " .. Timing.DAYS[wd]
    b.dates = tm.dn[wd] or 0
    b.ok = b.ok and b.dates >= Timing.MIN_DAY_DATES
    out.days[wd], dayList[#dayList + 1] = b, b
  end
  for s = 0, Timing.SLOTS - 1 do
    local b = bucket(ev, obs, cellsOfSlot(s), ctx)
    b.slot, b.name = s, Timing.SLOT_SHORT[s]
    out.slots[s], slotList[#slotList + 1] = b, b
  end
  for c = 0, Timing.CELLS - 1 do
    local b = bucket(ev, obs, { c }, ctx)
    b.cell, b.day, b.slot, b.name = c, math.floor(c / Timing.SLOTS), c % Timing.SLOTS, Timing.CellName(c)
    b.ok = b.ok and (tm.dn[b.day] or 0) >= Timing.MIN_DAY_DATES
    out.cells[c], cellList[#cellList + 1] = b, b
  end
  -- Rien n'est noté si l'homogénéité n'est pas rejetée
  if out.marked then
    for _, list in ipairs({ dayList, slotList, cellList }) do
      for _, b in ipairs(list) do b.grade = grade(b) end
    end
  end

  -- Comparer des jours n'a de sens que si plusieurs jours ont été observés (idem pour les tranches)
  local nDays, nSlots = 0, 0
  for _, b in ipairs(dayList) do if b.ok then nDays = nDays + 1 end end
  for _, b in ipairs(slotList) do if b.ok then nSlots = nSlots + 1 end end
  out.bestDay = nDays >= 3 and bestOf(dayList) or nil
  out.bestSlot = nSlots >= 2 and bestOf(slotList) or nil
  out.bestCell = (nDays >= 3 or nSlots >= 2) and bestOf(cellList) or nil

  -- Moment retenu : le jour d'abord, et sa meilleure case seulement si elle passe elle-même le seuil ;
  -- sinon une case seule, sinon une tranche de la semaine
  local d, s, c = out.bestDay, out.bestSlot, out.bestCell
  local function passes(b, level) return b and b.grade and (b.grade == "sure" or level == "hint") end
  local chosen
  for _, level in ipairs({ "sure", "hint" }) do
    if passes(d, level) then
      chosen = { d }
      local inDay = {}
      for sl = 0, Timing.SLOTS - 1 do inDay[#inDay + 1] = out.cells[d.day * Timing.SLOTS + sl] end
      local dc = bestOf(inDay)
      if passes(dc, level) then chosen[2] = dc end
    elseif passes(c, level) then chosen = { c }
    elseif passes(s, level) then chosen = { s } end
    if chosen then out.status = level; break end
  end
  out.status = out.status or "flat"
  out.reliability = Timing.RELIABILITY[out.status]
  if chosen then
    local parts = {}
    for i, b in ipairs(chosen) do
      parts[i] = ("+%.0f %% de ventes %s"):format(b.gain * 100, b.name)
    end
    out.text = table.concat(parts, " · ")
    out.chosen = chosen
    out.gain = chosen[1].gain
  end
  return out
end

-- Une ligne lisible : « +35 % de ventes le dimanche soir (fiable, 48 ventes sur 120 h) »
function Timing.Describe(p)
  if not p then return "pas assez de données" end
  if p.status == "low" then return "pas assez de données : " .. (p.why or "") end
  if p.status == "flat" then
    return ("pas de moment marqué : les ventes sont régulières (%.0f ventes sur %.0f h observées)"):format(p.events, p.hours)
  end
  local tail = (" (%s, %.0f ventes sur %.0f h observées)"):format(p.reliability, p.events, p.hours)
  return p.text .. tail
end

-- Indice par jour et par tranche (taux / moyenne) : « dim ×1.35 », pour le rapport
function Timing.IndexLine(list, n0, n1, short)
  local parts = {}
  for k = n0, n1 do
    local b = list[k]
    if b and b.rate and b.hours >= Timing.MIN_BUCKET_HOURS then
      parts[#parts + 1] = ("%s ×%.2f (%.0f h)"):format(short(k), 1 + b.gain, b.hours)
    else
      parts[#parts + 1] = ("%s ? (%.0f h)"):format(short(k), b and b.hours or 0)
    end
  end
  return table.concat(parts, ", ")
end

-- Objets dont le moment est fiable, triés par gain (rapport)
function Timing.Items(db, minStatus)
  local tm = Timing.Store(db)
  local out = {}
  for id in pairs(tm.it) do
    local p = Timing.Profile(db, id)
    if p.status == "sure" or (minStatus == "hint" and p.status == "hint") then
      p.id = id
      out[#out + 1] = p
    end
  end
  table.sort(out, function(a, b) return (a.gain or 0) > (b.gain or 0) end)
  return out
end

-- /ahl moment [objet] : lien, identifiant ou morceau de nom
local function findItem(db, arg)
  local id = tonumber(arg:match("item:(%d+)") or arg:match("^%s*(%d+)%s*$"))
  if id then return id end
  local low = arg:lower()
  local best
  for x in pairs(Timing.Store(db).it) do
    local n = AHLedgerDB.items[x] and AHLedgerDB.items[x].n
    if n and n:lower():find(low, 1, true) then
      if n:lower() == low then return x end
      if not best or #n < #(AHLedgerDB.items[best].n) then best = x end
    end
  end
  return best
end

function Timing.Command(rest)
  local db = ns.realmDB()
  rest = rest or ""
  if rest:match("^%s*$") then
    local p = Timing.Profile(db)
    ns.print("Meilleur moment pour vendre, tout l'HV : " .. Timing.Describe(p))
    if p.status ~= "low" then
      ns.print("Par jour : " .. Timing.IndexLine(p.days, 0, 6, function(k) return Timing.DAYS[k]:sub(1, 3) end))
      ns.print("Par tranche : " .. Timing.IndexLine(p.slots, 0, Timing.SLOTS - 1, function(k) return Timing.SLOT_NAMES[k] end))
    end
    local items = Timing.Items(db)
    for i = 1, math.min(5, #items) do
      local e = items[i]
      ns.print(("  %s : %s"):format((AHLedgerDB.items[e.id] and AHLedgerDB.items[e.id].n) or ("#" .. e.id), e.text))
    end
    ns.print("Ventes par heure observée (tes heures de scan ne comptent pas). Détail d'un objet : /ahl moment <objet>")
    return
  end
  local id = findItem(db, rest)
  if not id then ns.print("Objet inconnu : " .. rest .. " (lien, identifiant ou nom)") return end
  local name = (AHLedgerDB.items[id] and AHLedgerDB.items[id].n) or ("#" .. id)
  local p = Timing.Profile(db, id)
  ns.print(("Meilleur moment pour vendre %s : %s"):format(name, Timing.Describe(p)))
  if p.status ~= "low" then
    ns.print("Par jour : " .. Timing.IndexLine(p.days, 0, 6, function(k) return Timing.DAYS[k]:sub(1, 3) end))
    ns.print("Par tranche : " .. Timing.IndexLine(p.slots, 0, Timing.SLOTS - 1, function(k) return Timing.SLOT_NAMES[k] end))
  end
end
