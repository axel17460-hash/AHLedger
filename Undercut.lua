-- AHLedger - Sous-cotes : en combien de temps tes enchères se font sous-coter, et à quelle heure.
--
-- Forever ne donne pas le nom des vendeurs : on ne peut pas dire QUI sous-cote. On mesure ce qu'on
-- voit : quand tu mets un objet en vente, l'addon le note ; ensuite, chaque recherche que tu lances
-- (et chaque scan) dit si quelqu'un est passé moins cher que toi. Le délai mesuré est un maximum :
-- « sous-coté en moins de 4 min » veut dire que ta recherche 4 min après la mise en vente le montrait.
--
-- Un joueur avec un addon (TSM, Auctionator) peut reposter vite, une touche par enchère : c'est permis.
-- Un robot réagit vite à TOUTE heure, nuit comprise, avec le même écart de prix : c'est interdit.
-- Le verdict ne fait que décrire ce qui a été vu. Lecture seule : rien n'est cherché ni posté à ta place.
local _, ns = ...

local Und = {}
ns.Undercut = Und

Und.FAST = 10 * 60          -- sous-coté en moins de 10 min : quelqu'un surveille l'objet
Und.SLOT_HOURS = 4          -- tranches de la journée (0-4 h, 4-8 h, …) pour « à toute heure »
Und.SUSPECT_FAST = 3        -- au moins 3 sous-cotes rapides…
Und.SUSPECT_SLOTS = 3       -- …dans au moins 3 tranches différentes : comportement de robot
Und.WATCHED_FAST = 2        -- 2 sous-cotes rapides : objet surveillé
Und.SAME_SEARCH = 10 * 60   -- recherche faite moins de 10 min avant la mise en vente : marché du moment
Und.OPEN_HOURS = 48         -- une enchère ne dure pas plus longtemps
Und.KEEP_DAYS = 14
Und.MAX_POSTS = 400
Und.NIGHT = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true } -- 1 h à 6 h 59

function Und.DB()
  local db = ns.realmDB()
  db.undercut = db.undercut or { posts = {}, fix1 = true } -- neuf : rien à corriger
  return db.undercut
end

function Und.Name(id)
  local meta = AHLedgerDB.items and AHLedgerDB.items[id]
  return (meta and meta.n) or ("objet " .. id)
end

local function key(a) return a.id .. "|" .. math.floor(a.unit + 0.5) end

