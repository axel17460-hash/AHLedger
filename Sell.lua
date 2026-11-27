-- AHLedger - Vente : prix à poster, file de mise en vente et undercuts.
--
-- Objectif : gagner du temps à l'HV. On règle des règles de prix une fois, ensuite c'est un clic (ou une
-- touche) par enchère, sans réfléchir. Le module réutilise ce que l'addon calcule déjà : prix réel de
-- vente, vendus/jour, stock, signaux (Analysis), conseil des sacs (Bags), carnet du dernier scan (Scan),
-- tes enchères en cours (Auctions), tes achats (Ledger).
--
-- Règles Blizzard : AHLedger ne poste ni n'annule jamais seul. Chaque mise en vente et chaque annulation
-- exige un clic ou une touche de ta part (événement matériel) : pas de « tout poster » en un clic.
--
-- Rien ici ne dépend de l'interface (SellUI est dans UI.lua) : la logique reste testable hors jeu.
local _, ns = ...

local Sell = {}
ns.Sell = Sell

Sell.TROLL_SHARE = 0.10        -- sous le plancher, moins de 10 % du stock en rayon : c'est un bradeur, on l'ignore
Sell.REPOST_MIN_GAIN = 100     -- gain attendu mini (cuivre) pour proposer d'annuler et reposter
Sell.TOL = 1                   -- cuivre d'écart toléré pour reconnaître ta propre enchère dans le carnet
Sell.PIN_SECONDS = 4           -- après un post, l'objet n'est pas reproposé avant que les sacs soient relus
Sell.LOGIN_MAX_AGE = 3 * 86400 -- au login, on ne résume que des relevés de moins de 3 jours

