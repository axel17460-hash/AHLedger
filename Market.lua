-- AHLedger - Marché : prix d'équilibre, chances de vente et délai d'une mise en vente (1.0, phase 2)
--
-- Prix d'équilibre : le prix auquel l'objet part VRAIMENT. Médiane, sur 7 jours, du prix moyen des
-- enchères vendues chaque jour (pondérée par les unités vendues), d'après les scans AHLedger : un jour
-- de soldes ou une grosse pile vendue cher ne la déplace pas. Pas assez de ventes vues : le prix juste
-- de Midas s'il est chargé, sinon rien (Decide garde alors ses anciens repères).
--
-- Journal des enchères (db.sales[id]) : à chaque scan comparé au précédent, chaque enchère disparue
-- dont on est sûr du sort (vendue bien avant la fin de sa durée, ou expirée) est notée avec son prix
-- unitaire, sa quantité et le temps passé en rayon. Il dit, pour un prix donné :
--   - la chance qu'une enchère à ce prix parte (ventes vues à ce prix ou plus cher, contre
--     expirations vues à ce prix ou moins cher) ;
--   - en combien de temps elle part (médiane du temps en rayon des ventes à ce prix ou plus cher).
-- Format compact : "t,prix,unités,o,heures;…" (o = s vendue, e expirée ; heures × 10, vide si inconnu).
local _, ns = ...

local Market = {}
ns.Market = Market

Market.EQ_DAYS = 7          -- fenêtre du prix d'équilibre
Market.EQ_MIN_DAYS = 2      -- jours avec des ventes sûres, au moins
Market.EQ_MIN_UNITS = 3     -- unités vendues sûres, au moins
Market.EQ_LOW, Market.EQ_HIGH = 0.4, 1.5 -- équilibre gardé entre 0,4 et 1,5 fois le prix affiché du jour
Market.LOG_DAYS = 14        -- le journal garde 14 jours
Market.LOG_MAX = 40         -- et au plus 40 enchères par objet (les plus récentes)
Market.NEAR = 0.15          -- « à ce prix » : à 15 % près
Market.ODDS_MIN = 5         -- enchères au sort connu avant de croire à une chance de vente
Market.HOURS_MIN = 3        -- ventes au temps en rayon connu avant de croire à un délai
Market.DURATIONS = { 12, 24, 48 } -- durées de mise en vente proposées par le jeu (heures)

local function money(c) return ns.money(c) end