local function prune(u, now)
  local keep = {}
  for _, p in ipairs(u.posts) do
    if now - p.t <= Und.KEEP_DAYS * 86400 then keep[#keep + 1] = p end
  end
  while #keep > Und.MAX_POSTS do table.remove(keep, 1) end
  u.posts = keep
end

-- Ta liste d'enchères relue.
-- * Parties (vendues, annulées, expirées) : toute enchère suivie en trop par rapport à la liste reçue,
--   la plus ancienne d'abord. Vaut aussi entre deux visites.
-- * Mises en vente : une enchère de plus à un prix que dans prev. Seulement si prev a été relue pendant
--   la même visite à l'HV (sameVisit) : une liste plus ancienne ne connaît pas ce que tu as posté depuis.
function Und.OnOwned(prev, list, sameVisit)
  local function count(l)
    local c = {}
    for _, a in ipairs(l or {}) do
      if a.unit and not a.sold then c[key(a)] = (c[key(a)] or 0) + 1 end
    end
    return c
  end
  Und.FixFirstRead()
  local after = count(list)
  local u, now = Und.DB(), time()
  local tracked = {}
  for _, p in ipairs(u.posts) do
    if not p.done then
      local k = key(p)
      tracked[k] = tracked[k] or {}
      table.insert(tracked[k], p)
    end
  end
  for k, ps in pairs(tracked) do
    table.sort(ps, function(a, b) return a.t < b.t end)
    for i = 1, #ps - (after[k] or 0) do ps[i].done = now end
  end
  if not (prev and sameVisit) then return end
  local before = count(prev)
  for k, n in pairs(after) do
    local add = n - (before[k] or 0)
    if add > 0 then
      local id, unit = k:match("^(%d+)|(%d+)$")
      Und.Posted(tonumber(id), tonumber(unit), add, now)
    end
  end
end

-- Correctif unique : la 1re version notait comme « mises en vente » toutes les enchères déjà en vente
-- à la première lecture d'une visite (même heure, plusieurs objets). Une vraie mise en vente groupée
-- (pile découpée) n'a qu'un objet : on retire les groupes de 3 objets différents ou plus au même instant.
function Und.FixFirstRead()
  local db = ns.realmDB()
  local u = db.undercut
  if not u or u.fix1 then return end
  local ids = {}
  for _, p in ipairs(u.posts) do
    ids[p.t] = ids[p.t] or {}
    ids[p.t][p.id] = true
  end
  local bad = {}
  for t, set in pairs(ids) do
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    if n >= 3 then bad[t] = true end
  end
  local keep = {}
  for _, p in ipairs(u.posts) do if not bad[p.t] then keep[#keep + 1] = p end end
  u.posts, u.fix1 = keep, true
end

-- Mise en vente vue. Si une recherche juste avant montrait déjà moins cher, tu as posté au-dessus du
-- marché : ce n'est pas une sous-cote, on ne la compte pas.
function Und.Posted(id, unit, n, now)
  if not (id and unit and unit > 0) then return end
  local u = Und.DB()
  now = now or time()
  prune(u, now)
  local above
  local live = ns.Live and ns.Live.Get(id)
  if live and now - live.t <= Und.SAME_SEARCH and live.min < unit - 0.5 then above = true end
  for _ = 1, n or 1 do
    u.posts[#u.posts + 1] = { id = id, unit = unit, t = now, above = above }
  end
  ns.rememberItem(id)
end

local function open(p, now)
  return not p.done and not p.hit and not p.above and now - p.t <= Und.OPEN_HOURS * 3600
end

-- Ton enchère la moins chère encore en vente pour cet objet (un scan la compte avec les autres)
local function ownMin(u, id, now)
  local m
  for _, p in ipairs(u.posts) do
    if p.id == id and not p.done and now - p.t <= Und.OPEN_HOURS * 3600 and (not m or p.unit < m) then m = p.unit end
  end
  return m
end

local function alert(p, src)
  local name = Und.Name(p.id)
  ns.print(("|cffff9900Sous-coté|r : %s à %s/u, quelqu'un est passé à %s en moins de %s (vu par %s)."):format(
    name, ns.money(p.by + (p.gap or (p.unit - p.by))), ns.money(p.by), Und.Delay(p.hit - p.t), src == "scan" and "le scan" or "ta recherche"))
end

-- Le moins cher des AUTRES vendeurs vu à l'heure t (nil : personne d'autre). partial : une page de
-- résultats seulement (Classic) ; elle peut montrer une sous-cote, pas prouver qu'il n'y en a pas.
-- Même règle que le scan : sous-coté = un autre est passé sous ta moins chère. Toutes tes enchères
-- ouvertes de l'objet le sont alors ensemble ; une seule alerte (la mise en vente la plus récente).
function Und.Observe(id, othersMin, t, partial, src)
  local u = ns.realmDB().undercut
  if not (u and id) then return end
  t = t or time()
  local mine = ownMin(u, id, t)
  if not mine then return end
  local under = othersMin and othersMin < mine - 0.5
  local last, hits = nil, {}
  for _, p in ipairs(u.posts) do
    if p.id == id and open(p, t) and t >= p.t then
      if under then
        p.hit, p.by, p.src, p.gap = t, othersMin, src or "search", mine - othersMin
        hits[#hits + 1] = p
        if not last or p.t > last.t then last = p end
      elseif not partial then
        p.ok = t
      end
    end
  end
  if not last then return end
  -- Une enchère plus ancienne pas revue « encore la moins chère » depuis la dernière mise en vente :
  -- la sous-cote a pu arriver avant celle-ci (tu as alors posté au-dessus du marché). Délai incertain,
  -- jamais compté comme rapide.
  for _, p in ipairs(hits) do
    if p.t < last.t and not (p.ok and p.ok >= last.t) then
      for _, q in ipairs(hits) do q.unsure = true end
      return
    end
  end
  if t - last.t <= Und.FAST then alert(last, last.src) end
end

-- Après un scan : lastMin compte aussi tes enchères. Une sous-cote = plus bas que ta moins chère.
function Und.ObserveScan(lastMin, t)
  local u = ns.realmDB().undercut
  if not u then return end
  local seen = {}
  for _, p in ipairs(u.posts) do
    if open(p, t) and not seen[p.id] then
      seen[p.id] = true
      -- objet absent du scan alors que ton enchère y est censée être : scan douteux, on n'en conclut rien.
      -- m peut être ta propre enchère : Observe ne compte que ce qui est sous ta moins chère.
      local m = lastMin[p.id]
      if m then Und.Observe(p.id, m, t, false, "scan") end
    end
  end
end

function Und.Delay(sec)
  if sec < 60 then return "1 min" end
  if sec < 3600 then return ("%d min"):format(math.ceil(sec / 60)) end
  return ("%.1f h"):format(sec / 3600)
end

local function median(t)
  if #t == 0 then return nil end
  table.sort(t)
  return t[math.floor((#t + 1) / 2)]
end

-- Par objet, sur les days derniers jours :
-- { id, posts (mesurées), hits, fast, slots (tranches distinctes des sous-cotes rapides), night,
--   delay (médiane du délai max, s), step (écart identique répété, ou nil), unseen (mises en vente
--   jamais revues), verdict = "bot" | "watched" | "normal" | "none", why }
function Und.Stats(days)
  Und.FixFirstRead()
  local u = ns.realmDB().undercut
  if not u then return {} end
  local now, by, order = time(), {}, {}
  local since = now - (days or Und.KEEP_DAYS) * 86400
  -- Une sous-cote = une observation (objet, heure) : 5 enchères d'une pile découpée, sous-cotées par la
  -- même recherche, comptent une fois, avec le délai de la mise en vente la plus récente. Une mise en
  -- vente pas sous-cotée = un lot (objet, prix, heure de mise en vente).
  local events, lots = {}, {}
  for _, p in ipairs(u.posts) do
    if p.t >= since and not p.above then
      local e = by[p.id]
      if not e then
        e = { id = p.id, posts = 0, hits = 0, fast = 0, night = 0, unseen = 0, slotSet = {}, delays = {}, steps = {}, calm = {} }
        by[p.id] = e
        order[#order + 1] = e
      end
      if p.hit then
        local k = p.id .. "|" .. p.hit
        local ev = events[k]
        if not ev then events[k] = p elseif p.t > ev.t then events[k] = p end
      else
        local k = p.id .. "|" .. math.floor(p.unit + 0.5) .. "|" .. p.t
        if not lots[k] then
          lots[k] = true
          if p.ok then
            e.posts = e.posts + 1
            e.calm[math.floor(tonumber(date("%H", p.t)) / Und.SLOT_HOURS)] = true -- revue, pas sous-cotée
          else
            e.unseen = e.unseen + 1
          end
        end
      end
    end
  end
  for _, p in pairs(events) do
    local e = by[p.id]
    e.posts, e.hits = e.posts + 1, e.hits + 1
    local d = p.hit - p.t
    e.delays[#e.delays + 1] = d
    local step = p.gap or (p.unit - p.by)
    e.steps[step] = (e.steps[step] or 0) + 1
    if d <= Und.FAST and not p.unsure then
      e.fast = e.fast + 1
      local h = tonumber(date("%H", p.hit))
      e.slotSet[math.floor(h / Und.SLOT_HOURS)] = true
      if Und.NIGHT[h] then e.night = e.night + 1 end
    elseif d > Und.FAST then
      e.calm[math.floor(tonumber(date("%H", p.t)) / Und.SLOT_HOURS)] = true -- sous-cotée, mais lentement
    end
  end
  for _, e in ipairs(order) do
    e.slots = 0
    for _ in pairs(e.slotSet) do e.slots = e.slots + 1 end
    e.delay = median(e.delays)
    for step, n in pairs(e.steps) do
      if n >= 3 and n >= e.hits * 0.75 then e.step = step end
    end
    -- tranches calmes : tu y as posté sans être sous-coté vite (heures à conseiller face à un robot)
    e.quiet = {}
    for k in pairs(e.calm) do if not e.slotSet[k] then e.quiet[#e.quiet + 1] = k end end
    table.sort(e.quiet)
    e.slotSet, e.delays, e.steps, e.calm = nil, nil, nil, nil
    local same = e.step and (", toujours %s de moins que toi"):format(ns.money(e.step)) or ""
    if e.fast >= Und.SUSPECT_FAST and e.slots >= Und.SUSPECT_SLOTS then
      e.verdict = "bot"
      e.why = ("sous-coté %d fois en moins de %s, à %d moments de la journée différents%s%s : réaction de robot probable"):format(
        e.fast, Und.Delay(Und.FAST), e.slots, e.night > 0 and (", dont %d la nuit"):format(e.night) or "", same)
    elseif e.fast >= Und.WATCHED_FAST then
      e.verdict = "watched"
      e.why = ("sous-coté %d fois en moins de %s%s : quelqu'un surveille (addon au clic ou robot), ne joue pas la guerre des prix"):format(
        e.fast, Und.Delay(Und.FAST), same)
    elseif e.hits > 0 then
      e.verdict = "normal"
      e.why = ("sous-coté %d fois sur %d, délai médian < %s : rythme normal"):format(e.hits, e.posts, Und.Delay(e.delay))
    else
      e.verdict = "none"
      e.why = e.posts > 0 and ("%d mise%s en vente revue%s, jamais sous-cotée"):format(e.posts, e.posts > 1 and "s" or "", e.posts > 1 and "s" or "")
        or "pas encore revu après la mise en vente"
    end
  end
  local RANK = { bot = 4, watched = 3, normal = 2, none = 1 }
  table.sort(order, function(a, b)
    if RANK[a.verdict] ~= RANK[b.verdict] then return RANK[a.verdict] > RANK[b.verdict] end
    if a.fast ~= b.fast then return a.fast > b.fast end
    return a.id < b.id
  end)
  return order
end


Und.HINT = "Pour mesurer : après une mise en vente, recherche l'objet quelques minutes plus tard, à différentes heures."

-- Lignes de texte (chat et rapport). max : nombre d'objets au plus.
function Und.Lines(max)
  local rows = Und.Stats()
  local out = {}
  if #rows == 0 then
    out[1] = "Aucune mise en vente notée depuis l'installation de ce suivi. " .. Und.HINT
    return out
  end
  local unseen = 0
  for _, e in ipairs(rows) do unseen = unseen + e.unseen end
  for i = 1, math.min(#rows, max or 10) do
    local e = rows[i]
    if e.posts > 0 then out[#out + 1] = ("%s : %s"):format(Und.Name(e.id), e.why) end
  end
  if #out == 0 then out[1] = "Aucune de tes mises en vente n'a encore été revue." end
  if unseen > 0 then
    out[#out + 1] = ("%d mise%s en vente jamais revue%s. %s"):format(unseen, unseen > 1 and "s" or "", unseen > 1 and "s" or "", Und.HINT)
  end
  return out
end

function Und.Report()
  ns.print(("Sous-cotes de tes enchères (%d derniers jours ; noms des vendeurs inconnus sur Forever) :"):format(Und.KEEP_DAYS))
  for _, l in ipairs(Und.Lines(10)) do ns.print("  " .. l) end
end