-- Règles par défaut. Trois niveaux, le plus précis gagne : défaut → catégorie (classID) → objet.
-- Une valeur `false` désactive une règle héritée (ex. undercutPct = false : retour à l'undercut en cuivre).
Sell.DEFAULT_RULES = {
  undercutPct = false,    -- undercut en % du palier visé (ex. 0.02) ; sinon undercutCopper
  undercutCopper = 1,     -- 1 c sous le moins cher qui n'est pas à toi
  vendorMargin = 0.10,    -- plancher : rachat PNJ + 10 % (commission déduite)
  minProfit = 0.10,       -- plancher : coût d'achat connu (courriers) + 10 %
  farmCost = 1,           -- plancher : coût d'opportunité d'un objet farmé (Farm.UnitCost) × ce coefficient ; false = ignoré
  floorPct = 0.70,        -- plancher : 70 % du prix réel de vente
  floorFixed = false,     -- plancher fixé à la main, en cuivre/u
  fixedPrice = false,     -- prix fixé à la main (cuivre/u) : remplace palier − undercut et le plafond, mais pas le plancher
  ceilMult = 1.2,         -- plafond : 1,2 × le prix réel de vente (évite de poster sur un pic)
  stackSize = false,      -- unités par mise en vente (false : tout le conseillé d'un coup)
  stacks = false,         -- nombre de mises en vente voulues (avec stackSize : total voulu = taille × nombre)
  belowFloor = "keep",    -- sous le plancher : "keep" (garder), "vendor" (PNJ), "wait" (attendre)
  duration = false,       -- 12, 24 ou 48 h ; false : automatique selon la vitesse de vente
}

local function cut() return ns.Analysis and ns.Analysis.AH_CUT or 0.05 end
local function plain(s) return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
Sell.plain = plain

------------------------------------------------------------------------
-- Règles
------------------------------------------------------------------------

function Sell.DB()
  AHLedgerDB.sell = AHLedgerDB.sell or {}
  local d = AHLedgerDB.sell
  d.default, d.cat, d.item = d.default or {}, d.cat or {}, d.item or {}
  return d
end

-- Règles effectives d'un objet : défaut → catégorie → objet
function Sell.Rules(id)
  local r = {}
  for k, v in pairs(Sell.DEFAULT_RULES) do r[k] = v end
  local d = Sell.DB()
  local meta = AHLedgerDB.items and AHLedgerDB.items[id]
  local layers = { d.default, meta and meta.c and d.cat[meta.c] or nil, d.item[id] }
  for i = 1, 3 do
    local layer = layers[i]
    if layer then for k, v in pairs(layer) do r[k] = v end end
  end
  for k, v in pairs(r) do if v == false then r[k] = nil end end
  return r
end

-- 5g 20s 3c -> cuivre ; "250" = 250 cuivre. nil si illisible.
function Sell.ParseMoney(str)
  if not str or str == "" then return nil end
  local total, found = 0, false
  for n, unit in tostring(str):lower():gmatch("(%d+%.?%d*)%s*([gsc]?)") do
    n = tonumber(n)
    if not n then return nil end
    found = true
    total = total + n * (unit == "g" and 10000 or unit == "s" and 100 or 1)
  end
  return found and math.floor(total + 0.5) or nil
end

-- Modifie une règle. scope = "default", "cat" ou "item" ; target = classID ou id d'objet.
-- value nil : retire la règle de ce niveau (on retombe sur le niveau d'en dessous).
-- Renvoie true, ou false et un message.
function Sell.SetRule(scope, target, key, value)
  local d = Sell.DB()
  local layer
  if scope == "default" then layer = d.default
  elseif scope == "cat" then d.cat[target] = d.cat[target] or {}; layer = d.cat[target]
  elseif scope == "item" then d.item[target] = d.item[target] or {}; layer = d.item[target]
  else return false, "niveau inconnu : " .. tostring(scope) end
  if key == "undercut" then
    if value == nil then layer.undercutPct, layer.undercutCopper = nil, nil
    elseif type(value) == "table" and value.pct then layer.undercutPct = value.pct
    else layer.undercutPct, layer.undercutCopper = false, value end
  else
    if Sell.DEFAULT_RULES[key] == nil then return false, "règle inconnue : " .. tostring(key) end
    layer[key] = value
  end
  ns.dataVersion = (ns.dataVersion or 0) + 1
  return true
end

------------------------------------------------------------------------
-- Prix proposé
------------------------------------------------------------------------

-- Coût d'achat moyen à l'unité d'après tes courriers d'HV (Ledger), nil si tu n'as jamais acheté l'objet
local costCache, costKey
function Sell.Cost(id)
  if not (ns.Ledger and ns.Ledger.Summary and ns.Ledger.DB) then return nil end
  local key = tostring(ns.dataVersion) .. ":" .. #ns.Ledger.DB().ledger
  if costKey ~= key or not costCache then
    costCache, costKey = {}, key
    local ok, list = pcall(ns.Ledger.Summary)
    if ok and list then
      for _, r in ipairs(list) do
        if r.id and (r.bought or 0) > 0 and (r.spent or 0) > 0 then costCache[r.id] = r.spent / r.bought end
      end
    end
  end
  return costCache[id]
end

-- Plancher à l'unité : le plus grand de PNJ + marge, coût d'achat + marge, coût de farm, X % du prix réel,
-- plancher fixé.
-- Renvoie le prix et ce qui le fixe.
function Sell.Floor(id, s, rules)
  local best, why = 0, nil
  local function consider(v, label) if v and v > best then best, why = v, label end end
  local meta = AHLedgerDB.items and AHLedgerDB.items[id]
  local vendor = meta and meta.s or 0
  if vendor > 0 then consider(vendor * (1 + (rules.vendorMargin or 0)) / (1 - cut()), "PNJ + marge") end
  local cost = Sell.Cost(id)
  if cost then consider(cost * (1 + (rules.minProfit or 0)) / (1 - cut()), "coût d'achat + marge") end
  -- objet farmé : le temps passé à le looter vaut ton or/h de farm habituel (commission déduite, sans marge)
  local farm = rules.farmCost and ns.Farm and ns.Farm.UnitCost and ns.Farm.UnitCost(id)
  if farm and farm > 0 then consider(farm * rules.farmCost / (1 - cut()), "coût de farm") end
  if s and s.price and rules.floorPct then
    consider(s.price * rules.floorPct, ("%.0f %% du prix réel"):format(rules.floorPct * 100))
  end
  if rules.floorFixed then consider(rules.floorFixed, "plancher fixé") end
  return math.ceil(best), why
end

-- Tes enchères en cours pour cet objet : { {unit, qty} } (les enchères vendues et sans rachat sont ignorées)
function Sell.MyUnits(id)
  local out = {}
  local a = ns.Prof and ns.Prof.Char().auctions
  for _, e in ipairs(a and a.list or {}) do
    if e.id == id and not e.sold and e.unit and not e.cancelling then out[#out + 1] = { unit = e.unit, qty = e.qty } end
  end
  return out
end

-- Quantité que tu as déjà en vente pour cet objet
function Sell.Listed(id)
  local n = 0
  for _, m in ipairs(Sell.MyUnits(id)) do n = n + m.qty end
  return n
end

-- Carnet sans tes propres enchères. Le carnet vient du dernier scan, qui peut précéder certaines de tes
-- mises en vente : on n'enlève une enchère que si un palier de même prix (à TOL près) contient au moins
-- sa quantité.
-- levels : { {prix/u, quantité} } trié par prix ; mine : { {unit, qty} }
function Sell.WithoutMine(levels, mine)
  local out = {}
  for i, l in ipairs(levels or {}) do out[i] = { l[1], l[2] } end
  for _, m in ipairs(mine or {}) do
    local best
    for _, l in ipairs(out) do
      local d = math.abs(l[1] - m.unit)
      if l[2] >= m.qty and d <= Sell.TOL and (not best or d < math.abs(best[1] - m.unit)) then best = l end
    end
    if best then best[2] = best[2] - m.qty end
  end
  local clean = {}
  for _, l in ipairs(out) do if l[2] > 0 then clean[#clean + 1] = l end end
  return clean
end

-- Prix à poster pour un objet, à l'unité.
-- opts (surtout pour les tests) : s, rules, levels (carnet brut), mine.
-- Renvoie nil sans aucune donnée. Sinon une table :
--   status "ok" | "plancher" (le marché est sous ton plancher : price = nil, action = règle « sous le plancher »)
--   price, tier (palier visé), step (undercut), floor, floorWhy, ceil, capped, duration (h), net (/u),
--   ignored (unités bradées ignorées), reset { units, cost, tier } (les racheter relèverait le marché),
--   reason (texte court), noCompetition (rayon vide : prix habituel)
function Sell.Quote(id, opts)
  opts = opts or {}
  local s = opts.s or (ns.Analysis and ns.Analysis.Get(id))
  local rules = opts.rules or Sell.Rules(id)
  local levels = opts.levels
  if not levels then
    local db = ns.realmDB()
    local book = db.book and ns.Scan.UnpackBook(db.book[id])
    levels = book and book.levels or {}
  end
  levels = Sell.WithoutMine(levels, opts.mine or Sell.MyUnits(id))
  if not s and #levels == 0 then return nil end

  local sig = {}
  for _, g in ipairs(s and s.signals or {}) do sig[g] = true end
  local floor, floorWhy = Sell.Floor(id, s, rules)
  local stock = 0
  for _, l in ipairs(levels) do stock = stock + l[2] end
  local stockRef = math.max(stock, s and s.stock or 0)
  local q = { id = id, s = s, rules = rules, floor = floor, floorWhy = floorWhy, stock = stockRef, signals = sig }

  -- Anti-troll : les enchères sous le plancher dont la quantité cumulée est faible ne fixent pas le prix.
  -- On vise le premier palier « sain ». Si elles pèsent plus de TROLL_SHARE du stock, le marché est
  -- vraiment sous le plancher.
  local subQty, subCost, healthy = 0, 0, nil
  for _, l in ipairs(levels) do
    if l[1] < floor then
      subQty, subCost = subQty + l[2], subCost + l[1] * l[2]
    elseif not healthy then
      healthy = l[1]
    end
  end
  local tier
  if subQty > 0 and (stockRef <= 0 or subQty / stockRef < Sell.TROLL_SHARE) then
    tier, q.ignored = healthy, subQty
    if healthy then q.reset = { units = subQty, cost = subCost, tier = healthy } end
  elseif subQty > 0 then
    tier = levels[1][1] -- le marché lui-même est sous le plancher
  else
    tier = levels[1] and levels[1][1]
  end
  if not tier then
    -- rayon vide (ou seulement des bradeurs) : on retombe sur le prix habituel, sans undercut
    tier = s and s.price
    if not tier then return nil end
    q.noCompetition = true
  end

  -- Undercut : pénurie → le plus petit possible (on vise haut) ; afflux → doublé (on veut partir vite)
  local step = 0
  if not q.noCompetition then
    step = rules.undercutPct and math.max(1, math.floor(tier * rules.undercutPct)) or (rules.undercutCopper or 1)
    if sig["pénurie"] then step = 1 end
    if sig["afflux"] then step = step * 2 end
    step = math.max(1, math.floor(step))
  end
  local price = math.max(1, math.floor(tier - step))

  -- Plafond : jamais au-dessus de ceilMult × le prix réel (un peu plus haut en pénurie)
  local mult = rules.ceilMult
  if mult and sig["pénurie"] then mult = mult + 0.2 end
  q.ceil = (mult and s and s.price) and math.floor(s.price * mult) or nil
  if rules.fixedPrice then
    price, q.fixed = math.max(1, math.floor(rules.fixedPrice)), true -- ton prix : ni undercut ni plafond, le plancher reste
  elseif q.ceil and price > q.ceil then
    price, q.capped = q.ceil, true
  end

  q.tier, q.step = tier, step
  if price < floor then
    q.status, q.wouldPost, q.action = "plancher", price, rules.belowFloor or "keep"
  else
    q.status, q.price, q.net = "ok", price, price * (1 - cut())
  end

  -- Durée : rapide (≥ stock vendu par jour) → 12 h, on reposte souvent pour un dépôt faible ; sinon 48 h
  local hours = rules.duration
  if not hours then
    if sig["afflux"] then hours = 12
    elseif sig["pénurie"] then hours = 48
    elseif s and s.perDay then hours = (s.perDay >= stockRef) and 12 or 48
    else hours = 24 end
  end
  q.duration = hours

  -- Raison, en clair
  local parts = {}
  if q.fixed then
    parts[#parts + 1] = "prix fixé"
  elseif q.noCompetition then
    parts[#parts + 1] = "rayon vide : prix habituel"
  else
    parts[#parts + 1] = ("palier %s − %s"):format(plain(ns.money(tier)), plain(ns.money(step)))
  end
  if q.ignored then parts[#parts + 1] = ("%d u. bradées ignorées"):format(q.ignored) end
  if q.capped then parts[#parts + 1] = "plafond" end
  if sig["pénurie"] then parts[#parts + 1] = "pénurie" end
  if sig["afflux"] then parts[#parts + 1] = "afflux" end
  if q.status == "plancher" then
    parts[#parts + 1] = ("%s < plancher %s (%s)"):format(plain(ns.money(price)), plain(ns.money(floor)), floorWhy or "?")
  end
  q.reason = table.concat(parts, " · ")
  return q
end

------------------------------------------------------------------------
-- File de mise en vente
------------------------------------------------------------------------

local ACTION_LABEL = { keep = "Garder", vendor = "PNJ", wait = "Attendre" }
Sell.ACTION_LABEL = ACTION_LABEL

-- Une ligne de la file : { id, have, qty, price, status, net, reason, duration, ... }.
-- adv : le conseil des sacs (Bags.Advise) — la file ne reprend que les objets à vendre à l'HV.
-- opts.bank : ligne des exemplaires de la banque (non postable : à retirer d'abord) ;
-- opts.covered : unités déjà prévues par la ligne des sacs, déduites de la quantité visée.
function Sell.Plan(id, have, adv, opts)
  opts = opts or {}
  local q = Sell.Quote(id)
  if not q then return nil end
  local r = q.rules
  -- combien viser : le conseil des sacs (une journée de ventes), ou ce que tes règles imposent
  local planned = adv and adv.postQty or have
  if r.stackSize and r.stacks then planned = r.stackSize * r.stacks end -- « piles » ne joue qu'avec « pile »
  local listed = Sell.Listed(id)
  planned = math.min(have, planned - listed - (opts.covered or 0)) -- ne pas inonder : ce qui est déjà en vente compte
  if planned < 1 then return nil end
  local qty = math.min(planned, r.stackSize or planned)
  local e = { id = id, have = have, qty = qty, planned = planned, listed = listed, q = q, s = q.s,
              status = q.status, price = q.price, tier = q.tier, floor = q.floor, duration = q.duration,
              reason = q.reason, reset = q.reset }
  local shown = q.price or q.wouldPost or 0
  e.net = shown * qty * (1 - cut())
  if opts.bank then
    -- en banque : on montre ce qu'il rapporterait, sans pouvoir le poster d'ici
    e.bank, e.where = true, "banque"
    e.action = "Retirer"
    e.reason = "en banque : à retirer d'abord · " .. e.reason
    if q.status ~= "ok" then e.blocked = true; e.action = ACTION_LABEL[q.action] or q.action end
  elseif q.status == "ok" then
    e.action = "Poster"
    local meta = AHLedgerDB.items and AHLedgerDB.items[id]
    if meta and (meta.c == 2 or meta.c == 4) then e.reason = e.reason .. " · équipement : vérifie la variante" end
    if q.reset then
      e.reason = e.reason .. (" · les %d u. bradées coûtent %s : les racheter relève le marché"):format(
        q.reset.units, plain(ns.money(q.reset.cost)))
    end
  else
    e.action = ACTION_LABEL[q.action] or q.action
    e.blocked = true
  end
  return e
end

-- Les objets de tes sacs à vendre à l'HV, triés par gain attendu par clic (net de commission) :
-- avec 5 minutes devant toi, les meilleurs partent d'abord. Les lignes bloquées (sous le plancher) suivent.
-- Si ta banque a été relue (ouverte une fois), ses objets à vendre apparaissent aussi, marqués « banque » :
-- triés avec le reste pour voir ce qui vaut le détour, mais jamais postés (il faut d'abord les retirer).
-- Un objet à la fois dans les sacs et en banque : la ligne « banque » ne vise que ce que les sacs ne couvrent pas.
function Sell.Queue()
  local c = ns.Prof.Char()
  local out = {}
  local bags, bank = c.bags or {}, c.bank or {}
  local ids = {}
  for id in pairs(bags) do ids[id] = true end
  for id in pairs(bank) do ids[id] = true end
  for id in pairs(ids) do
    local nb, nk = bags[id] or 0, bank[id] or 0
    local adv = ns.Bags.Advise(id, nb + nk)
    if adv and adv.action == "Vendre HV" then
      local covered = 0
      if nb > 0 then
        local e = Sell.Plan(id, nb, adv)
        if e then out[#out + 1] = e; covered = e.planned end
      end
      if nk > 0 then
        local e = Sell.Plan(id, nk, adv, { bank = true, covered = covered })
        if e then out[#out + 1] = e end
      end
    end
  end
  table.sort(out, function(a, b)
    if (a.blocked or false) ~= (b.blocked or false) then return not a.blocked end
    if a.net ~= b.net then return a.net > b.net end
    if a.id ~= b.id then return a.id < b.id end
    return not a.bank and b.bank or false
  end)
  for i, e in ipairs(out) do e.order = i end -- l'interface trie sur ce rang par défaut
  return out
end

-- La ligne à poster au prochain clic : celle que tu as choisie (clic sur une ligne), sinon la première
-- qui n'est pas bloquée. Un objet à peine posté n'est pas reproposé avant que les sacs soient relus.
function Sell.Next(queue)
  queue = queue or Sell.Queue()
  local function recent(id) return Sell.last and Sell.last.id == id and time() - Sell.last.t < Sell.PIN_SECONDS end
  if Sell.pinned then
    for _, e in ipairs(queue) do
      if e.id == Sell.pinned and not e.blocked and not e.bank and not recent(e.id) then return e end
    end
  end
  for _, e in ipairs(queue) do
    if not e.blocked and not e.bank and not recent(e.id) then return e end
  end
end

function Sell.Pin(id) Sell.pinned = (Sell.pinned ~= id) and id or nil end

------------------------------------------------------------------------
-- Undercuts : mes enchères battues
------------------------------------------------------------------------

-- Probabilité d'écouler ses unités dans la fenêtre : (unités devant + les miennes) ÷ vitesse = jours
-- nécessaires ; une fenêtre plus courte que ça en laisse une partie invendue.
local function sellProb(ahead, qty, perDay, windowDays)
  local need = (ahead + qty) / perDay
  if need <= 0 then return 1 end
  return math.min(1, windowDays / need)
end

local function unitsBelow(levels, price)
  local n = 0
  for _, l in ipairs(levels) do if l[1] < price - 0.5 then n = n + l[2] end end
  return n
end

-- Gain attendu à annuler puis reposter. Annuler perd le dépôt (à vérifier en jeu), reposter en paie un
-- nouveau, perdu à l'expiration. EV = ventes attendues nettes de commission − dépôts perdus.
function Sell.RepostGain(qty, oldPrice, newPrice, p_old, p_new, deposit)
  local ev_old = qty * (p_old * oldPrice * (1 - cut()) - (1 - p_old) * deposit)
  local ev_new = qty * (p_new * newPrice * (1 - cut()) - (1 - p_new) * deposit) - qty * deposit
  return ev_new - ev_old
end

-- Enchères battues, regroupées par objet et par prix :
-- { id, s, n (nombre d'enchères), qty, unit, low (le moins cher, hors toi), gap, newPrice, gain, worth,
--   status = "à reposter" | "pas rentable" | "sous le plancher" | "bradeur ignoré" | "volume inconnu", left, auctions }
function Sell.Undercuts()
  local data = ns.Prof.Char().auctions
  local out = {}
  if not data then return out end
  local groups, order = {}, {}
  for _, a in ipairs(data.list) do
    if not a.sold and a.unit and not a.cancelling then
      local key = a.id .. "|" .. math.floor(a.unit + 0.5)
      local g = groups[key]
      if not g then
        g = { id = a.id, unit = a.unit, qty = 0, n = 0, auctions = {} }
        groups[key] = g
        order[#order + 1] = g
      end
      g.qty, g.n = g.qty + a.qty, g.n + 1
      g.auctions[#g.auctions + 1] = a
      if a.left and (not g.left or a.left < g.left) then g.left = a.left end
    end
  end
  local db = ns.realmDB()
  for _, g in ipairs(order) do
    local book = db.book and ns.Scan.UnpackBook(db.book[g.id])
    local levels = Sell.WithoutMine(book and book.levels or {}, Sell.MyUnits(g.id))
    local low = levels[1] and levels[1][1]
    if low and low < g.unit - 0.5 then
      local s = ns.Analysis.Get(g.id)
      local q = Sell.Quote(g.id, { levels = book.levels })
      g.s, g.low, g.gap, g.newPrice = s, low, g.unit / low - 1, q and q.price
      if not q then
        g.status = "volume inconnu"
      elseif q.status == "plancher" then
        g.status, g.newPrice = "sous le plancher", nil
      elseif q.price >= g.unit - 0.5 then
        g.status = "bradeur ignoré" -- ce qui te bat est sous ton plancher et pèse peu : ton prix est le bon
      elseif not (s and s.perDay and s.perDay > 0) then
        g.status = "volume inconnu"
      else
        local dep = s.deposit or 0
        local left = (g.left or 12 * 3600) / 86400
        local p_old = sellProb(unitsBelow(levels, g.unit), g.qty, s.perDay, left)
        local p_new = sellProb(unitsBelow(levels, q.price), g.qty, s.perDay, q.duration / 24)
        g.gain = Sell.RepostGain(g.qty, g.unit, q.price, p_old, p_new, dep)
        g.worth = g.gain > Sell.REPOST_MIN_GAIN
        g.status = g.worth and "à reposter" or "pas rentable"
        g.duration = q.duration
      end
      out[#out + 1] = g
    end
  end
  table.sort(out, function(a, b)
    if (a.worth or false) ~= (b.worth or false) then return a.worth or false end
    local ga, gb = a.gain or -math.huge, b.gain or -math.huge
    if ga ~= gb then return ga > gb end
    return a.id < b.id
  end)
  return out
end

------------------------------------------------------------------------
-- Résumé : « 6 à reposter, 3 vendues, 2 sous plancher, repasser dans ~8 h »
------------------------------------------------------------------------

function Sell.Summary()
  local data = ns.Prof.Char().auctions
  if not data then return nil end
  local r = { sold = 0, active = 0, undercut = 0, below = 0, age = time() - data.t }
  for _, a in ipairs(data.list) do
    if a.sold then
      r.sold = r.sold + 1
    else
      r.active = r.active + 1
      if a.left and (not r.soonest or a.left < r.soonest) then r.soonest = a.left end
    end
  end
  for _, u in ipairs(Sell.Undercuts()) do
    if u.worth then r.undercut = r.undercut + u.n
    elseif u.status == "sous le plancher" then r.below = r.below + u.n end
  end
  return r
end

function Sell.SummaryText(r)
  if not r then return nil end
  local parts = {}
  if r.undercut > 0 then parts[#parts + 1] = ("%d à reposter"):format(r.undercut) end
  if r.sold > 0 then parts[#parts + 1] = ("%d vendue%s"):format(r.sold, r.sold > 1 and "s" or "") end
  if r.below > 0 then parts[#parts + 1] = ("%d sous plancher"):format(r.below) end
  if r.active > 0 and r.soonest then parts[#parts + 1] = "repasser dans ~" .. ns.Auctions.LeftText(r.soonest) end
  if #parts == 0 then return r.active > 0 and ("%d en vente, rien à faire"):format(r.active) or "rien en vente" end
  return table.concat(parts, ", ")
end

-- À l'ouverture de l'HV (une fois par visite) et à la connexion (relevé de la dernière visite)
local announced = false
function Sell.OnAuctions()
  if announced or not ns.isAHOpen() then return end
  announced = true
  local text = Sell.SummaryText(Sell.Summary())
  if text then ns.print("Mes enchères : " .. text .. ". Onglet « Mes objets » > « file de vente » pour agir.") end
end
ns.on("AUCTION_HOUSE_SHOW", function() announced = false end)
ns.on("AUCTION_HOUSE_CLOSED", function() announced = false end)
ns.on("PLAYER_LOGIN", function()
  C_Timer.After(8, function()
    ns.safe("résumé vente", function()
      local r = Sell.Summary()
      if r and r.age < Sell.LOGIN_MAX_AGE and (r.active > 0 or r.sold > 0) then
        ns.print(("Au dernier relevé (il y a %s) : %s."):format(
          ns.Auctions.LeftText(math.max(r.age, 60)), Sell.SummaryText(r)))
      end
    end)
  end)
end)

------------------------------------------------------------------------
-- Poster et annuler (un clic ou une touche = une action)
------------------------------------------------------------------------

-- Premier emplacement de l'objet dans les sacs et nombre total d'exemplaires non liés
function Sell.FindItem(id)
  local C = C_Container
  if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo and ItemLocation and ItemLocation.CreateFromBagAndSlot) then
    return nil, 0
  end
  local first, total = nil, 0
  for bag = 0, 4 do
    for slot = 1, C.GetContainerNumSlots(bag) or 0 do
      local i = C.GetContainerItemInfo(bag, slot)
      if i and i.itemID == id and not i.isBound then
        first = first or ItemLocation:CreateFromBagAndSlot(bag, slot)
        total = total + (i.stackCount or 1)
      end
    end
  end
  return first, total
end

local DURATION_CODE = { [12] = 1, [24] = 2, [48] = 3 }

-- Session de jeu : depuis le chargement de l'addon (connexion ou /reload).
-- cancels : { {t, id, qty, dep} } annulations faites depuis AHLedger (dépôt perdu estimé).
Sell.session = { posted = 0, net = 0, cancelled = 0, start = time(), cancels = {} }

-- Dépôt estimé à l'unité (même estimation que l'analyse : part du prix PNJ, calibrée par Ledger)
function Sell.DepositPerUnit(id)
  local s = ns.Analysis and ns.Analysis.Get(id)
  if s and s.deposit then return s.deposit end
  local meta = AHLedgerDB.items and AHLedgerDB.items[id]
  return (meta and meta.s or 0) * (ns.Analysis and ns.Analysis.DEPOSIT_RATE or 0.15)
end

-- Résumé des ventes depuis `since` (secondes), d'après les courriers d'HV lus (Ledger) : il faut ouvrir la
-- boîte aux lettres pour qu'une vente ou une expiration apparaisse, et elle compte au moment de la lecture.
-- Dépôts perdus = enchères expirées (courriers) + annulations faites depuis AHLedger, au dépôt estimé ;
-- le dépôt d'une enchère vendue est rendu, il ne compte pas.
-- { since, secs, units, gross, cut, expired (unités), cancelled (enchères), depExpired, depCancel, depLost,
--   net (= gross − cut − depLost), perHour }
function Sell.SalesSummary(since)
  since = since or Sell.session.start
  local r = { since = since, secs = math.max(time() - since, 60), units = 0, gross = 0, cut = 0, expired = 0,
              cancelled = 0, depExpired = 0, depCancel = 0 }
  if ns.Ledger and ns.Ledger.DB then
    for _, e in ipairs(ns.Ledger.DB().ledger or {}) do
      if e.t and e.t >= since then
        if e.k == "sold" then
          r.units, r.gross, r.cut = r.units + (e.c or 0), r.gross + (e.g or 0), r.cut + (e.cut or 0)
        elseif e.k == "expired" then
          r.expired = r.expired + (e.c or 0)
          if e.id then r.depExpired = r.depExpired + (e.c or 0) * Sell.DepositPerUnit(e.id) end
        end
      end
    end
  end
  for _, c in ipairs(Sell.session.cancels or {}) do
    if c.t >= since then r.cancelled, r.depCancel = r.cancelled + 1, r.depCancel + (c.dep or 0) end
  end
  r.depLost = r.depExpired + r.depCancel
  r.net = r.gross - r.cut - r.depLost
  r.perHour = r.net / (r.secs / 3600)
  return r
end

-- Ventes réellement encaissées depuis le début de la session de jeu. { units, gross, cut, net, depLost, … }
function Sell.SessionSold() return Sell.SalesSummary(Sell.session.start) end

-- « Farmer ou acheter ? » : ventes de la session de jeu, et pendant la session /ahl farm en cours, à côté de
-- l'or/h du farm (loot valorisé + or ramassé) et de ton or/h de farm habituel (médiane de tes zones).
-- { game = SalesSummary, farm = Farm.CurrentStats() ou nil, farmSales = SalesSummary depuis le début du farm,
--   ref = or/h de référence ou nil }
function Sell.FarmCompare()
  local r = { game = Sell.SalesSummary(Sell.session.start) }
  local F = ns.Farm
  if F then
    r.farm = F.CurrentStats and F.CurrentStats()
    if r.farm then r.farmSales = Sell.SalesSummary(r.farm.start) end
    r.ref = F.RefRate and F.RefRate()
  end
  return r
end

local function salesLine(t)
  local m = function(v) return plain(ns.money(math.floor(v + 0.5))) end
  local dep = ""
  if t.depLost > 0 then
    dep = (" − dépôts perdus %s (%d u. expirée%s, %d annulée%s)"):format(m(t.depLost), t.expired,
      t.expired > 1 and "s" or "", t.cancelled, t.cancelled > 1 and "s" or "")
  end
  return ("vendu %d u. %s − commission %s%s = net %s (%s/h)"):format(t.units, m(t.gross), m(t.cut), dep,
    m(t.net), m(math.max(t.perHour, 0)))
end

-- Textes de l'onglet Farm : court (pied de page) et complet (aide, entière au survol)
function Sell.FarmCompareText(c)
  c = c or Sell.FarmCompare()
  local m = function(v) return plain(ns.money(math.floor(v + 0.5))) end
  local short = ("ventes de la session : net %s (%s/h)"):format(m(c.game.net), m(math.max(c.game.perHour, 0)))
  local long = {
    ("Session de jeu (depuis %s) : %s."):format(date("%H:%M", c.game.since), salesLine(c.game)),
  }
  if c.farm then
    short = short .. (" · farm en cours %s/h, encaissé %s/h"):format(m(c.farm.total), m(math.max(c.farmSales.perHour, 0)))
    long[#long + 1] = ("Farm en cours (%s, %d min) : loot ~%s/h + or ramassé %s/h = %s/h ; à l'HV pendant ce temps : %s."):format(
      c.farm.zone or "?", math.floor(c.farm.hours * 60 + 0.5), m(c.farm.lootPerHour), m(c.farm.moneyPerHour),
      m(c.farm.total), salesLine(c.farmSales))
  end
  if c.ref then
    short = short .. (" · farm habituel %s/h"):format(m(c.ref))
    long[#long + 1] = ("Ton farm habituel : %s/h (médiane de tes zones) ; c'est aussi ce que vaut le temps passé à looter un objet dans le plancher de vente (règle « farm »)."):format(m(c.ref))
  end
  long[#long + 1] = "Ventes et expirations comptent à la lecture des courriers : passe à la boîte aux lettres."
  return short, table.concat(long, " ")
end

-- Garde-fous : on ne poste jamais sous le plancher ni sous le rachat PNJ (net de commission), ni plus
-- de 3 fois au-dessus du prix réel : une erreur de calcul ne doit pas coûter d'or.
function Sell.Guard(e)
  if e.bank then return false, "objet en banque : retire-le d'abord" end
  if not e.price or e.price < 1 then return false, "pas de prix" end
  if e.floor and e.price < e.floor then return false, "sous le plancher" end
  local meta = AHLedgerDB.items and AHLedgerDB.items[e.id]
  if meta and meta.s and meta.s > 0 and e.price * (1 - cut()) < meta.s then return false, "le marchand paierait plus" end
  if e.s and e.s.price and e.price > e.s.price * 3 then return false, "plus de 3 × le prix réel" end
  return true
end

-- Poste la ligne e. À appeler depuis un clic ou une touche. Renvoie true, ou false et la raison.
function Sell.Post(e)
  local A = C_AuctionHouse
  if not (A and A.PostCommodity and A.PostItem) then
    return false, "l'API de mise en vente n'est pas disponible (seule l'API C_AuctionHouse est gérée)"
  end
  if not ns.isAHOpen() then return false, "ouvre l'hôtel des ventes" end
  local ok, why = Sell.Guard(e)
  if not ok then return false, why end
  local loc, total = Sell.FindItem(e.id)
  if not loc or total < 1 then return false, "objet introuvable dans les sacs (ou lié)" end
  local qty = math.min(e.qty, total)
  if A.GetAvailablePostCount then
    local okc, avail = pcall(A.GetAvailablePostCount, loc)
    if okc and type(avail) == "number" and avail > 0 then qty = math.min(qty, avail) end
  end
  local code = DURATION_CODE[e.duration] or 2
  -- marchandise (empilable, prix à l'unité) ou objet unique (prix de la pile entière) ?
  local commodity
  if A.GetItemCommodityStatus then
    local okc, st = pcall(A.GetItemCommodityStatus, loc)
    local COMMODITY = Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2
    if okc and st and st ~= 0 then commodity = st == COMMODITY end
  end
  if commodity == nil then
    local meta = AHLedgerDB.items and AHLedgerDB.items[e.id]
    commodity = not (meta and (meta.c == 2 or meta.c == 4))
  end
  local price = math.floor(e.price)
  if commodity then
    A.PostCommodity(loc, code, qty, price)
  else
    qty = 1
    A.PostItem(loc, code, 1, nil, price)
  end
  Sell.last = { id = e.id, t = time() }
  Sell.session.posted = Sell.session.posted + 1
  Sell.session.net = Sell.session.net + price * qty * (1 - cut())
  local name = (AHLedgerDB.items[e.id] and AHLedgerDB.items[e.id].n) or ("#" .. e.id)
  ns.print(("Mise en vente : %s ×%d à %s/u, %d h (net attendu ~%s)."):format(
    name, qty, ns.money(price), e.duration or 24, ns.money(price * qty * (1 - cut()))))
  return true
end

-- Un clic : poste la ligne suivante de la file
function Sell.PostNext()
  local e = Sell.Next()
  if not e then
    ns.print("Rien à poster : file vide ou tout est sous ton plancher (onglet « Mes objets » > « file de vente »).")
    return false
  end
  local ok, why = Sell.Post(e)
  if not ok then ns.print("|cffff5050Mise en vente impossible :|r " .. tostring(why)) end
  return ok
end

-- Annule la première enchère battue qui vaut la peine d'être repostée. Les objets reviennent par courrier
-- ou dans les sacs (à vérifier en jeu) : une fois dans les sacs, la file de mise en vente les reposte au
-- nouveau prix.
function Sell.CancelNext()
  local A = C_AuctionHouse
  if not (A and A.CancelAuction) then
    ns.print("|cffff5050Annulation impossible :|r l'API C_AuctionHouse.CancelAuction n'est pas disponible.")
    return false
  end
  if not ns.isAHOpen() then ns.print("Ouvre l'hôtel des ventes."); return false end
  for _, g in ipairs(Sell.Undercuts()) do
    if g.worth then
      for _, a in ipairs(g.auctions) do
        if a.aid then
          a.cancelling = true
          A.CancelAuction(a.aid)
          Sell.session.cancelled = Sell.session.cancelled + 1
          local cs = Sell.session.cancels
          cs[#cs + 1] = { t = time(), id = g.id, qty = a.qty, dep = (a.qty or 1) * Sell.DepositPerUnit(g.id) }
          local name = (AHLedgerDB.items[g.id] and AHLedgerDB.items[g.id].n) or ("#" .. g.id)
          ns.print(("Annulation : %s ×%d à %s/u. Nouveau prix conseillé %s/u : reposte-le depuis la file de vente une fois l'objet récupéré."):format(
            name, a.qty, ns.money(g.unit), ns.money(g.newPrice)))
          return true
        end
      end
    end
  end
  ns.print("Rien à annuler : aucune enchère battue qui vaille un repost (ou rouvre l'HV pour relire tes enchères).")
  return false
end

-- Fonctions globales pour les raccourcis clavier (Bindings.xml) : une touche = une action
BINDING_HEADER_AHLEDGER = "AHLedger"
BINDING_NAME_AHLEDGER_POSTNEXT = "Poster la suivante (file de vente)"
BINDING_NAME_AHLEDGER_CANCELNEXT = "Annuler l'enchère battue suivante"
function AHLedger_PostNext() ns.safe("poster suivant", Sell.PostNext) end
function AHLedger_CancelNext() ns.safe("annuler suivante", Sell.CancelNext) end

-- Texte de session pour le pied de page
function Sell.SessionText()
  local s = Sell.session
  local text = ("session : %d posée%s (~%s net), %d annulée%s"):format(
    s.posted, s.posted > 1 and "s" or "", plain(ns.money(s.net)), s.cancelled, s.cancelled > 1 and "s" or "")
  local sold = Sell.SessionSold()
  if sold.units > 0 or sold.depLost > 0 then
    text = text .. (" · encaissé %d u., commission %s"):format(sold.units, plain(ns.money(sold.cut)))
    if sold.depLost > 0 then text = text .. ", dépôts perdus " .. plain(ns.money(math.floor(sold.depLost + 0.5))) end
    text = text .. ", net " .. plain(ns.money(math.floor(sold.net + 0.5)))
  end
  return text
end

------------------------------------------------------------------------
-- /ahl vendre …
------------------------------------------------------------------------

local KEY_ALIAS = {
  undercut = "undercut", plancher = "floorPct", plafond = "ceilMult", marge = "vendorMargin", profit = "minProfit",
  pile = "stackSize", piles = "stacks", duree = "duration", ["durée"] = "duration", sous = "belowFloor",
  fixe = "floorFixed", prix = "fixedPrice", farm = "farmCost",
}
local BELOW_ALIAS = { garder = "keep", keep = "keep", pnj = "vendor", vendor = "vendor", attendre = "wait", wait = "wait" }

-- Valeur lue dans la commande : "off" désactive ; "2%" pour undercut ; "70%" pour plancher ; "1.2" pour plafond…
local function parseValue(key, text)
  local low = text:lower()
  if low == "off" or low == "non" or low == "defaut" or low == "défaut" then return nil, true end
  if key == "undercut" then
    local p = low:match("^(%d+%.?%d*)%s*%%$")
    if p then return { pct = tonumber(p) / 100 } end
    return Sell.ParseMoney(low)
  elseif key == "floorPct" or key == "vendorMargin" or key == "minProfit" then
    local p = low:match("^(%d+%.?%d*)%s*%%?$")
    return p and tonumber(p) / 100 or nil
  elseif key == "ceilMult" then
    return tonumber(low)
  elseif key == "stackSize" or key == "stacks" or key == "duration" then
    local n = tonumber(low)
    if key == "duration" and not DURATION_CODE[n or 0] then return nil end
    return n and math.floor(n) or nil
  elseif key == "belowFloor" then
    return BELOW_ALIAS[low]
  elseif key == "floorFixed" or key == "fixedPrice" then
    return Sell.ParseMoney(low)
  elseif key == "farmCost" then
    -- coefficient (1 = l'or/h de farm habituel) ; 0 désactive (false : bloque aussi le niveau hérité)
    local n = tonumber(low)
    if n == 0 then return false end
    return n and n > 0 and n or nil
  end
end

local function describe(r)
  local u = r.undercutPct and ("%.1f %%"):format(r.undercutPct * 100) or plain(ns.money(r.undercutCopper or 1))
  return ("undercut %s · plancher %.0f %% du prix réel, PNJ +%.0f %%, achat +%.0f %%, farm %s%s · plafond ×%.2f · pile %s × %s · durée %s · sous le plancher : %s"):format(
    u, (r.floorPct or 0) * 100, (r.vendorMargin or 0) * 100, (r.minProfit or 0) * 100,
    r.farmCost and ("×%.2g"):format(r.farmCost) or "non", r.floorFixed and (" , fixe " .. plain(ns.money(r.floorFixed))) or "", r.ceilMult or 0,
    tostring(r.stackSize or "tout"), tostring(r.stacks or "auto"), r.duration and (r.duration .. " h") or "auto",
    ACTION_LABEL[r.belowFloor or "keep"] or "?")
end

function Sell.Command(rest)
  rest = rest or ""
  local sub, args = rest:match("^(%S*)%s*(.-)$")
  sub = (sub or ""):lower()
  if sub == "" or sub == "file" then
    local q = Sell.Queue()
    if #q == 0 then ns.print("File de vente vide : rien à poster (sacs relus ? scan récent ?).") return end
    ns.print(("File de vente (%d lignes) :"):format(#q))
    for i = 1, math.min(#q, 8) do
      local e = q[i]
      local name = (AHLedgerDB.items[e.id] and AHLedgerDB.items[e.id].n) or ("#" .. e.id)
      ns.print(("%d. %s ×%d — %s — net ~%s — %s"):format(i, name, e.qty,
        e.price and (ns.money(e.price) .. "/u") or ("|cffff8040" .. e.action .. "|r"), ns.money(e.net), e.reason))
    end
  elseif sub == "regles" or sub == "règles" then
    local d = Sell.DB()
    ns.print("Règles par défaut : " .. describe(Sell.Rules(0)))
    for cat in pairs(d.cat) do ns.print(("Catégorie %s : règles propres (voir /ahl vendre regle cat %s …)"):format(cat, cat)) end
    local n = 0
    for _ in pairs(d.item) do n = n + 1 end
    if n > 0 then ns.print(("%d objet(s) avec des règles propres."):format(n)) end
  elseif sub == "regle" or sub == "règle" then
    -- /ahl vendre regle [objet <id> | cat <classID>] <clé> <valeur>
    local scope, target = "default", nil
    local word, after = args:match("^(%S+)%s+(.*)$")
    if word == "objet" or word == "cat" then
      -- un lien d'objet colle son nom (avec des espaces) : l'identifiant est dans « item:123 », la suite après « |h|r »
      local t, tail = after:match("item:(%d+)"), after:match("|h|r%s+(.*)$")
      if not (t and tail) then t, tail = after:match("^(%d+)%s+(.*)$") end
      if not t then ns.print("Syntaxe : /ahl vendre regle " .. word .. " <" .. (word == "objet" and "lien ou id" or "classID") .. "> <clé> <valeur>") return end
      scope, target, args = word == "objet" and "item" or "cat", tonumber(t), tail
    end
    local key, val = args:match("^(%S+)%s+(.+)$")
    local k = key and KEY_ALIAS[key:lower()]
    if not k then
      ns.print("Clés : undercut (1c ou 2%), plancher (70%), marge, profit, plafond (1.2), pile, piles, duree (12/24/48), sous (garder/pnj/attendre), fixe (plancher fixé), prix (prix fixé), farm (coût de farm : 1, 0.5, 0 = ignoré). « off » retire la règle.")
      return
    end
    local value, clear = parseValue(k, val)
    if value == nil and not clear then ns.print("Valeur illisible : " .. val) return end
    local ok, err = Sell.SetRule(scope, target, k, value)
    if ok then ns.print("Règle enregistrée. " .. (scope == "default" and describe(Sell.Rules(0)) or "")) else ns.print(err) end
  elseif sub == "prix" then
    -- /ahl vendre prix <lien ou id> <prix> : prix fixé pour cet objet (« off » pour l'enlever)
    local t, tail = args:match("item:(%d+)"), args:match("|h|r%s+(.*)$")
    if not (t and tail) then t, tail = args:match("^(%d+)%s+(.*)$") end
    if not t then ns.print("Syntaxe : /ahl vendre prix <lien ou id de l'objet> <prix, ex. 5g 20s> | off") return end
    Sell.Command("regle objet " .. t .. " prix " .. tail)
  elseif sub == "undercuts" then
    local list = Sell.Undercuts()
    if #list == 0 then ns.print("Aucune de tes enchères n'est battue (d'après le dernier scan).") return end
    for _, g in ipairs(list) do
      local name = (AHLedgerDB.items[g.id] and AHLedgerDB.items[g.id].n) or ("#" .. g.id)
      ns.print(("%s ×%d à %s : %s — %s"):format(name, g.qty, ns.money(g.unit), g.status,
        g.newPrice and ("nouveau prix " .. ns.money(g.newPrice)) or ("moins cher " .. ns.money(g.low))))
    end
  else
    ns.print("/ahl vendre [file] | regles | regle [objet <id>|cat <n>] <clé> <valeur> | prix <objet> <prix> | undercuts")
  end
end