-- Médiane pondérée de { {valeur, poids}, … }
local function weightedMedian(pts)
  table.sort(pts, function(a, b) return a[1] < b[1] end)
  local total = 0
  for _, p in ipairs(pts) do total = total + p[2] end
  local acc = 0
  for _, p in ipairs(pts) do
    acc = acc + p[2]
    if acc >= total / 2 then return p[1] end
  end
  return pts[#pts] and pts[#pts][1]
end
Market.WeightedMedian = weightedMedian

local function median(list)
  if #list == 0 then return nil end
  table.sort(list)
  local m = (#list + 1) / 2
  return (list[math.floor(m)] + list[math.ceil(m)]) / 2
end

-------------------------------------------------------------------------------
-- Prix d'équilibre
-------------------------------------------------------------------------------
local eqCache, eqVer = {}, nil

-- Prix d'équilibre /u de id. Retourne prix, source ("tes scans" ou "Midas"), unités vendues, jours.
-- nil si ni les scans ni Midas n'en savent assez.
function Market.Equilibrium(id)
  if not id then return nil end
  if eqVer ~= ns.dataVersion then eqCache, eqVer = {}, ns.dataVersion end
  local c = eqCache[id]
  if c == nil then
    c = false
    local db = ns.realmDB()
    local h = db.hist and db.hist[id]
    local today = ns.History.today()
    local pts, units, days = {}, 0, 0
    if h then
      for d = today - Market.EQ_DAYS + 1, today do
        local r = ns.History.parse(h[d])
        local dr = db.days and db.days[d]
        -- jours observés de bout en bout en 0.9 seulement (même règle qu'Analysis) : avant, une
        -- enchère retirée comptait comme vendue
        if r and r.v9 and r.sold >= 1 and r.soldVal > 0 and dr and (dr.obs or 0) > 0 and (dr.o9 or 0) >= dr.obs then
          pts[#pts + 1] = { r.soldVal / r.sold, r.sold }
          units, days = units + r.sold, days + 1
        end
      end
    end
    local eq = days >= Market.EQ_MIN_DAYS and units >= Market.EQ_MIN_UNITS and math.floor(weightedMedian(pts) + 0.5) or nil
    -- mêmes bornes que le prix réel d'Analysis : loin du prix affiché (pile bradée vite rachetée,
    -- retraits pris pour des ventes), ce n'est pas le prix auquel TU vendras
    local s = ns.Analysis.Get(id)
    local lp = s and s.listPrice
    local function near(v) return not lp or (v >= Market.EQ_LOW * lp and v <= Market.EQ_HIGH * lp) end
    if eq and not near(eq) then eq = nil end
    if eq then
      c = { eq, "tes scans", units, days }
    else
      -- le prix juste de Midas passe par les mêmes bornes
      local fair = ns.MidasLink and ns.MidasLink.Fair(id)
      if fair and near(fair) then c = { fair, "Midas" } end
    end
    eqCache[id] = c
  end
  if not c then return nil end
  return c[1], c[2], c[3], c[4]
end

-------------------------------------------------------------------------------
-- Journal des enchères au sort connu
-------------------------------------------------------------------------------
local function parseLog(str)
  local out = {}
  for t, unit, n, o, life in (str or ""):gmatch("(%d+),(%d+),(%d+),([se]),(%d*);?") do
    out[#out + 1] = { t = tonumber(t), unit = tonumber(unit), n = tonumber(n), sold = o == "s",
                      life = life ~= "" and tonumber(life) / 10 or nil }
  end
  return out
end

local function packLog(list)
  local parts = {}
  for i, e in ipairs(list) do
    parts[i] = ("%d,%d,%d,%s,%s"):format(e.t, e.unit, e.n, e.sold and "s" or "e", e.life and tostring(math.floor(e.life * 10 + 0.5)) or "")
  end
  return table.concat(parts, ";")
end

local logCache, logVer = {}, nil
-- Les enchères du journal de moins de LOG_DAYS jours (les plus vieilles restent écrites jusqu'au
-- prochain événement de l'objet, mais ne comptent plus)
function Market.Log(id)
  if logVer ~= ns.dataVersion then logCache, logVer = {}, ns.dataVersion end
  local l = logCache[id]
  if not l then
    local db = ns.realmDB()
    local since = time() - Market.LOG_DAYS * 86400
    l = {}
    for _, e in ipairs(parseLog(db.sales and db.sales[id])) do
      if e.t >= since then l[#l + 1] = e end
    end
    logCache[id] = l
  end
  return l
end

-- Ajoute les enchères au sort connu d'un scan : events = { {sold=bool, unit, n, life (h) ou nil}, … }
function Market.Record(db, id, events, now)
  if not (events and #events > 0) then return end
  db.sales = db.sales or {}
  local list = parseLog(db.sales[id])
  local since = now - Market.LOG_DAYS * 86400
  local kept = {}
  for _, e in ipairs(list) do if e.t >= since then kept[#kept + 1] = e end end
  for _, e in ipairs(events) do
    if e.unit and e.unit > 0 and e.n and e.n > 0 then
      kept[#kept + 1] = { t = now, unit = e.unit, n = math.floor(e.n + 0.5), sold = e.sold, life = e.life }
    end
  end
  while #kept > Market.LOG_MAX do table.remove(kept, 1) end
  db.sales[id] = #kept > 0 and packLog(kept) or nil
  logCache[id] = nil
end

-- Oublie les objets dont le journal n'a plus rien de récent (appelé après chaque scan)
function Market.Prune(db, now)
  if not db.sales then return end
  local since = now - Market.LOG_DAYS * 86400
  for id, str in pairs(db.sales) do
    local newest = 0
    for t in str:gmatch("(%d+),%d+,%d+,[se],%d*") do newest = math.max(newest, tonumber(t)) end
    if newest < since then db.sales[id] = nil end
  end
end

-------------------------------------------------------------------------------
-- Chance de vente et délai à un prix donné
-------------------------------------------------------------------------------
-- Chance qu'une enchère à price parte. Une vente vue au moins aussi cher (à NEAR près) dit que ce prix
-- passe ; une expiration vue au plus aussi cher dit qu'il ne passe pas. Retourne chance, source,
-- nombre d'enchères qui fondent le chiffre ; nil si trop peu de preuves (Midas en second recours).
function Market.Odds(id, price)
  if not (id and price and price > 0) then return nil end
  local sold, exp = 0, 0
  for _, e in ipairs(Market.Log(id)) do
    if e.sold and e.unit >= price / (1 + Market.NEAR) then sold = sold + 1
    elseif not e.sold and e.unit <= price * (1 + Market.NEAR) then exp = exp + 1 end
  end
  if sold + exp >= Market.ODDS_MIN then
    return sold / (sold + exp), "tes scans", sold + exp
  end
  local m = ns.MidasLink and ns.MidasLink.Odds(id, price)
  if m then return m, "Midas" end
  return nil
end

-- En combien d'heures qty unités postées à price partent. ahead = unités moins chères déjà en vente
-- (elles partent avant). Médiane du temps en rayon des ventes vues à ce prix ou plus cher ; sinon,
-- d'après le débit : (ahead + qty) ÷ ventes sûres par jour. Retourne heures, source ; nil sans débit.
function Market.Hours(id, price, qty, s, ahead)
  local lives = {}
  for _, e in ipairs(Market.Log(id)) do
    if e.sold and e.life and price and e.unit >= price / (1 + Market.NEAR) then lives[#lives + 1] = e.life end
  end
  local rate = s and s.surePerDay
  if #lives >= Market.HOURS_MIN then
    local h = median(lives)
    -- plusieurs unités : il faut aussi que le marché les absorbe
    if rate and rate > 0 and qty and qty > 1 then h = math.max(h, 24 * ((ahead or 0) + qty) / rate) end
    return h, "tes scans"
  end
  if rate and rate > 0 then
    return 24 * ((ahead or 0) + (qty or 1)) / rate, "débit"
  end
  return nil
end

-- Durée de mise en vente : la plus courte qui couvre le délai prévu (le dépôt grandit avec la durée)
function Market.Duration(hours)
  if not hours then return Market.DURATIONS[#Market.DURATIONS] end
  for _, d in ipairs(Market.DURATIONS) do
    if hours * 1.5 <= d then return d end
  end
  return Market.DURATIONS[#Market.DURATIONS]
end

-- « part en ~6 h, 80 % de chances » (texte d'une projection)
function Market.Text(p)
  if not p then return nil end
  local parts = {}
  if p.hours then
    -- peu de chances : le délai ne vaut que pour les fois où elle part, on le dit
    local longest = Market.DURATIONS[#Market.DURATIONS]
    local head = p.odds and p.odds < 0.5 and "si elle part, c'est " or "part "
    if p.hours > longest then
      -- plus long que la plus longue mise en vente : elle expirera sans doute avant
      parts[#parts + 1] = ("~%.0f j pour partir, plus qu'une mise en vente de %d h : risque d'expirer, mets-en moins"):format(
        p.hours / 24, longest)
    else
      parts[#parts + 1] = head .. (p.hours < 1 and "en moins d'1 h" or ("en ~%.0f h"):format(p.hours))
    end
  end
  if p.odds then
    parts[#parts + 1] = ("%.0f %% de chances%s"):format(p.odds * 100,
      p.oddsN and (" (%d enchères vues à ce prix)"):format(p.oddsN)
      or p.oddsSrc == "Midas" and (" (Midas, pour une mise en vente de %d h)"):format(Market.DURATIONS[#Market.DURATIONS])
      or p.oddsSrc and (" (%s)"):format(p.oddsSrc) or "")
  end
  if p.dur then parts[#parts + 1] = ("mets-la %d h"):format(p.dur) end
  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

-- Pour l'infobulle et le rapport : « équilibre 4s 20c (32 vendus en 6 j) »
function Market.EqText(id)
  local eq, src, units, days = Market.Equilibrium(id)
  if not eq then return nil end
  if src == "Midas" then return ("équilibre %s (Midas)"):format(money(eq)) end
  return ("équilibre %s (%d vendus en %d j)"):format(money(eq), units, days)
end
