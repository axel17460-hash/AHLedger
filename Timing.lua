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
-- Stockage compact (db.timing, jamais purgé, comme db.rebound : la connaissance s'accumule) :
--   v     = 1 (format)
--   upto  = heure du dernier scan intégré (évite de compter deux fois un scan)
--   first = début du premier intervalle observé
--   obs   = "s0,s1,…,s27"  secondes observées par case (case = jour * 4 + tranche, jour 0 = dimanche)
--   all   = "case:n;case:n" enchères vendues tous objets confondus, en dixièmes (répartition au prorata)
--   it[id]= "case:n;case:n" enchères vendues de l'objet, en dixièmes ; seules les cases non nulles
--   dn    = { [jour] = nombre de dates distinctes observées }, dl = { [jour] = dernière date vue }
-- Première utilisation : reprise des snapshots bruts déjà stockés (db.scans), où l'on ne connaît que
-- les unités vendues par scan : chaque objet vendu dans un intervalle y compte pour UNE enchère.
local _, ns = ...

local Timing = {}
ns.Timing = Timing

Timing.SLOTS = 4                -- tranches de 6 h
Timing.SLOT_HOURS = 6
Timing.CELLS = 7 * Timing.SLOTS
Timing.MAX_GAP = 6 * 3600       -- intervalle entre scans au-delà duquel l'heure des ventes est trop floue
Timing.PRIOR_HOURS = 2          -- lissage : chaque case reçoit 2 h fictives au taux moyen
Timing.MIN_EVENTS = 15          -- enchères vendues avant de parler du moment (objet)
Timing.MIN_EVENTS_ALL = 60      -- idem, tous objets confondus
Timing.MIN_HOURS = 12           -- heures de marché observées au total
Timing.MIN_BUCKET_HOURS = 2     -- une case (ou un jour, une tranche) doit avoir été observée 2 h
Timing.MIN_BUCKET_EVENTS = 4    -- ... et compter au moins 4 ventes pour être proposée
Timing.MIN_DAY_DATES = 2        -- un jour de la semaine doit avoir été vu à 2 dates différentes
Timing.GAIN_SURE = 0.15         -- fiable : au moins +15 % de ventes par heure
Timing.Z_SURE = 2               -- ... et un écart net face au hasard (loi de Poisson, z ≥ 2)
Timing.GAIN_HINT = 0.10         -- indicatif : +10 %, z ≥ 1
Timing.Z_HINT = 1

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
  return { v = 1, obs = packDense({}), all = "", it = {}, dn = {}, dl = {} }
end

-- Ajoute un intervalle observé [t - gap, t] et ses ventes : events[id] = enchères vendues
local function addInterval(tm, obs, all, cache, t, gap, events)
  local t0 = t - gap
  if not tm.first or t0 < tm.first then tm.first = t0 end
  local pieces = {}
  Timing.Split(t0, t, function(cell, secs, dateKey, wd)
    pieces[#pieces + 1] = { cell, secs }
    obs[cell] = obs[cell] + secs
    if tm.dl[wd] ~= dateKey then
      tm.dl[wd] = dateKey
      tm.dn[wd] = (tm.dn[wd] or 0) + 1
    end
  end)
  for id, n in pairs(events) do
    if n > 0 then
      local t2 = cache[id]
      if not t2 then t2 = parseSparse(tm.it[id]); cache[id] = t2 end
      for _, p in ipairs(pieces) do
        local add = math.floor(n * 10 * p[2] / gap + 0.5)
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
  for id, t in pairs(cache) do tm.it[id] = packSparse(t) end
end

-- Reprise des snapshots bruts déjà stockés (format v = 2) : une seule fois
function Timing.Backfill(db, tm)
  local obs, all, cache = parseDense(tm.obs), parseSparse(tm.all), {}
  local n = 0
  for _, sc in ipairs(db.scans or {}) do
    if sc.v == 2 and sc.gap and sc.gap > 0 and sc.gap <= Timing.MAX_GAP and sc.t and sc.t > (tm.upto or 0) and sc.items then
      local events = {}
      for id, sold in sc.items:gmatch("(%d+)=%d+,%d+,%d+,%d+,%d+,(%d+)") do
        if tonumber(sold) > 0 then events[tonumber(id)] = 1 end
      end
      addInterval(tm, obs, all, cache, sc.t, sc.gap, events)
      tm.upto = sc.t
      n = n + 1
    end
  end
  flush(tm, obs, all, cache)
  tm.backfilled = n
  return n
end

function Timing.Store(db)
  local tm = db.timing
  if not tm or tm.v ~= 1 then
    tm = newStore()
    db.timing = tm
    Timing.Backfill(db, tm)
  end
  tm.it, tm.dn, tm.dl = tm.it or {}, tm.dn or {}, tm.dl or {}
  return tm
end

-- Appelé à la fin de chaque scan (Scan.Finish), avec le diff du scan précédent et l'écart en secondes
function Timing.Record(db, now, diff, gap)
  local tm = Timing.Store(db)
  if not (diff and gap and gap > 0 and gap <= Timing.MAX_GAP) then return end
  if tm.upto and now <= tm.upto then return end -- déjà compté (reprise des snapshots)
  local events = {}
  for id, d in pairs(diff) do
    local n = d.ns or ((d.sold or 0) > 0 and 1 or 0) -- ns : enchères vendues (Scan.Diff)
    if n > 0 then events[id] = n end
  end
  local obs, all, cache = parseDense(tm.obs), parseSparse(tm.all), {}
  addInterval(tm, obs, all, cache, now, gap, events)
  flush(tm, obs, all, cache)
  tm.upto = now
end

-- Analyse -------------------------------------------------------------------------------------

-- Taux lissé et écart au hasard d'un groupe de cases (un jour, une tranche ou une case seule)
local function bucket(ev, obs, cells, mean)
  local e, o = 0, 0
  for _, c in ipairs(cells) do e, o = e + (ev[c] or 0), o + (obs[c] or 0) end
  local hours = o / 3600
  local b = { events = e, hours = hours }
  if hours <= 0 then return b end
  b.rate = (e + Timing.PRIOR_HOURS * mean) / (hours + Timing.PRIOR_HOURS)
  b.gain = b.rate / mean - 1
  local expected = mean * hours
  b.z = expected > 0 and (e - expected) / math.sqrt(expected) or 0
  b.ok = hours >= Timing.MIN_BUCKET_HOURS and e >= Timing.MIN_BUCKET_EVENTS
  return b
end

local function grade(b)
  if not (b and b.ok and b.gain) then return nil end
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
--   events, hours, perHour, days[0..6], slots[0..3] (chaque { events, hours, rate, gain, z, ok }),
--   bestDay, bestSlot, bestCell (mêmes champs + day / slot / cell / name / grade),
--   text = « +35 % de ventes le dimanche soir » (moment retenu, nil si rien de marqué) }
function Timing.Profile(db, id)
  local tm = Timing.Store(db)
  local obs = parseDense(tm.obs)
  local ev = parseSparse(id and tm.it[id] or tm.all)
  for c, n in pairs(ev) do ev[c] = n / 10 end
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

  local dayList, slotList, cellList = {}, {}, {}
  for wd = 0, 6 do
    local b = bucket(ev, obs, cellsOfDay(wd), mean)
    b.day, b.name = wd, "le " .. Timing.DAYS[wd]
    b.dates = tm.dn[wd] or 0
    b.ok = b.ok and b.dates >= Timing.MIN_DAY_DATES
    out.days[wd], dayList[#dayList + 1] = b, b
  end
  for s = 0, Timing.SLOTS - 1 do
    local b = bucket(ev, obs, cellsOfSlot(s), mean)
    b.slot, b.name = s, Timing.SLOT_SHORT[s]
    out.slots[s], slotList[#slotList + 1] = b, b
  end
  for c = 0, Timing.CELLS - 1 do
    local b = bucket(ev, obs, { c }, mean)
    b.cell, b.day, b.slot, b.name = c, math.floor(c / Timing.SLOTS), c % Timing.SLOTS, Timing.CellName(c)
    b.ok = b.ok and (tm.dn[b.day] or 0) >= Timing.MIN_DAY_DATES
    out.cells[c], cellList[#cellList + 1] = b, b
  end

  -- Comparer des jours n'a de sens que si plusieurs jours ont été observés (idem pour les tranches)
  local nDays, nSlots = 0, 0
  for _, b in ipairs(dayList) do if b.ok then nDays = nDays + 1 end end
  for _, b in ipairs(slotList) do if b.ok then nSlots = nSlots + 1 end end
  out.bestDay = nDays >= 3 and bestOf(dayList) or nil
  out.bestSlot = nSlots >= 2 and bestOf(slotList) or nil
  out.bestCell = (nDays >= 3 or nSlots >= 2) and bestOf(cellList) or nil
  for _, k in ipairs({ "bestDay", "bestSlot", "bestCell" }) do
    if out[k] then out[k].grade = grade(out[k]) end
  end

  -- Moment retenu : la case précise si elle tient, sinon le jour et / ou la tranche
  local d, s, c = out.bestDay, out.bestSlot, out.bestCell
  local function pick(level)
    if c and c.grade == level then return { c } end
    local t = {}
    if d and d.grade == level then t[#t + 1] = d end
    if s and s.grade == level then t[#t + 1] = s end
    if #t > 0 then return t end
  end
  local chosen = pick("sure")
  out.status = chosen and "sure" or nil
  if not chosen then
    chosen = pick("hint")
    out.status = chosen and "hint" or "flat"
  end
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
