-- AHLedger - Une seule décision par objet : que faire de ce que tu as, à quel prix, combien, et
-- sur quelles preuves. Les sacs, l'infobulle, les pastilles, l'vue « Sacs et banque » et le rapport
-- lisent tous cette décision : un seul avis, le même partout.
--
-- Les preuves, de la plus sûre à la moins sûre (chaque raison affichée dit d'où elle vient) :
--   courrier     tes courriers d'HV des 30 derniers jours : ce que TU as vendu ou vu expirer
--   scans        les scans AHLedger : enchères parties bien avant la fin de leur durée (ventes sûres),
--                expirées, retirées alors qu'une moins chère restait (annulations, pas des ventes)
--   scan         le dernier scan : enchère la moins chère en vente, quantité devant toi
--   Auctionator  les minimums des jours passés (prix plancher habituel)
--   jeu          le prix de rachat du marchand (certain)
-- Sans preuve qu'un objet se vend, on ne conseille ni de le fabriquer, ni de le garder pour plus tard.
local _, ns = ...

local Decide = {}
ns.Decide = Decide

Decide.MIN_OBS_HOURS = 12       -- heures de scans comparables avant de juger un marché
Decide.SELLS_RATE = 1           -- ventes sûres par jour pour dire « se vend »…
Decide.SELLS_DAYS = 2           -- …vues au moins 2 jours différents sur 7
Decide.NO_SALE_HOURS = 24       -- aucune vente en 24 h de scans : ne se vend pas
Decide.OWN_MIN = 3              -- tes unités (vendues + expirées) mini pour trancher…
Decide.OWN_NO_EXPIRED = 2       -- …et au moins 2 mises en vente expirées pour dire « ne se vend pas »
Decide.HEAVY_STOCK_DAYS = 7     -- plus de 7 jours de ventes déjà en rayon : ta pile attendra
Decide.STALE_HOURS = 6          -- dernier scan plus vieux : prix à revérifier
Decide.DUMP_DAY_SHARE = 0.25    -- le prix plancher part en moins d'un quart de journée…
Decide.DUMP_GAP = 0.10          -- …et le niveau suivant est 10 % plus haut : on vise sous le suivant
Decide.LOW_VS_USUAL = 0.75      -- prix de vente sous 75 % du minimum habituel : attendre
Decide.HIGH_VS_USUAL = 1.5      -- au-dessus de 150 % : le signaler (ça peut redescendre vite)
Decide.SUSPECT_VS_USUAL = 3     -- au-dessus de 3× : prix douteux (scan partiel, une seule enchère
                                -- chère) : 1 seule mise en vente pour voir, rien n'est compté comme sûr
Decide.VENDOR_EDGE = 1.10       -- l'HV doit rapporter au moins 10 % de plus que le marchand
Decide.SLOW_VENDOR_SHARE = 0.5  -- marché lent : le marchand gagne s'il paie la moitié de l'HV
Decide.TEST_RATIO = 3           -- marché inconnu : tester à l'HV seulement si elle promet 3× le marchand
Decide.CRAFT_MIN_GAIN = 0.25    -- fabriquer : au moins 25 % de plus par composant…
Decide.CRAFT_MIN_TOTAL = 500    -- …et au moins 5 pa de plus en tout (sinon ça ne vaut pas le temps de fabriquer)
Decide.CRAFT_DAYS = 2           -- on ne fabrique pas plus que ce que l'HV absorbe en 2 jours
Decide.MIN_VALUE = 100          -- moins de 1 pa en tout : pas de ligne dans « Mes objets »
Decide.CRAFT_MARGIN = 0.15      -- objet que tu fabriques : rentable = coût des composants + 15 % net
local GEAR = { [2] = true, [4] = true } -- armes, armures : chaque pièce est un marché à part
local DEFAULT_P = { yes = 0.67, slow = 0.4, unknown = 0.5, no = 0.1 } -- chance qu'une mise en vente parte

-- Couleur de chaque décision (pastilles des sacs, infobulle, tableau). Garder et Attendre : pas de pastille.
Decide.COLORS = { HV = { 0.25, 1, 0.25 }, Tester = { 1, 0.82, 0 }, PNJ = { 1, 0.31, 0.31 },
                  Fabriquer = { 1, 0.6, 0 }, Attendre = { 0.4, 0.8, 1 }, Garder = { 0.4, 0.8, 1 } }
Decide.MARKS = { HV = true, Tester = true, PNJ = true, Fabriquer = true }

local function money(c) return ns.money(c) end
local function rate(v)
  if not v then return "?" end
  if v >= 10 then return ("%.0f"):format(v) end
  return (("%.1f"):format(v):gsub("%.0$", ""))
end

-- Rachat par le marchand /u : mémorisé, sinon demandé au jeu
function Decide.VendorPrice(id)
  local meta = AHLedgerDB.items[id]
  local v = meta and meta.s
  if not v and ns.GetItemInfo then v = select(11, ns.GetItemInfo(id)) end
  return (v and v > 0) and v or 0
end

-- Tes ventes réelles, recalculées quand les données changent (courrier lu, scan)
local ownCache, ownVer
local function own(id)
  if ownVer ~= ns.dataVersion or not ownCache then ownCache, ownVer = ns.Analysis.RealSales(), ns.dataVersion end
  return ownCache[id]
end

-- Tes enchères en cours sur cet objet : { [prix/u] = quantité }, total
local function mine(id)
  local data = ns.Prof.Char().auctions
  if not data then return nil end
  local by, total = nil, 0
  for _, a in ipairs(data.list or {}) do
    if a.id == id and not a.sold and a.unit and (not a.left or data.t + a.left > time()) then
      by = by or {}
      local u = math.floor(a.unit + 0.5)
      by[u] = (by[u] or 0) + a.qty
      total = total + a.qty
    end
  end
  return by, total
end

-- Ventes sûres par jour, seulement si elles viennent des scans 0.9 (12 h au moins) ; nil sinon
local function trustedRate(s)
  return s and (s.obs9Hours or 0) >= Decide.MIN_OBS_HOURS and s.surePerDay or nil
end
Decide.TrustedRate = trustedRate

-- Est-ce que ça se vend ? { v = "yes" | "slow" | "no" | "unknown", why, src, rate = ventes/j, p = chance
-- qu'une mise en vente parte, own = jugé sur tes courriers }
function Decide.Sells(id, s)
  s = s or ns.Analysis.Get(id)
  local o = own(id)
  local meta = AHLedgerDB.items[id]
  local r
  if o and o.sold + o.expired >= Decide.OWN_MIN then
    local st = o.sold / (o.sold + o.expired)
    r = { own = true, src = "courrier", p = math.max(st, 0.05),
          why = ("tes ventes %d j : %d vendus, %d expirés"):format(ns.Ledger.DAYS, o.sold, o.expired) }
    r.v = (o.sold == 0 and "no") or (st >= 0.5 and "yes") or "slow"
    -- une seule pile expirée ne prouve rien (prix trop haut ce jour-là ?) ; et si le marché vend
    -- clairement, tes expirations disent « vends au plancher, pas plus », pas « ne se vend pas »
    local tr = trustedRate(s)
    local marketSells = tr and tr >= Decide.SELLS_RATE and (s.salesDays or 0) >= Decide.SELLS_DAYS
    if r.v == "no" and ((o.expiredN or Decide.OWN_NO_EXPIRED) < Decide.OWN_NO_EXPIRED or marketSells) then
      r.v = "slow"
      if marketSells then r.why = r.why .. (", alors que l'HV en vend ~%s/j"):format(rate(tr)) end
    end
  elseif not s then
    r = { v = "unknown", src = "scans", why = "jamais vu en vente à l'HV" }
  elseif s.obsHours < Decide.MIN_OBS_HOURS then
    r = { v = "unknown", src = "scans", why = ("%.0f h de scans seulement"):format(s.obsHours) }
  else
    local sure, days = s.soldSure or 0, s.salesDays or 0
    r = { src = (s.obs9Hours or 0) >= Decide.MIN_OBS_HOURS and "scans" or "anciens scans" }
    if sure < 0.5 and (s.perDay or 0) < 0.5 and s.obsHours >= Decide.NO_SALE_HOURS then
      r.v, r.why = "no", ("aucune vente en %.0f h de scans"):format(s.obsHours)
    elseif sure < 0.5 then
      r.v, r.why = "unknown", ("disparitions incertaines seulement (%.0f h de scans)"):format(s.obsHours)
    else
      if r.src == "scans" then
        r.why = ("~%s ventes sûres/j, vues %d j sur 7"):format(rate(s.surePerDay), days)
      else
        -- avant la 0.9, une enchère retirée comptait comme vendue : chiffre surestimé, on le dit
        r.why = ("~%s disparitions/j (retraits compris), vues %d j sur 7"):format(rate(s.surePerDay), days)
      end
      r.v = ((s.surePerDay or 0) >= Decide.SELLS_RATE and days >= Decide.SELLS_DAYS) and "yes" or "slow"
      -- anciens scans vus un seul jour : ces « disparitions » peuvent n'être que des retraits,
      -- rien ne prouve que ça se vend. Pas de prix HV affirmé : une mise en vente pour voir.
      if r.src == "anciens scans" and days < Decide.SELLS_DAYS then
        r.v, r.weak = "unknown", true
        r.why = r.why .. " seulement : ventes pas prouvées"
        r.p = DEFAULT_P.slow -- pas plus de chances de vente qu'un marché lent
      end
    end
    -- l'écoulement d'anciens scans vus un seul jour compte aussi les retraits : on ne s'y fie pas
    if s.stReliable and not r.weak then
      r.p = math.max(s.sellThrough, 0.05)
      r.why = r.why .. (", %.0f %% des enchères partent"):format(s.sellThrough * 100)
    end
  end
  r.rate = s and s.surePerDay
  if o and not r.own and o.sold + o.expired > 0 then
    r.why = r.why .. (" (toi : %d vendus, %d expirés)"):format(o.sold, o.expired)
  end
  -- beaucoup de stock déjà en vente : ta pile passera après
  if r.v == "yes" and s and s.stockDays and s.stockDays > Decide.HEAVY_STOCK_DAYS then
    r.v = "slow"
    r.why = r.why .. (", mais %.0f j de ventes déjà en rayon"):format(s.stockDays)
  end
  -- équipement : d'autres pièces se vendent, ça ne dit pas que la tienne partira
  if r.v == "yes" and not r.own and GEAR[(s and s.class) or (meta and meta.c)] then
    r.v = "slow"
    r.why = r.why .. ", équipement : pas prouvé pour ta pièce"
  end
  r.p = r.p or DEFAULT_P[r.v]
  return r
end

Decide.EQ_NEAR = 0.10           -- moins chère à moins de 10 % sous l'équilibre : prix normal, 1c dessous
Decide.DUMP_DAYS = 1            -- bradées qui partent en moins d'un jour de ventes : on passe derrière

-- Surveillance de l'objet par un robot ou un joueur (Undercut.Stats), par objet, une fois par version
local watchCache, watchVer = {}, nil
local function watch(id)
  if watchVer ~= ns.dataVersion then
    watchCache, watchVer = {}, ns.dataVersion
    if ns.Undercut then
      local ok, rows = pcall(ns.Undercut.Stats)
      for _, e in ipairs(ok and rows or {}) do watchCache[e.id] = e end
    end
  end
  return watchCache[id]
end

-- « 12 h-16 h »
local function slotText(k)
  local h = ns.Undercut and ns.Undercut.SLOT_HOURS or 4
  return ("%d h-%d h"):format(k * h, k * h + h)
end

-- Prix de mise en vente /u. Retourne prix, raison, prix plancher vu (la moins chère des autres),
-- info = { eq, eqSrc, ahead (unités des autres moins chères que ce prix), dump, bigDump, watch }.
--  * Par défaut : 1c sous l'enchère la moins chère qui n'est pas à toi. Si ce plancher est une petite
--    quantité qui partira vite et que le niveau suivant est nettement plus haut : juste sous le suivant.
--  * Prix d'équilibre connu (Market) et la moins chère bien en dessous (bradée) : si ces bradées partent
--    en moins d'un jour de ventes, on vise juste sous le premier prix normal, sans dépasser l'équilibre ;
--    sinon 1c sous la moins chère, et compute décide (attendre, PNJ) : on ne suit pas un bradage.
--  * Objet surveillé (sous-cotes rapides, robot probable) : pas de course au centime, on se met à
--    l'équilibre et on dit à quelle heure personne n'a réagi vite.
function Decide.PostPrice(id, s, sellRate)
  local db = ns.realmDB()
  local book = db.book and ns.Scan.UnpackBook(db.book[id])
  local levels = {}
  local myBy = mine(id)
  for _, l in ipairs(book and book.levels or {}) do
    local q = l[2] - (myBy and myBy[l[1]] or 0)
    if q > 0 then levels[#levels + 1] = { l[1], q } end
  end
  local eq, eqSrc
  if ns.Market then eq, eqSrc = ns.Market.Equilibrium(id) end
  local info = { eq = eq, eqSrc = eqSrc, ahead = 0 }
  local first = levels[1]
  if not first then
    if s and s.minNow and not myBy then return math.max(s.minNow - 1, 1), "1c sous la moins chère", s.minNow, info end
    return nil
  end
  local post, why = math.max(first[1] - 1, 1), ("1c sous la moins chère (%s)"):format(money(first[1]))
  local nx = levels[2]
  local floorEq = eq and eq * (1 - Decide.EQ_NEAR)
  if floorEq and first[1] < floorEq then
    -- bradage : combien d'unités sous le prix normal, et le premier niveau normal
    local dump, normal = 0, nil
    for _, l in ipairs(levels) do
      if l[1] < floorEq then dump = dump + l[2] elseif not normal then normal = l[1] end
    end
    info.dump = dump
    if sellRate and sellRate > 0 and dump <= sellRate * Decide.DUMP_DAYS then
      post = math.max(1, math.min(normal and normal - 1 or math.floor(eq), math.floor(eq)))
      why = ("les %d bradées dès %s partiront avant les tiennes (moins d'un jour de ventes) : vise %s, équilibre %s"):format(
        dump, money(first[1]), money(post), money(eq))
    else
      info.bigDump = true
      why = ("1c sous la moins chère (%s), bien sous son équilibre %s : %d bradées devant"):format(money(first[1]), money(eq), dump)
    end
  elseif nx and sellRate and sellRate > 0 and first[2] <= sellRate * Decide.DUMP_DAY_SHARE
    and nx[1] >= first[1] * (1 + Decide.DUMP_GAP) then
    post = nx[1] - 1
    why = ("sous %s : les %d à %s partiront avant les tiennes"):format(money(nx[1]), first[2], money(first[1]))
  end
  local w = watch(id)
  if eq and w and (w.verdict == "bot" or w.verdict == "watched") then
    info.watch = w
    post = math.floor(eq)
    local quiet = w.quiet and w.quiet[1]
    why = ("%s : pas de course au centime, mets-le à son équilibre %s%s ; sinon PNJ ou garde-le"):format(
      w.verdict == "bot" and "robot probable sur cet objet" or "objet surveillé (sous-cotes rapides)", money(eq),
      quiet and (" (poste vers %s : personne ne t'a sous-coté vite à cette heure)"):format(slotText(quiet)) or "")
  end
  for _, l in ipairs(levels) do
    if l[1] < post then info.ahead = info.ahead + l[2] end
  end
  return post, why, first[1], info
end

-- Le prix net /u : une seule formule pour tout l'addon (Analysis.NetAt)
local function netAH(post, s, vendor, p)
  return ns.Analysis.NetAt(post, s, vendor, p)
end

-- LA chance qu'une mise en vente à post parte (seule règle de l'addon). Dans l'ordre :
--   tes courriers (ce que TU as vendu ou vu expirer) ;
--   le journal du marché à ce prix (Market.Odds : enchères vues partir ou expirer à ce prix) ;
--   l'écoulement mesuré par les scans (tous prix confondus) ;
--   Midas, s'il est chargé ;
--   sinon la valeur par défaut de Sells.
-- Retourne chance, source (nil pour la valeur par défaut), nombre d'enchères qui la fondent.
function Decide.Odds(id, post, s, sells)
  sells = sells or Decide.Sells(id, s)
  if sells.own then return sells.p, "tes ventes" end
  local mo, src, n
  if post and ns.Market then mo, src, n = ns.Market.Odds(id, post) end
  if mo and src ~= "Midas" then return math.max(mo, 0.05), src, n end
  if s and s.stReliable and not sells.weak then return sells.p, "écoulement mesuré" end
  if mo then return math.max(mo, 0.05), src end
  return sells.p, nil
end

-- Prix de référence d'un objet : son prix d'équilibre (Market : ce à quoi il part vraiment), sinon son
-- plus bas habituel (Auctionator). Retourne prix, nom à afficher, source, unités vendues, jours.
function Decide.Ref(id, s)
  if ns.Market then
    local eq, src, units, days = ns.Market.Equilibrium(id)
    if eq then return eq, "son prix d'équilibre", src, units, days end
  end
  local usual, src, days = ns.Analysis.UsualMin(id, s)
  if usual then return usual, "son plus bas habituel", src, nil, days end
  return nil
end

-- Prix pour VALORISER un objet (farm, objet fabriqué, composant que tu as) : le prix de mise en vente,
-- sauf prix douteux (plus de 3× la référence : scan partiel, une seule enchère chère) ou personne n'en
-- vend : alors la référence (équilibre, sinon plus bas habituel). 2e retour : vrai si c'est la
-- référence ; 3e : son nom (« son prix d'équilibre »…).
function Decide.FairPost(id, s)
  s = s or ns.Analysis.Get(id)
  local post = Decide.PostPrice(id, s, trustedRate(s))
  local ref, refName = Decide.Ref(id, s)
  if ref and (not post or post > ref * Decide.SUSPECT_VS_USUAL) then return math.floor(ref), true, refName end
  return post, false
end

-- D'où vient la preuve qu'un objet se vend (colonne « Sûr ? ») ; un prix douteux n'est jamais « prouvé »
function Decide.Conf(sells, d)
  if d and d.suspect then return "à tester" end
  if not sells then return "à tester" end
  if sells.own and sells.v ~= "unknown" then return "prouvé" end
  if sells.v == "unknown" then return "à tester" end
  if sells.src == "scans" then return "prouvé" end
  return "à confirmer"
end

-- Ce que tu récoltes toi-même : cuir que tu dépèces, minerai si tu mines, plantes si tu cueilles,
-- et tout ce que tu as looté pendant tes sessions /ahl farm
local farmedCache, farmedVer
function Decide.Gathered(id)
  local P = ns.Prof
  if P and P.Related and P.Related()[id] == "dépeçage" then return true end
  local meta = AHLedgerDB.items[id]
  local sub = meta and meta.c == 7 and meta.sc
  if P and P.Skill and ((sub == 7 and P.Skill("mining")) or (sub == 9 and P.Skill("herbalism"))) then return true end
  if farmedVer ~= ns.dataVersion or not farmedCache then
    farmedCache, farmedVer = {}, ns.dataVersion
    for _, f in ipairs(ns.realmDB().farm or {}) do
      for lid in pairs(f.loot or {}) do farmedCache[lid] = true end
    end
  end
  return farmedCache[id] == true
end

-- Combien tu en as (sacs + banque)
local function ownedCount(id)
  local c = ns.Prof and ns.Prof.Char()
  if not (c and c.bags) then return 0 end
  return (c.bags[id] or 0) + (c.bank and c.bank[id] or 0)
end

-- Ce que te rapporterait une unité vendue brute, tout de suite : le meilleur entre le marchand et l'HV
-- (seulement si l'objet se vend, au prix « juste »). C'est ce que te coûte un composant que tu as déjà :
-- l'or auquel tu renonces en le fabriquant.
local rawCache, rawVer = {}, nil
function Decide.RawValue(id)
  if rawVer ~= ns.dataVersion then rawCache, rawVer = {}, ns.dataVersion end
  if rawCache[id] then return rawCache[id] end
  local vend = Decide.VendorPrice(id)
  local best = vend
  local s = ns.Analysis.Get(id)
  local sells = Decide.Sells(id, s)
  if sells.v == "yes" or sells.v == "slow" then
    local post = Decide.FairPost(id, s)
    local net = post and netAH(post, s, vend, (Decide.Odds(id, post, s, sells)))
    if net and net > best then best = net end
  end
  rawCache[id] = best
  return best
end

-- Coût /u de k unités d'un composant pour UNE fabrication. Ce que tu as déjà, ou que tu récoltes
-- toi-même, coûte ce qu'il te rapporterait vendu brut (au plus son prix d'achat) ; le reste, ce qu'il
-- faut payer (PNJ ou HV, en parcourant les enchères). Source : "toi", "PNJ" ou "HV".
local function reagentCost(rid, k)
  local buy, src = ns.Analysis.ReagentCost(rid, k)
  if ownedCount(rid) >= k or Decide.Gathered(rid) then
    local raw = Decide.RawValue(rid)
    if not buy or raw <= buy then return raw, "toi" end
  end
  return buy, src
end
Decide.ReagentCost = reagentCost

-- LE coût des composants d'une recette (seule formule de l'addon : Artisanat, Montée, infobulle,
-- décisions). r = { r = { [composant] = quantité }, m = fabriqués }. Retourne coût total d'une
-- fabrication (nil s'il manque un prix), nombre de prix manquants, vrai si des composants viennent de
-- l'HV, vrai si certains sont à toi. fixId/fixValue : ce composant-là compte fixValue /u (l'objet de tes
-- sacs dont on décide le sort, à ce que sa vente brute te rapporterait).
function Decide.RecipeCost(r, fixId, fixValue)
  local cost, missing, fromAH, own = 0, 0, false, false
  for rid, k in pairs(r and r.r or {}) do
    local c, src
    if rid == fixId then c, src = fixValue, "toi" else c, src = reagentCost(rid, k) end
    if c then
      cost = cost + c * k
      if src == "HV" then fromAH = true elseif src == "toi" then own = true end
    else
      missing = missing + 1
    end
  end
  return missing == 0 and cost or nil, missing, fromAH, own
end

-- Objet que tu fabriques : coût de fabrication /u (Decide.RecipeCost : tes propres composants à ce
-- qu'ils te rapporteraient bruts, les autres à leur prix d'achat) et prix de mise en vente /u à partir
-- duquel la vente rapporte, commission et dépôts perdus compris.
--   floor  = seuil : en dessous, tu vends à perte
--   target = prix rentable : le coût + CRAFT_MARGIN net dans ta poche
-- nil si aucune de tes recettes ne le fabrique ou si un composant n'a pas de prix.
function Decide.CraftCost(id, s, sells)
  if not (ns.Prof and ns.Prof.Recipes) then return nil end
  -- cuir que tu dépèces : une recette qui en fabrique (4 légers → 1 moyen) ne dit pas ce qu'il t'a coûté
  if ns.Prof.SKINNING and ns.Prof.SKINNING[id] then return nil end
  local best
  for prof, list in pairs(ns.Prof.Recipes() or {}) do
    local r = list[id]
    if r and r.r then
      local cost, _, fromAH, own = Decide.RecipeCost(r)
      if cost then
        local unit = cost / (r.m or 1)
        if not best or unit < best.unit then best = { unit = unit, prof = prof, fromAH = fromAH, own = own } end
      end
    end
  end
  if not best or best.unit <= 0 then return nil end
  s = s or ns.Analysis.Get(id)
  sells = sells or Decide.Sells(id, s)
  local p = math.max(sells.p or DEFAULT_P[sells.v] or DEFAULT_P.unknown, 0.1)
  local _, deposit = netAH(0, s, Decide.VendorPrice(id), p)
  local keep = 1 - ns.Analysis.AH_CUT
  best.loss = deposit * (1 - p) / p -- dépôts perdus par vente (mises en vente qui expirent)
  best.floor = math.ceil((best.unit + best.loss) / keep)
  best.target = math.ceil((best.unit * (1 + Decide.CRAFT_MARGIN) + best.loss) / keep)
  return best
end

-- Ce que rapporte la vente d'un objet fabriqué à post /u, une fois le coût de fabrication payé
local function craftMargin(cc, post)
  return post * (1 - ns.Analysis.AH_CUT) - cc.loss - cc.unit
end

-- Valeur sûre d'un objet fabriqué : HV seulement s'il se vend vraiment (au prix « juste » : un prix
-- douteux ne fait pas fabriquer), sinon le marchand
local function outValue(outId)
  local so = ns.Analysis.Get(outId)
  local vend = Decide.VendorPrice(outId)
  local best = vend > 0 and { unit = vend, to = "PNJ", why = "rachat PNJ " .. money(vend) } or nil
  local sells = Decide.Sells(outId, so)
  if sells.v == "yes" and (sells.own or sells.src == "scans") then
    local post, refUsed, refName = Decide.FairPost(outId, so)
    if post then
      local net = netAH(post, so, vend, (Decide.Odds(outId, post, so, sells)))
      if not best or net > best.unit * Decide.VENDOR_EDGE then
        best = { unit = net, to = "HV", post = post, rate = sells.rate, src = sells.src,
                 why = sells.why .. (refUsed and (" (%s %s : le prix du jour est douteux)"):format(refName, money(post)) or "") }
      end
    end
  end
  return best, sells
end
Decide.OutValue = outValue

-- Matière brute ou fabriqué (1.0 phase 3), LE verdict d'une recette (Artisanat, Conseils, Mes objets) :
-- « vendre les composants bruts rapporte X, fabriquer puis vendre rapporte Y ».
--   raw  (X) = chaque composant à ce qu'il te rapporterait vendu brut (Decide.RawValue) ;
--   craft (Y) = l'objet fabriqué à sa valeur sûre × la quantité fabriquée (Decide.OutValue : l'HV
--               seulement s'il s'y vend vraiment, sinon le rachat du marchand) ;
--   cost = Decide.RecipeCost : tes composants à leur valeur brute (= X), ceux qu'il faut acheter à
--          leur prix d'achat.
-- base = ce que tu laisses en fabriquant : le plus haut entre X et le coût (des composants qu'on
-- achète moins cher qu'ils ne se revendent rapportent plus revendus tels quels). gain = Y − base.
-- ok : on conseille de fabriquer seulement si Y bat la base d'au moins CRAFT_MARGIN et que l'objet
-- fabriqué se vend (HV prouvée, ou un marchand le rachète). r = { r = { [composant] = qté }, m }.
-- fixId/fixValue : ce composant compte fixValue /u, brut comme coût (Mes objets : ce que te rapporterait
-- la décision pour cet objet de tes sacs).
function Decide.RawOrCraft(outId, r, fixId, fixValue)
  local raw = 0
  for rid, k in pairs(r and r.r or {}) do raw = raw + (rid == fixId and fixValue or Decide.RawValue(rid)) * k end
  local cost, missing, fromAH, own = Decide.RecipeCost(r, fixId, fixValue)
  local ov, sells = Decide.OutValue(outId)
  local made = r and r.m or 1
  local e = { raw = raw, craft = ov and ov.unit * made or 0, cost = cost, missing = missing, fromAH = fromAH,
              own = own, to = ov and ov.to, ov = ov, sells = sells, made = made }
  if cost then
    e.base = math.max(cost, raw)
    e.gain = e.craft - e.base
    e.ok = ov ~= nil and e.gain > 0 and e.gain >= e.base * Decide.CRAFT_MARGIN
  end
  return e
end

-- Prix de revient /u de ce que tu as (1.0 phase 3), n unités (sacs, banque, enchères en cours) :
--   achetées (HV ou marchand) = le prix payé, le plus ancien achat parti d'abord ;
--   fabriquées (relevées) = leurs composants à leur propre prix de revient ;
--   le reste (farmé, looté, ou d'avant les relevés) = ce qu'il vaudrait vendu brut (Decide.RawValue).
-- Retourne { unit, n, bought, boughtUnit, crafted, craftUnit, farmed, farmUnit, known, knownUnit } ou nil.
function Decide.UnitCost(id, n)
  n = n or 0
  if n <= 0 then return nil end
  local b = ns.Tracker and ns.Tracker.CostBasis()[id]
  local c = { n = n, bought = 0, crafted = 0 }
  if b then
    -- plus d'unités relevées que tu n'en as (les autres sont parties) : les plus récentes restent
    c.bought = math.min(b.bought, n)
    c.crafted = math.min(b.crafted, n - c.bought)
    c.boughtUnit = b.bought > 0 and b.boughtCost / b.bought or nil
    c.craftUnit = b.crafted > 0 and b.craftCost / b.crafted or nil
  end
  c.farmed = n - c.bought - c.crafted
  c.farmUnit = Decide.RawValue(id)
  c.known = c.bought + c.crafted
  local knownCost = c.bought * (c.boughtUnit or 0) + c.crafted * (c.craftUnit or 0)
  c.knownUnit = c.known > 0 and knownCost / c.known or nil
  c.unit = (knownCost + c.farmed * c.farmUnit) / n
  return c
end

-- « 1s 20c/u : 3 achetés 1s 50c, 2 fabriqués 80c, 5 farmés (valeur brute 1s) »
function Decide.UnitCostText(c)
  if not c then return nil end
  local parts = {}
  if c.bought > 0 then parts[#parts + 1] = ("%d acheté%s %s"):format(c.bought, c.bought > 1 and "s" or "", money(c.boughtUnit)) end
  if c.crafted > 0 then parts[#parts + 1] = ("%d fabriqué%s %s"):format(c.crafted, c.crafted > 1 and "s" or "", money(c.craftUnit)) end
  if c.farmed > 0 then
    parts[#parts + 1] = ("%d farmé%s (valeur brute %s)"):format(c.farmed, c.farmed > 1 and "s" or "", money(c.farmUnit))
  end
  return ("%s/u : %s"):format(money(c.unit), table.concat(parts, ", "))
end

-- Meilleure recette connue qui transforme n unités de id pour plus que raw /u (vente brute décidée)
local function craftUp(id, n, raw)
  if not ns.Prof then return nil end
  local best
  for prof, list in pairs(ns.Prof.Recipes() or {}) do
    for outId, r in pairs(list) do
      local q = r.r and r.r[id]
      if q and outId ~= id and n >= q then
        local others, ok = 0, true
        for rid, k in pairs(r.r) do
          if rid ~= id then
            local c = reagentCost(rid, k)
            if not c then ok = false; break end
            others = others + c * k
          end
        end
        local made = r.m or 1
        -- une seule règle pour fabriquer : le verdict de la recette (matière brute ou fabriqué)
        local rc = ok and Decide.RawOrCraft(outId, r, id, raw)
        local ov = rc and rc.ok and rc.ov
        if ov then
          local perUnit = (ov.unit * made - others) / q
          local gain = perUnit - raw
          local crafts = math.floor(n / q)
          if ov.to == "HV" then crafts = math.min(crafts, math.max(1, math.floor((ov.rate or 0) * Decide.CRAFT_DAYS / made))) end
          local total = gain * q * crafts
          if gain > 0 and gain >= raw * Decide.CRAFT_MIN_GAIN and total >= Decide.CRAFT_MIN_TOTAL
            and (not best or total > best.total) then
            local meta = AHLedgerDB.items[outId]
            best = { out = outId, name = r.n or (meta and meta.n) or ("#" .. outId), prof = prof, q = q, made = made,
                     crafts = crafts, used = crafts * q, others = others, perUnit = perUnit, raw = raw, gain = gain,
                     total = total, to = ov.to, post = ov.post, why = ov.why, src = ov.src }
          end
        end
      end
    end
  end
  return best
end

local function compute(id, n)
  local A = ns.Analysis
  local s = A.Get(id)
  local vendor = Decide.VendorPrice(id)
  local sells = Decide.Sells(id, s)
  local d = { id = id, n = n, s = s, vendor = vendor, sells = sells, facts = {}, warn = {} }
  local function fact(src, text) d.facts[#d.facts + 1] = { src, text } end

  local post, postWhy, _, pinfo = Decide.PostPrice(id, s, trustedRate(s))
  local usual, usualSrc, usualDays = A.UsualMin(id, s)
  -- référence des prix « bradé », « douteux », « haut » : l'équilibre (ce à quoi il part vraiment),
  -- sinon le plus bas habituel
  local ref, refName, refSrc, refUnits, refDays = Decide.Ref(id, s)
  if not post and ref and sells.v ~= "no" then
    post, postWhy = math.floor(ref), ("personne n'en vend en ce moment : vise %s"):format(refName)
  end
  if not post and vendor <= 0 then return nil end -- ni HV ni PNJ : rien à conseiller

  local p, pSrc, pN = Decide.Odds(id, post, s, sells)
  local ahNet = post and netAH(post, s, vendor, p)
  d.post, d.ahNet, d.p = post, ahNet, p

  local function npc(why) d.action, d.unit, d.qty, d.reason = "PNJ", vendor, n, why end
  local function ah(action, qty, why) d.action, d.unit, d.qty, d.reason = action, ahNet, math.min(qty, n), why end

  if not post then
    npc("aucun prix HV : personne n'en vend en ce moment et pas de plus bas habituel connu")
  elseif sells.v == "no" then
    if vendor > 0 then npc("ne se vend pas à l'HV")
    else d.action, d.unit, d.qty, d.reason = "Garder", 0, n, "ne se vend pas à l'HV et le marchand ne le rachète pas" end
  elseif ahNet <= vendor * Decide.VENDOR_EDGE then
    npc(("à %s/u l'HV te laisse %s (commission et dépôts perdus déduits), le marchand paie %s tout de suite"):format(
      money(post), ahNet > 0 and money(ahNet) or "rien", money(vendor)))
  elseif sells.v == "unknown" then
    if vendor <= 0 or ahNet >= vendor * Decide.TEST_RATIO then
      ah("Tester", 1, "marché encore inconnu : une mise en vente le dira")
    else
      npc(("marché inconnu, l'HV (%s net) ne promet pas assez plus que le marchand"):format(money(ahNet)))
    end
  elseif sells.v == "slow" then
    if vendor > 0 and vendor >= ahNet * Decide.SLOW_VENDOR_SHARE then
      npc(("se vend lentement : le marchand paie %s tout de suite, l'HV %s un jour peut-être"):format(money(vendor), money(ahNet)))
    else
      ah("HV", math.max(1, math.floor((sells.rate or 0) * 2)), "se vend lentement : peu à la fois")
    end
  else
    -- environ une journée de ventes à la fois : le reste attendrait derrière les autres et expirerait
    ah("HV", math.max(1, math.ceil(sells.rate or n)), "se vend")
  end

  -- prix très bas aujourd'hui par rapport à la référence : attendre plutôt que brader
  if (d.action == "HV" or d.action == "Tester") and ref then
    if post < ref * Decide.LOW_VS_USUAL and ref * (1 - A.AH_CUT) > vendor * Decide.VENDOR_EDGE then
      d.action, d.qty = "Attendre", 0
      d.reason = ("HV bradé : %s/u, %s est %s"):format(money(post), refName, money(ref))
        .. (pinfo and pinfo.dump and pinfo.dump > 0 and (" (%d bradées devant toi)"):format(pinfo.dump) or "")
        .. (vendor > 0 and (" ; ou PNJ %s/u maintenant"):format(money(vendor)) or "")
    elseif post > ref * Decide.SUSPECT_VS_USUAL then
      d.action, d.qty, d.suspect = "Tester", math.min(1, n), true
      d.reason = ("prix douteux : %s/u, %.0f× %s (%s) ; rescanne, ou mets-en 1 pour voir"):format(
        money(post), post / ref, refName, money(ref))
    elseif post > ref * Decide.HIGH_VS_USUAL then
      d.warn[#d.warn + 1] = ("prix %.0f %% au-dessus de %s (%s) : vends tant qu'il tient"):format(
        (post / ref - 1) * 100, refName, money(ref))
    end
  end

  -- objet que tu fabriques : vendre seulement à un prix qui rembourse la fabrication. Sous le seuil,
  -- garder en banque si d'habitude il part plus cher ; sinon le dire (composants déjà dépensés :
  -- garder ne rapportera pas plus, mais la recette perd de l'or à ces prix)
  local cc = Decide.CraftCost(id, s, sells)
  d.cost = cc
  if cc and post and (d.action == "HV" or d.action == "Tester" or d.action == "Attendre") then
    local m = craftMargin(cc, post)
    d.margin = m
    if post < cc.floor and d.action ~= "Attendre" and not d.suspect then
      if ref and ref >= cc.floor then
        d.action, d.qty = "Attendre", 0
        d.reason = ("à %s/u tu vends à perte (fabrication %s/u) ; %s est %s"):format(
          money(post), money(cc.unit), refName, money(ref))
      else
        d.warn[#d.warn + 1] = ("à %s/u tu perds %s/u sur la fabrication (%s/u)%s : n'en fabrique plus à ces prix"):format(
          money(post), money(-m), money(cc.unit),
          ref and (", et à %s (%s) aussi"):format(refName, money(ref)) or ", pas assez d'historique pour savoir s'il remonte")
      end
    elseif post >= cc.floor and post < cc.target and d.action ~= "Attendre" then
      d.warn[#d.warn + 1] = ("marge faible : +%s/u à %s ; rentable à partir de %s/u"):format(money(m), money(post), money(cc.target))
    end
    if d.action == "Attendre" and ref and ref >= cc.floor then
      d.hold = true
      d.holdAt = ref >= cc.target and cc.target or cc.floor
    end
  end

  -- transformer plutôt que vendre brut : seulement vers un objet qui se vend vraiment
  local raw = d.action == "Attendre" and math.max(vendor, 0) or (d.unit or 0)
  local up = craftUp(id, n, raw)
  if up then
    d.alt = { action = d.action, unit = d.unit, qty = d.qty, reason = d.reason, post = d.post }
    d.craft = up
    d.hold, d.holdAt = nil, nil -- « Garder en banque » ne vaut plus : on le transforme
    d.action, d.unit, d.qty = "Fabriquer", up.perUnit, up.used
    d.reason = ("%s rapporte %s/u au lieu de %s"):format(up.name, money(up.perUnit), money(raw))
  end

  -- ce que tu en as acheté ou fabriqué : vendre sous son prix de revient se dit (la décision ne change
  -- pas : l'or payé est déjà dépensé, garder ne le rendra pas)
  local basis = Decide.UnitCost(id, ownedCount(id) + (select(2, mine(id)) or 0))
  d.basis = basis
  if basis and basis.known > 0 and d.unit and (d.action == "HV" or d.action == "Tester")
    and d.unit < basis.knownUnit then
    d.warn[#d.warn + 1] = ("à %s/u net, tu vends sous son prix de revient (%s/u) : %s/u de perte"):format(
      money(d.unit), money(basis.knownUnit), money(basis.knownUnit - d.unit))
  end

  -- projection de la mise en vente conseillée : en combien de temps elle part, ses chances, sa durée
  if post and (d.action == "HV" or d.action == "Tester") and ns.Market then
    local hours, hSrc = ns.Market.Hours(id, post, d.qty, s, pinfo and pinfo.ahead)
    d.proj = { odds = pSrc and p or nil, oddsSrc = pSrc, oddsN = pN, hours = hours, hoursSrc = hSrc,
               dur = ns.Market.Duration(hours) }
  end

  -- preuves, avec leur source
  fact(sells.src, sells.why)
  if ref and refSrc and refName == "son prix d'équilibre" and d.action ~= "PNJ" then
    fact(refSrc, refUnits and ("équilibre %s/u (%d vendus en %d j)"):format(money(ref), refUnits, refDays)
      or ("équilibre %s/u"):format(money(ref)))
  end
  if post and d.action ~= "PNJ" then
    local scanAge = ns.realmDB().lastScanTime and (time() - ns.realmDB().lastScanTime) / 3600
    fact(scanAge and ("scan il y a %s"):format(scanAge < 1 and "<1 h" or ("%.0f h"):format(scanAge)) or "scan", postWhy)
    if scanAge and scanAge > Decide.STALE_HOURS then
      d.warn[#d.warn + 1] = ("dernier scan il y a %.0f h : rescanne avant de mettre en vente"):format(scanAge)
    end
  end
  if usual and d.action ~= "PNJ" then fact(usualSrc, ("plus bas habituel %s (%d j)"):format(money(usual), usualDays)) end
  if vendor > 0 and d.action ~= "PNJ" then fact("jeu", "PNJ " .. money(vendor)) end
  if d.craft then fact(d.craft.src or "jeu", (d.craft.to == "HV" and "objet fabriqué : " or "") .. d.craft.why) end
  local _, listed = mine(id)
  if listed and listed > 0 then fact("tes enchères", ("%d déjà en vente"):format(listed)) end

  d.value = (d.unit or 0) * ((d.action == "Fabriquer" or d.suspect) and d.qty or n)
  if d.action == "Fabriquer" and d.alt then d.value = d.value + (d.alt.unit or 0) * (n - d.qty) end
  return d
end

local cache, cacheVer = {}, nil
-- Décision pour n unités de l'objet id (n = 1 : pour un objet que tu n'as pas). nil : rien à conseiller.
function Decide.For(id, n)
  if not id then return nil end
  n = math.max(n or 1, 1)
  if cacheVer ~= ns.dataVersion then cache, cacheVer = {}, ns.dataVersion end
  local key = id * 10000 + math.min(n, 9999)
  local d = cache[key]
  if d == nil then
    d = compute(id, n) or false
    cache[key] = d
  end
  return d or nil
end

-- La décision est-elle déjà calculée (pour cette version des données) ? Ne calcule rien.
function Decide.Ready(id, n)
  if not id then return true end
  if cacheVer ~= ns.dataVersion then return false end
  return cache[id * 10000 + math.min(math.max(n or 1, 1), 9999)] ~= nil
end

-- « Vendre à l'HV : 5 sur 20 à 4s39/u »
local function qtyText(q, n)
  if q >= n then return n > 1 and ("les %d"):format(n) or "" end
  return ("%d sur %d"):format(q, n)
end
local function lineFor(action, d, qty, post, unit)
  local n = d.n
  if action == "HV" then
    local q = qtyText(qty, n)
    return ("Vendre à l'HV%s à %s/u"):format(q ~= "" and (" : " .. q) or "", money(post))
  elseif action == "Tester" then
    return ("Tester à l'HV : %s à %s/u"):format(qty >= n and n > 1 and ("les %d"):format(n) or tostring(qty), money(post))
  elseif action == "PNJ" then
    return ("Vendre au PNJ : %s/u%s"):format(money(unit), n > 1 and (" (%s)"):format(money(unit * n)) or "")
  elseif action == "Attendre" and d.hold then
    return ("Garder en banque : vends à partir de %s/u"):format(money(d.holdAt))
  elseif action == "Attendre" then
    return "Attendre : ne brade pas aujourd'hui"
  elseif action == "Garder" then
    return "Garder : ni l'HV ni le marchand n'en veulent"
  end
  return action
end

function Decide.Line(d)
  if d.action == "Fabriquer" then
    local c = d.craft
    return ("Fabriquer %d × %s%s"):format(c.crafts, c.name, c.to == "HV" and (" (vendre %s/u)"):format(money(c.post)) or " (pour le PNJ)")
  end
  return lineFor(d.action, d, d.qty, d.post, d.unit)
end

-- Ce que tu ferais sans la fabrication
function Decide.AltLine(d)
  local a = d.alt
  if not a then return nil end
  return lineFor(a.action, d, a.qty, a.post, a.unit)
end

-- Objet que tu fabriques : « Rentable dès X/u (fabrication Y/u, à perte sous Z) · à P : +M/u (+N %) »
-- et sa couleur (vert : rentable au prix de vente ; jaune : marge faible ; rouge : à perte). nil sinon.
Decide.COST_COLORS = { ok = { 0.25, 1, 0.25 }, thin = { 1, 0.82, 0 }, loss = { 1, 0.31, 0.31 } }
function Decide.CostLine(d)
  local cc = d and d.cost
  if not cc then return nil end
  local head = ("Rentable dès %s/u (fabrication %s/u, à perte sous %s)"):format(money(cc.target), money(cc.unit), money(cc.floor))
  if d.action == "PNJ" then
    local state = d.vendor >= cc.unit * (1 + Decide.CRAFT_MARGIN) and "ok" or d.vendor >= cc.unit and "thin" or "loss"
    local word = { ok = "rentable", thin = "marge faible", loss = "à perte" }
    return head .. (" · PNJ %s/u : %s"):format(money(d.vendor), word[state]), state
  end
  if not (d.post and d.margin) then return head, "thin" end
  local m = d.margin
  local state = d.post >= cc.target and "ok" or d.post >= cc.floor and "thin" or "loss"
  return head .. (" · à %s : %s%s/u (%s%.0f %%)"):format(money(d.post), m >= 0 and "+" or "-", money(math.abs(m)),
    m >= 0 and "+" or "-", math.abs(m) / cc.unit * 100), state
end

-- « raison · source : preuve · source : preuve » (maxFacts : les plus importantes d'abord ; noCost :
-- sans la ligne de rentabilité, quand l'appelant l'affiche à part)
function Decide.Why(d, sep, maxFacts, noCost)
  sep = sep or " · "
  local parts = { d.reason }
  local proj = ns.Market and ns.Market.Text(d.proj)
  if proj then parts[#parts + 1] = proj end
  local cost = not noCost and Decide.CostLine(d)
  if cost then parts[#parts + 1] = cost end
  for i, f in ipairs(d.facts) do
    if maxFacts and i > maxFacts then break end
    parts[#parts + 1] = f[1] .. " : " .. f[2]
  end
  return table.concat(parts, sep)
end
