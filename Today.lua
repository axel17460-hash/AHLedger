-- AHLedger - Aujourd'hui : plan de séance. « J'ai 30 minutes et 40 po, je fais quoi ? »
--
-- Rassemble les conseils que l'addon calcule déjà, sans refaire leurs calculs :
--   * ventes : file de mise en vente (Sell.Queue), enchères battues à reposter (Sell.Undercuts),
--     objets de la banque à poster au-dessus du prix habituel (Opp.Undercuts), vente au PNJ (Bags.Advice) ;
--   * flips HV (Analysis.Flips) et achats PNJ → HV (Analysis.VendorFlips) ;
--   * artisanat : recettes connues rentables (Analysis.Crafts) et composants des sacs à transformer
--     (conseil « Fabriquer » de Bags.Advise / Analysis.CraftUp) ;
--   * farm : meilleure zone de tes sessions /ahl farm (Analysis.FarmZones).
-- Chaque action : gain attendu, temps, or immobilisé, fiabilité (Trust.Check au prix visé, et taux de
-- réussite du type de conseil d'après Track), raison.
--
-- Modèle de classement (glouton documenté) :
--   1. Gain incrémental, homogène pour toutes les actions (en cuivre, par rapport à « ne rien faire de plus ») :
--      * vente d'un objet possédé (file, banque) : unités × (p × (net − prix PNJ) − (1 − p) × dépôt). Le prix PNJ
--        est l'alternative sûre (vendre au marchand) : poster ne rapporte que ce qui la dépasse. Un invendu
--        revient au courrier et vaut encore son prix PNJ : seul son dépôt est perdu ;
--      * p (chance de vendre pendant l'enchère) : même modèle que les reposts de Sell.lua, vitesse de vente
--        (s.perDay, vendus/j) contre ce qu'il faut écouler, unités moins chères devant nous comprises :
--        p = min(1, durée en jours ÷ ((devant + unités) ÷ vendus/j)) ; vendus/j inconnu : UNKNOWN_SELL_P.
--        Prix « à tester » (Trust.Check) : p × TEST_WEIGHT. La durée vient de Sell.Quote (12/24/48 h) ;
--      * repost (Sell.Undercuts) : gain déjà pondéré par les chances de vendre (Sell.RepostGain), pris tel quel ;
--      * flip HV, achat PNJ → HV, artisanat : bénéfice net déjà calculé par Analysis (commission et dépôts
--        perdus déduits) ; vente au PNJ des sacs : prix PNJ, certain ; farm : or/h relevé.
--   2. Poids de fiabilité : 1 pour les gains déjà pondérés par une probabilité (ventes, reposts) ; pour les
--      autres, TEST_WEIGHT si le conseil est « à tester ». On écarte les conseils non fiables : prix non tenu
--      (Trust.Check = « bad ») ou type de conseil qui échoue trop souvent (Track : au moins TRACK_MIN_CHECKED
--      vérifiés et moins de TRACK_BAD_RATE réussis). Jamais la vente au PNJ : son gain est certain, même si
--      Track juge mal le conseil « Sacs : vendre au PNJ » (l'HV aurait pu payer mieux, pas moins).
--   3. Score = gain × poids ÷ (minutes ÷ T + or immobilisé ÷ G), T et G = temps et or de la séance : une action
--      est jugée sur la part des deux ressources qu'elle consomme. Avec beaucoup d'or, c'est le gain/minute ;
--      avec peu d'or, un flip qui bloque presque tout l'or passe derrière une action peu coûteuse. Une action
--      divisible est notée à la taille qui tient dans T et G. L'or immobilisé comprend les dépôts des mises
--      en vente (dépôt à l'unité de Sell.DepositPerUnit : il ne dépend pas encore de la durée 12/24/48 h).
--   4. On prend les actions par score décroissant tant qu'il reste du temps et de l'or, une seule par objet
--      (la mieux classée qui tient) : file de vente, repost, flip, achat PNJ et artisanat d'un même objet se
--      partagent les mêmes acheteurs, on ne les additionne pas. Une action divisible (achat PNJ, artisanat,
--      farm) qui ne tient pas entière est réduite à ce qui tient ; une action indivisible (flip, mise en
--      vente groupée) qui ne tient pas est sautée.
--   Le glouton par ratio est optimal quand tout est divisible, proche de l'optimum sinon : assez bon pour
--   des actions petites devant la séance, et lisible (« pourquoi celle-ci avant celle-là »).
--   L'or des ventes n'est pas compté comme disponible pendant la séance (il arrive plus tard au courrier ;
--   même la vente au PNJ, payée tout de suite, n'est pas réinvestie : on reste prudent).
--   Un objet des sacs conseillé « PNJ » ou « Fabriquer » n'est jamais proposé à l'HV (onglet Sous-coter).
--
-- Aucune automatisation : le plan dit quoi faire, chaque achat ou mise en vente reste un clic du joueur.
-- Rien ici ne dépend de l'interface (onglet dans UI.lua) : la logique reste testable hors jeu.
local _, ns = ...

local Today = {}
ns.Today = Today

-- Hypothèses de temps par action, en minutes (à ajuster après un essai en jeu)
Today.POST_MIN = 0.25          -- une mise en vente (un clic sur « Poster suivant ») : ~15 s
Today.REPOST_MIN = 0.5         -- annuler puis reposter une enchère battue
Today.BANK_MIN = 3             -- aller à la banque et en revenir
Today.FLIP_MIN = 2             -- chercher l'objet, acheter les enchères, reposter
Today.VENDOR_TRAVEL_MIN = 5    -- aller chez le marchand, acheter, revenir à l'HV
Today.VENDOR_SELL_MIN = 2      -- vendre ses sacs au PNJ le plus proche
Today.CRAFT_SETUP_MIN = 3      -- acheter les composants, ouvrir le métier
Today.CRAFT_EACH_MIN = 0.05    -- une fabrication (~3 s)
Today.FARM_MIN_BLOCK = 15      -- on ne propose pas de farmer moins de 15 min
Today.FARM_MAX_BLOCK = 60      -- ni plus d'une heure d'affilée dans la même zone
Today.FARM_MIN_HOURS = 0.25    -- au moins 15 min de sessions relevées dans la zone
Today.FARM_OK_HOURS = 2        -- moins de 2 h relevées : rendement « à tester »

-- Fiabilité
Today.TEST_WEIGHT = 0.5        -- un conseil « à tester » compte pour la moitié de son gain dans le classement
Today.UNKNOWN_SELL_P = 0.5     -- chance de vendre quand les vendus/j sont inconnus
Today.TRACK_MIN_CHECKED = 5    -- conseils vérifiés d'un type avant de juger ce type
Today.TRACK_BAD_RATE = 0.34    -- moins d'un tiers de réussis : type de conseil écarté
Today.TRACK_OK_RATE = 0.6      -- au moins 60 % de réussis : le type ne rend pas le conseil « à tester »

Today.CHOICES = { 15, 30, 60, 120 }
Today.DEFAULT_MINUTES = 60

local function cut() return ns.Analysis and ns.Analysis.AH_CUT or 0.05 end
local function plain(s) return (tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local function g(c) return plain(ns.money(c)) end
local function nameOf(id, s)
  local meta = AHLedgerDB.items and AHLedgerDB.items[id]
  return plain((s and s.name) or (meta and meta.n) or ("#" .. tostring(id)))
end

------------------------------------------------------------------------
-- Fiabilité : Trust (le prix visé est-il tenu ?) + Track (ce type de conseil marche-t-il ?)
------------------------------------------------------------------------

-- Taux de réussite par type de conseil (Track.GROUPS) : { [clé] = { checked, rate } }
function Today.TrackRates()
  local by = {}
  if not (ns.Track and ns.Track.Summary) then return by end
  local ok, rows = pcall(ns.Track.Summary)
  if not ok or not rows then return by end
  for _, r in ipairs(rows) do by[r.key] = r end
  return by
end

-- Verdict combiné : "ok" | "test" | "bad", et la raison
function Today.Reliability(s, price, group, rates)
  local level, why = "ok", nil
  if s and price and ns.Trust then
    level, why = ns.Trust.Check(s, price)
    if level == "bad" then return "bad", why end
  end
  local r = group and rates and rates[group]
  if r and r.checked >= Today.TRACK_MIN_CHECKED and r.rate then
    if r.rate < Today.TRACK_BAD_RATE then
      return "bad", ("%s : %.0f %% réussis sur %d vérifiés"):format(r.label, r.rate * 100, r.checked)
    end
    if r.rate < Today.TRACK_OK_RATE and level == "ok" then
      level, why = "test", ("%s : %.0f %% réussis"):format(r.label, r.rate * 100)
    end
  end
  if level == "ok" then why = why or "fiable" end
  return level, why
end

------------------------------------------------------------------------
-- Gain d'une vente : chance de vendre, dépôt, alternative PNJ
------------------------------------------------------------------------

local function vendorPrice(id)
  local meta = AHLedgerDB.items and AHLedgerDB.items[id]
  return meta and meta.s or 0
end

local function depositPerUnit(id, s)
  if ns.Sell and ns.Sell.DepositPerUnit then return ns.Sell.DepositPerUnit(id) or 0 end
  return s and s.deposit or 0
end

-- Équipement (armes, armures) : une mise en vente par exemplaire
local function oneByOne(id)
  local meta = AHLedgerDB.items and AHLedgerDB.items[id]
  return meta and (meta.c == 2 or meta.c == 4) or false
end

-- Chance d'écouler `units` pendant `hours` heures, avec `ahead` unités moins chères devant (voir l'en-tête)
function Today.SellProb(s, units, hours, ahead)
  local perDay = s and s.perDay
  if not (perDay and perDay > 0) then return Today.UNKNOWN_SELL_P end
  local need = ((ahead or 0) + math.max(units or 1, 1)) / perDay
  if need <= 0 then return 1 end
  return math.min(1, (hours or 24) / 24 / need)
end

-- Gain incrémental de la mise en vente de `units` objets possédés à `price`/u :
-- units × (p × (net − prix PNJ) − (1 − p) × dépôt) : un invendu revient au courrier et garde sa
-- valeur PNJ, seul le dépôt est perdu. Renvoie gain, p, dépôt/u, prix PNJ/u.
function Today.SaleGain(id, s, units, price, hours, ahead, trust)
  local p = Today.SellProb(s, units, hours, ahead)
  if trust == "test" then p = p * Today.TEST_WEIGHT end
  local net = price * (1 - cut())
  local dep = depositPerUnit(id, s)
  local vend = vendorPrice(id)
  return units * (p * (net - vend) - (1 - p) * dep), p, dep, vend
end

------------------------------------------------------------------------
-- Candidats : une action par conseil existant
------------------------------------------------------------------------
-- Action : { kind, id, text, gain, minutes, gold, trust, trustWhy, why, group, weighted (gain déjà pondéré),
--            divisible = { unitGain, unitGold, unitMin, fixedMin, qty, minQty } (réductible), label(q) }

local function add(list, a)
  if a and a.gain and a.gain > 0 and a.minutes and a.minutes > 0 then list[#list + 1] = a end
end

-- Plus grande quantité d'une action divisible qui tient dans le temps et l'or donnés (0 si rien)
local function fitQty(d, timeLeft, goldLeft)
  local q = d.qty
  if d.unitMin > 0 then q = math.min(q, math.floor((timeLeft - d.fixedMin) / d.unitMin + 1e-9)) end
  if d.unitGold > 0 then q = math.min(q, math.floor(goldLeft / d.unitGold + 1e-9)) end
  if d.fixedMin > timeLeft + 1e-9 then q = 0 end
  return math.max(q, 0)
end

-- Poids, or/minute et score d'une action pour une séance de T minutes et G cuivre (voir l'en-tête)
function Today.Score(a, T, G)
  a.weight = (a.weighted or a.trust ~= "test") and 1 or Today.TEST_WEIGHT
  a.gpm = a.gain / a.minutes
  local gain, minutes, gold = a.gain, a.minutes, a.gold
  local d = a.divisible
  if d then
    -- notée à la taille qui tient dans la séance (un gros achat PNJ n'est pas puni pour sa quantité maximale)
    local q = fitQty(d, T, G)
    if q >= (d.minQty or 1) and q < d.qty then
      gain, gold, minutes = d.unitGain * q, d.unitGold * q, d.fixedMin + d.unitMin * q
    end
  end
  local use = minutes / math.max(T, 1e-9)
  if gold > 0 then use = use + (G > 0 and gold / G or math.huge) end
  a.score = use > 0 and gain * a.weight / use or 0
  return a.score
end

-- Ventes : la file de mise en vente (une ligne par objet ; plusieurs piles s'il y en a plusieurs à poster)
local function sellActions(ctx)
  for _, e in ipairs(ns.Sell.Queue()) do
    if not e.blocked and e.price then
      ctx.inQueue[e.id] = true
      local posts = math.max(1, math.ceil(e.planned / math.max(e.qty, 1)))
      local units = math.min(e.planned, posts * e.qty)
      local trust, tw = Today.Reliability(e.s, e.price, "bagAH", ctx.rates)
      local ahead = e.q and e.q.ignored or 0 -- bradeurs ignorés pour le prix, mais achetés avant nous
      local gain, p, dep, vend = Today.SaleGain(e.id, e.s, units, e.price, e.duration, ahead, trust)
      local net = e.price * units * (1 - cut())
      add(ctx.out, { kind = "sell", id = e.id, s = e.s, gain = gain, p = p, units = units, weighted = true,
                     minutes = posts * Today.POST_MIN + (e.bank and Today.BANK_MIN or 0), gold = dep * units,
                     trust = trust, trustWhy = tw, group = "bagAH",
                     text = ("Poste %d pile%s de %s (×%d, %s/u)%s : ~%s net, %.0f %% de chances, +%s sur le PNJ"):format(
                       posts, posts > 1 and "s" or "", nameOf(e.id, e.s), e.qty, g(e.price),
                       e.bank and ", pris à la banque" or "", g(net), p * 100, g(gain)),
                     why = plain(e.reason) .. (vend > 0 and (" · PNJ %s/u"):format(g(vend)) or "") })
    end
  end
end

-- Enchères battues qui valent un repost : gain déjà pondéré par les chances de vendre (Sell.RepostGain)
local function repostActions(ctx)
  for _, u in ipairs(ns.Sell.Undercuts()) do
    if u.worth and u.gain and u.newPrice then
      local trust, tw = Today.Reliability(u.s, u.newPrice, nil, ctx.rates)
      add(ctx.out, { kind = "repost", id = u.id, s = u.s, gain = u.gain, minutes = u.n * Today.REPOST_MIN,
                     gold = depositPerUnit(u.id, u.s) * u.qty, trust = trust, trustWhy = tw, weighted = true,
                     text = ("Annule et reposte %s ×%d à %s/u : +%s attendus"):format(nameOf(u.id, u.s), u.qty,
                       g(u.newPrice), g(u.gain)),
                     why = ("battue de %+.0f %%"):format((u.gap or 0) * 100) })
    end
  end
end

-- Marchés au-dessus du prix habituel, pour ce que tu as (surtout en banque : les sacs sont déjà dans la file).
-- Un objet que le conseiller des sacs envoie au PNJ ou à l'établi n'est pas proposé à l'HV.
local function premiumActions(ctx)
  if not (ns.Opp and ns.Opp.Undercuts) then return end
  local c = ns.Prof.Char()
  for _, e in ipairs(ns.Opp.Undercuts()) do
    if (e.have or 0) > 0 and not ctx.inQueue[e.id] then
      local adv = ns.Bags.Advise(e.id, e.have)
      if not (adv and (adv.action == "PNJ" or adv.action == "Fabriquer")) then
        local qty = math.min(e.have, e.qty)
        local inBags = (c.bags or {})[e.id] or 0
        local trust, tw = Today.Reliability(e.s, e.post, "bagAH", ctx.rates)
        local q = ns.Sell.Quote and ns.Sell.Quote(e.id)
        local gain, p, dep = Today.SaleGain(e.id, e.s, qty, e.post, q and q.duration or 24, 0, trust)
        local net = e.post * qty * (1 - cut())
        add(ctx.out, { kind = "premium", id = e.id, s = e.s, gain = gain, p = p, units = qty, weighted = true,
                       minutes = Today.POST_MIN + (inBags >= qty and 0 or Today.BANK_MIN),
                       gold = dep * qty, trust = trust, trustWhy = tw, group = "bagAH",
                       text = ("Poste %d %s à %s/u (%s au-dessus de l'habituel)%s : ~%s net, %.0f %% de chances, +%s sur le PNJ"):format(
                         qty, nameOf(e.id, e.s), g(e.post), plain(ns.pct(e.premium)),
                         inBags >= qty and "" or ", pris à la banque", g(net), p * 100, g(gain)),
                       why = plain(e.notes) })
      end
    end
  end
end

-- Flips HV : achat groupé, indivisible (le bénéfice dépend des paliers achetés) ; le dépôt de la remise en
-- vente est compté dans l'or immobilisé
local function flipActions(ctx)
  for _, f in ipairs(ns.Analysis.Flips()) do
    local group = f.kind == "stock" and (f.known and "stock" or "stockTest") or "now"
    local trust, tw = Today.Reliability(f.s, f.resale, group, ctx.rates)
    local when = f.kind == "stock" and (", garde-les : " .. ns.Analysis.FlipWhen(f)) or ""
    add(ctx.out, { kind = "flip", id = f.id, s = f.s, gain = f.profit, minutes = Today.FLIP_MIN,
                   gold = f.cost + depositPerUnit(f.id, f.s) * f.qty,
                   trust = trust, trustWhy = tw, group = group,
                   text = ("Achète %d %s jusqu'à %s/u, revends à %s/u%s : ~%s"):format(f.qty, nameOf(f.id, f.s), g(f.maxBuy),
                     g(f.resale), when, g(f.profit)),
                   why = ("ROI %.0f %%, écoulé en ~%.1f j"):format(f.roi * 100, f.days or 0) })
  end
end

-- Temps de mise en vente à l'HV : une enchère par pile (règle « pile » de Sell), une par exemplaire pour
-- l'équipement. Renvoie (minutes fixes, minutes par unité vendue).
local function postTime(id)
  if oneByOne(id) then return 0, Today.POST_MIN end
  local r = ns.Sell and ns.Sell.Rules and ns.Sell.Rules(id) or {}
  if r.stackSize and r.stackSize > 0 then return 0, Today.POST_MIN / r.stackSize end
  return Today.POST_MIN, 0
end

-- Achats PNJ → HV : divisibles à l'unité ; trajet + mise en vente, prix d'achat + dépôt immobilisés
local function vendorActions(ctx)
  for _, e in ipairs(ns.Analysis.VendorFlips()) do
    local qty = e.reliable and math.max(1, math.ceil(e.vol or 1)) or (e.testQty or 1)
    if e.lim and e.lim > 0 then qty = math.min(qty, e.lim) end
    local group = e.reliable and "vendor" or "vendorTest"
    local trust, tw = Today.Reliability(e.s, e.s.price, group, ctx.rates)
    if not e.reliable and trust == "ok" then trust, tw = "test", e.why end
    local postFixed, postEach = postTime(e.id)
    local unitGold = e.buy + depositPerUnit(e.id, e.s)
    local fixed = Today.VENDOR_TRAVEL_MIN + postFixed
    add(ctx.out, { kind = "vendor", id = e.id, s = e.s, gain = e.margin * qty, minutes = fixed + postEach * qty,
                   gold = unitGold * qty, trust = trust, trustWhy = tw, group = group,
                   divisible = { qty = qty, unitGain = e.margin, unitGold = unitGold, unitMin = postEach,
                                 fixedMin = fixed },
                   label = function(q) return ("Achète %d %s chez %s (%s, %s/u), revends à l'HV %s/u : ~%s"):format(
                     q, nameOf(e.id, e.s), plain(e.npc or "?"), plain(e.zone or "?"), g(e.buy), g(e.s.price), g(e.margin * q)) end,
                   why = ("marge %s/u, %s vendus/j"):format(g(e.margin), e.perDay and ("%.0f"):format(e.perDay) or "?") })
  end
end

-- Artisanat : recettes connues rentables, et composants des sacs à transformer (une seule action par objet
-- fabriqué : la mieux notée, gain pondéré par la fiabilité). Revendu à l'HV : mise en vente et dépôt comptés.
local function craftActions(ctx)
  local best = {}
  local function keep(a)
    if not (a and a.gain and a.gain > 0 and a.minutes > 0) then return end
    Today.Score(a, ctx.T, ctx.G)
    local cur = best[a.id]
    if not cur or a.score > cur.score then best[a.id] = a end
  end
  -- (minutes fixes, minutes et or de dépôt par fabrication) pour vendre `made` objets fabriqués à l'HV
  local function hvCosts(id, s, made)
    local pf, pe = postTime(id)
    return pf, pe * made, depositPerUnit(id, s) * made
  end
  for _, e in ipairs(ns.Analysis.Crafts()) do
    if e.cost and (e.profit or 0) > 0 and not (e.sellTo == "HV" and e.slow) then
      local qty = math.max(1, math.ceil(e.vol or 1))
      local hv = e.sellTo == "HV"
      local group = hv and "craft" or nil
      local trust, tw = "ok", "revente au PNJ"
      if hv then trust, tw = Today.Reliability(e.s, e.post, group, ctx.rates) end
      local made = e.made or 1
      local pf, pe, dep = 0, 0, 0
      if hv then pf, pe, dep = hvCosts(e.id, e.s, made) end
      local fixed, each, unitGold = Today.CRAFT_SETUP_MIN + pf, Today.CRAFT_EACH_MIN + pe, e.cost + dep
      keep({ kind = "craft", id = e.id, s = e.s, gain = e.profit * qty,
             minutes = fixed + qty * each, gold = unitGold * qty,
             trust = trust, trustWhy = tw, group = group,
             divisible = { qty = qty, unitGain = e.profit, unitGold = unitGold, unitMin = each, fixedMin = fixed },
             label = function(q) return ("Crafte %s ×%d (%s), vends %s : ~%s"):format(nameOf(e.id, e.s), q * made,
               plain(ns.Prof.LABEL[e.prof] or e.prof), hv and "à l'HV" or "au PNJ", g(e.profit * q)) end,
             why = ("coût %s, bénéfice %s par fabrication"):format(g(e.cost), g(e.profit)) })
    end
  end
  -- conseil des sacs « Fabriquer » : tes propres composants valent plus transformés (recette déjà apprise)
  local c = ns.Prof.Char()
  for _, e in ipairs(ns.Bags.Advice()) do
    local up = e.action == "Fabriquer" and e.craftUp
    local have = (c.bags or {})[e.id] or 0
    if up and up.learned and have >= up.q then
      local crafts = math.floor(have / up.q)
      local made = up.made or 1
      local hv = up.sellTo == "HV"
      local trust, tw = "ok", "revente au PNJ"
      local pf, pe, dep = 0, 0, 0
      if hv then
        local so = ns.Analysis.Get(up.out)
        local sale = ns.Analysis.CraftSale(so)
        trust, tw = Today.Reliability(so, sale and sale.gross, "craft", ctx.rates)
        if up.unsure and trust == "ok" then trust, tw = "test", "aucune vente vue au prix de l'objet fabriqué" end
        pf, pe, dep = hvCosts(up.out, so, made)
      end
      local fixed, each, unitGold = Today.CRAFT_SETUP_MIN + pf, Today.CRAFT_EACH_MIN + pe, up.others + dep
      keep({ kind = "craft", id = up.out, gain = up.gain * up.q * crafts,
             minutes = fixed + crafts * each, gold = unitGold * crafts,
             trust = trust, trustWhy = tw, group = hv and "craft" or nil,
             divisible = { qty = crafts, unitGain = up.gain * up.q, unitGold = unitGold, unitMin = each, fixedMin = fixed },
             label = function(q) return ("Crafte %s ×%d avec tes %s, vends %s : +%s de plus que brut"):format(
               nameOf(up.out), q * made, nameOf(e.id, e.s), hv and "à l'HV" or "au PNJ",
               g(up.gain * up.q * q)) end,
             why = ("%s/u au lieu de %s"):format(g(up.perUnit), g(up.raw)) })
    end
  end
  for _, a in pairs(best) do add(ctx.out, a) end
end

-- Vente au PNJ des sacs (conseil « PNJ ») : une seule action groupée, payée tout de suite. Gain certain :
-- jamais écartée, même si Track juge mal ce type de conseil (il dit que l'HV aurait parfois payé plus).
local function vendorSaleAction(ctx)
  local c = ns.Prof.Char()
  local total, n, ids = 0, 0, {}
  for _, e in ipairs(ns.Bags.Advice()) do
    local have = (c.bags or {})[e.id] or 0
    if e.action == "PNJ" and have > 0 and (e.vendor or 0) > 0 then
      total, n = total + e.vendor * have, n + 1
      ids[#ids + 1] = e.id
    end
  end
  if n == 0 then return end
  local tw = "payé tout de suite"
  local r = ctx.rates.bagNPC
  if r and r.checked >= Today.TRACK_MIN_CHECKED and r.rate and r.rate < Today.TRACK_OK_RATE then
    tw = ("payé tout de suite (Track : l'HV a payé mieux %d fois sur %d)"):format(
      math.floor((1 - r.rate) * r.checked + 0.5), r.checked)
  end
  add(ctx.out, { kind = "npc", ids = ids, gain = total, minutes = Today.VENDOR_SELL_MIN, gold = 0,
                 trust = "ok", trustWhy = tw, group = "bagNPC",
                 text = ("Vends %d objet%s des sacs au PNJ : %s"):format(n, n > 1 and "s" or "", g(total)),
                 why = "l'HV ne paie pas mieux que le marchand" })
end

-- Farm : meilleure zone de tes sessions, divisible en minutes (pas d'id d'objet : rien à dédoublonner)
local function farmAction(ctx)
  local bestZ
  for _, z in ipairs(ns.Analysis.FarmZones()) do
    if z.hours >= Today.FARM_MIN_HOURS and z.total > 0 and (not bestZ or z.total > bestZ.total) then bestZ = z end
  end
  if not bestZ then return end
  local z = bestZ
  local perMin = z.total / 60
  local trust = z.hours >= Today.FARM_OK_HOURS and "ok" or "test"
  local tw = ("%.1f h relevées"):format(z.hours)
  add(ctx.out, { kind = "farm", bestItem = z.best, gain = perMin * Today.FARM_MAX_BLOCK, minutes = Today.FARM_MAX_BLOCK,
                 gold = 0, trust = trust, trustWhy = tw, farm = true,
                 divisible = { qty = Today.FARM_MAX_BLOCK, unitGain = perMin, unitGold = 0, unitMin = 1, fixedMin = 0,
                               minQty = Today.FARM_MIN_BLOCK },
                 label = function(q) return ("Farm %s %d min : ~%s/h, ~%s"):format(plain(z.zone), q, g(z.total), g(perMin * q)) end,
                 why = ("%d session%s, meilleur objet %s"):format(z.sessions, z.sessions > 1 and "s" or "",
                   z.best and nameOf(z.best) or "-") })
end

-- Tous les conseils candidats, fiables ou non (les « bad » sont marqués, pas encore écartés), notés pour une
-- séance de `minutes` minutes et `gold` cuivre (défauts : DEFAULT_MINUTES, ton or)
function Today.Candidates(minutes, gold)
  local T = tonumber(minutes) or Today.DEFAULT_MINUTES
  local G = tonumber(gold) or (ns.Analysis.Gold()) or 0
  local ctx = { out = {}, rates = Today.TrackRates(), inQueue = {}, T = T, G = G }
  local function try(label, fn)
    local ok, err = pcall(fn, ctx)
    if not ok then
      ns.errors[#ns.errors + 1] = "aujourd'hui/" .. label .. " : " .. tostring(err)
      if #ns.errors > 20 then table.remove(ns.errors, 1) end
    end
  end
  try("ventes", sellActions)
  try("reposts", repostActions)
  try("banque", premiumActions)
  try("flips", flipActions)
  try("achats PNJ", vendorActions)
  try("artisanat", craftActions)
  try("vente PNJ", vendorSaleAction)
  try("farm", farmAction)
  for _, a in ipairs(ctx.out) do
    if a.label and not a.text then a.text = a.label(a.divisible.qty) end
    Today.Score(a, T, G)
  end
  return ctx.out
end

------------------------------------------------------------------------
-- Plan : glouton par score, sous contrainte de temps et d'or, une action par objet
------------------------------------------------------------------------

-- Réduit une action divisible à ce qui tient dans le temps et l'or restants ; nil si rien ne tient
local function shrink(a, timeLeft, goldLeft)
  local d = a.divisible
  local q = fitQty(d, timeLeft, goldLeft)
  if q < (d.minQty or 1) then return nil end
  local b = {}
  for k, v in pairs(a) do b[k] = v end
  b.qty, b.shrunk = q, q < d.qty
  b.gain, b.gold, b.minutes = d.unitGain * q, d.unitGold * q, d.fixedMin + d.unitMin * q
  b.gpm = b.gain / b.minutes
  b.text = a.label(q)
  if b.minutes > timeLeft + 1e-9 or b.gold > goldLeft then return nil end
  return b
end

-- Today.Plan(minutes, orDisponible) → liste ordonnée d'actions, résumé
--   minutes : durée de la séance (défaut DEFAULT_MINUTES) ; orDisponible : en cuivre (défaut : ton or)
--   résumé = { gain, minutes, gold, minutesMax, goldMax, excluded (non fiables écartés), skipped (ne tiennent
--   pas), dup (autre action déjà retenue pour le même objet) }
-- Cache du plan : le calcul relance Sell.Queue, Flips, Crafts, Bags, Track et FarmZones ; on ne le refait
-- pas à chaque rafraîchissement de l'UI (molette, tri) tant que rien n'a bougé (données, or, farm) et au
-- plus une fois toutes les PLAN_TTL secondes (les sacs ne changent pas ns.dataVersion).
Today.PLAN_TTL = 5
local planCache = {}

function Today.Plan(minutes, gold)
  minutes = tonumber(minutes) or Today.DEFAULT_MINUTES
  gold = tonumber(gold) or (ns.Analysis.Gold()) or 0
  local key = table.concat({ minutes, gold, ns.dataVersion or 0, ns.Farm and ns.Farm.gen or 0 }, ":")
  local now = time()
  if planCache.key == key and now - planCache.t < Today.PLAN_TTL then return planCache.plan, planCache.sum end
  local plan, sum = Today.PlanUncached(minutes, gold)
  planCache.key, planCache.t, planCache.plan, planCache.sum = key, now, plan, sum
  return plan, sum
end

function Today.PlanUncached(minutes, gold)
  local cands = Today.Candidates(minutes, gold)
  local pool, excluded = {}, 0
  for _, a in ipairs(cands) do
    if a.trust == "bad" and a.kind ~= "npc" then excluded = excluded + 1 else pool[#pool + 1] = a end
  end
  table.sort(pool, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return (a.text or "") < (b.text or "")
  end)
  local plan, used = {}, {}
  local timeLeft, goldLeft, skipped, dup = minutes, gold, 0, 0
  for _, a in ipairs(pool) do
    local pick
    if a.id and used[a.id] then
      dup = dup + 1
    else
      if a.minutes <= timeLeft + 1e-9 and a.gold <= goldLeft then
        pick = a
      elseif a.divisible then
        pick = shrink(a, timeLeft, goldLeft)
      end
      if pick then
        plan[#plan + 1] = pick
        pick.order = #plan
        if pick.id then used[pick.id] = true end
        timeLeft, goldLeft = timeLeft - pick.minutes, goldLeft - pick.gold
      else
        skipped = skipped + 1
      end
    end
    if timeLeft < Today.POST_MIN then break end
  end
  local sum = { gain = 0, minutes = 0, gold = 0, minutesMax = minutes, goldMax = gold, excluded = excluded,
                skipped = skipped, dup = dup }
  for _, a in ipairs(plan) do
    sum.gain, sum.minutes, sum.gold = sum.gain + a.gain, sum.minutes + a.minutes, sum.gold + a.gold
  end
  return plan, sum
end

-- Une phrase de total : « 6 actions, ~4g 20s en 52 min, 12g immobilisés sur 40g »
function Today.TotalText(sum, n)
  local t = ("%d action%s, ~%s en %.0f/%d min, %s immobilisés sur %s"):format(n, n > 1 and "s" or "", g(sum.gain),
    sum.minutes, sum.minutesMax, g(sum.gold), g(sum.goldMax))
  if sum.excluded > 0 then t = t .. (" · %d conseil%s non fiable%s écarté%s"):format(sum.excluded,
    sum.excluded > 1 and "s" or "", sum.excluded > 1 and "s" or "", sum.excluded > 1 and "s" or "") end
  return t
end

Today.TRUST_LABEL = { ok = "fiable", test = "à tester" }

-- « <1 min », « 4 min »
function Today.MinText(m)
  if m < 1 then return "<1 min" end
  return ("%.0f min"):format(m)
end

-- Lignes texte (chat et rapport)
function Today.Lines(minutes, gold)
  local plan, sum = Today.Plan(minutes, gold)
  local out = {}
  for i, a in ipairs(plan) do
    local label = Today.TRUST_LABEL[a.trust] or a.trust
    local tw = a.trustWhy and a.trustWhy ~= label and (" (" .. plain(a.trustWhy) .. ")") or ""
    out[#out + 1] = ("%d. %s — %s, %s immobilisés, %s%s · %s"):format(i, a.text, Today.MinText(a.minutes), g(a.gold),
      label, tw, plain(a.why or ""))
  end
  return out, Today.TotalText(sum, #plan), plan, sum
end

-- /ahl aujourdhui [minutes]
function Today.Command(rest)
  local minutes = tonumber((rest or ""):match("(%d+)")) or Today.DEFAULT_MINUTES
  local lines, total = Today.Lines(minutes)
  ns.print(("Plan de séance (%d min) : %s"):format(minutes, total))
  if #lines == 0 then
    ns.print("  rien à proposer : scanne l'HV, ouvre tes sacs et tes métiers, ou fais une session /ahl farm.")
  end
  for _, l in ipairs(lines) do ns.print("  " .. l) end
end
