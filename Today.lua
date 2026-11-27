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
--   1. on écarte les conseils non fiables : prix non tenu (Trust.Check = « bad ») ou type de conseil qui
--      échoue trop souvent (Track : au moins TRACK_MIN_CHECKED vérifiés et moins de TRACK_BAD_RATE réussis) ;
--   2. score = gain × poids de fiabilité ÷ minutes (« à tester » : poids TEST_WEIGHT, une chance sur deux) ;
--   3. on prend les actions par score décroissant tant qu'il reste du temps et de l'or. Une action
--      divisible (achat PNJ, artisanat, farm) qui ne tient pas entière est réduite à ce qui tient ; une
--      action indivisible (flip, mise en vente groupée) qui ne tient pas est sautée.
--   Le glouton par ratio est optimal quand tout est divisible, proche de l'optimum sinon : assez bon pour
--   des actions petites devant la séance, et lisible (« pourquoi celle-ci avant celle-là »).
--   L'or des ventes n'est pas compté comme disponible pendant la séance (il arrive plus tard au courrier ;
--   même la vente au PNJ, payée tout de suite, n'est pas réinvestie : on reste prudent).
--   Pas de modèle de sous-agent consulté pour ce choix (outil indisponible lors de l'écriture) : à revoir
--   si les essais en jeu montrent un meilleur ordre.
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
-- Candidats : une action par conseil existant
------------------------------------------------------------------------
-- Action : { kind, id, text, gain, minutes, gold, trust, trustWhy, why, group,
--            divisible = { unitGain, unitGold, unitMin, fixedMin, qty, label } (réductible) }

local function add(list, a)
  if a and a.gain and a.gain > 0 and a.minutes and a.minutes > 0 then list[#list + 1] = a end
end

-- Ventes : la file de mise en vente (une ligne par objet ; plusieurs piles s'il y en a plusieurs à poster)
local function sellActions(out, rates, inQueue)
  for _, e in ipairs(ns.Sell.Queue()) do
    if not e.blocked and e.price then
      inQueue[e.id] = true
      local posts = math.max(1, math.ceil(e.planned / math.max(e.qty, 1)))
      local units = math.min(e.planned, posts * e.qty)
      local net = e.price * units * (1 - cut())
      local trust, tw = Today.Reliability(e.s, e.price, "bagAH", rates)
      local dep = (e.s and e.s.deposit or 0) * units
      add(out, { kind = "sell", id = e.id, s = e.s, gain = net, minutes = posts * Today.POST_MIN, gold = dep,
                 trust = trust, trustWhy = tw, group = "bagAH",
                 text = ("Poste %d pile%s de %s (×%d, %s/u) : ~%s net"):format(posts, posts > 1 and "s" or "",
                   nameOf(e.id, e.s), e.qty, g(e.price), g(net)),
                 why = plain(e.reason) })
    end
  end
end

-- Enchères battues qui valent un repost
local function repostActions(out, rates)
  for _, u in ipairs(ns.Sell.Undercuts()) do
    if u.worth and u.gain and u.newPrice then
      local trust, tw = Today.Reliability(u.s, u.newPrice, nil, rates)
      add(out, { kind = "repost", id = u.id, s = u.s, gain = u.gain, minutes = u.n * Today.REPOST_MIN,
                 gold = (u.s and u.s.deposit or 0) * u.qty, trust = trust, trustWhy = tw,
                 text = ("Annule et reposte %s ×%d à %s/u : +%s attendus"):format(nameOf(u.id, u.s), u.qty,
                   g(u.newPrice), g(u.gain)),
                 why = ("battue de %+.0f %%"):format((u.gap or 0) * 100) })
    end
  end
end

-- Marchés au-dessus du prix habituel, pour ce que tu as (surtout en banque : les sacs sont déjà dans la file)
local function premiumActions(out, rates, inQueue)
  if not (ns.Opp and ns.Opp.Undercuts) then return end
  local c = ns.Prof.Char()
  for _, e in ipairs(ns.Opp.Undercuts()) do
    if (e.have or 0) > 0 and not inQueue[e.id] then
      local qty = math.min(e.have, e.qty)
      local inBags = (c.bags or {})[e.id] or 0
      local trust, tw = Today.Reliability(e.s, e.post, "bagAH", rates)
      local net = e.post * qty * (1 - cut())
      add(out, { kind = "premium", id = e.id, s = e.s, gain = net,
                 minutes = Today.POST_MIN + (inBags >= qty and 0 or Today.BANK_MIN),
                 gold = (e.s and e.s.deposit or 0) * qty, trust = trust, trustWhy = tw, group = "bagAH",
                 text = ("Poste %d %s à %s/u (%s au-dessus de l'habituel)%s : ~%s net"):format(qty, nameOf(e.id, e.s),
                   g(e.post), plain(ns.pct(e.premium)), inBags >= qty and "" or ", pris à la banque", g(net)),
                 why = plain(e.notes) })
    end
  end
end

-- Flips HV : achat groupé, indivisible (le bénéfice dépend des paliers achetés)
local function flipActions(out, rates)
  for _, f in ipairs(ns.Analysis.Flips()) do
    local group = f.kind == "stock" and (f.known and "stock" or "stockTest") or "now"
    local trust, tw = Today.Reliability(f.s, f.resale, group, rates)
    local when = f.kind == "stock" and (", garde-les : " .. ns.Analysis.FlipWhen(f)) or ""
    add(out, { kind = "flip", id = f.id, s = f.s, gain = f.profit, minutes = Today.FLIP_MIN, gold = f.cost,
               trust = trust, trustWhy = tw, group = group,
               text = ("Achète %d %s jusqu'à %s/u, revends à %s/u%s : ~%s"):format(f.qty, nameOf(f.id, f.s), g(f.maxBuy),
                 g(f.resale), when, g(f.profit)),
               why = ("ROI %.0f %%, écoulé en ~%.1f j"):format(f.roi * 100, f.days or 0) })
  end
end

-- Achats PNJ → HV : divisibles à l'unité
local function vendorActions(out, rates)
  for _, e in ipairs(ns.Analysis.VendorFlips()) do
    local qty = e.reliable and math.max(1, math.ceil(e.vol or 1)) or (e.testQty or 1)
    if e.lim and e.lim > 0 then qty = math.min(qty, e.lim) end
    local group = e.reliable and "vendor" or "vendorTest"
    local trust, tw = Today.Reliability(e.s, e.s.price, group, rates)
    if not e.reliable and trust == "ok" then trust, tw = "test", e.why end
    add(out, { kind = "vendor", id = e.id, s = e.s, gain = e.margin * qty, minutes = Today.VENDOR_TRAVEL_MIN,
               gold = e.buy * qty, trust = trust, trustWhy = tw, group = group,
               divisible = { qty = qty, unitGain = e.margin, unitGold = e.buy, unitMin = 0,
                             fixedMin = Today.VENDOR_TRAVEL_MIN },
               label = function(q) return ("Achète %d %s chez %s (%s, %s/u), revends à l'HV %s/u : ~%s"):format(
                 q, nameOf(e.id, e.s), plain(e.npc or "?"), plain(e.zone or "?"), g(e.buy), g(e.s.price), g(e.margin * q)) end,
               why = ("marge %s/u, %s vendus/j"):format(g(e.margin), e.perDay and ("%.0f"):format(e.perDay) or "?") })
  end
end

-- Artisanat : recettes connues rentables, et composants des sacs à transformer (une seule action par objet fabriqué)
local function craftActions(out, rates)
  local best = {}
  local function keep(a)
    if not (a and a.gain and a.gain > 0) then return end
    local cur = best[a.id]
    if not cur or a.gain / a.minutes > cur.gain / cur.minutes then best[a.id] = a end
  end
  for _, e in ipairs(ns.Analysis.Crafts()) do
    if e.cost and (e.profit or 0) > 0 and not (e.sellTo == "HV" and e.slow) then
      local qty = math.max(1, math.ceil(e.vol or 1))
      local group = e.sellTo == "HV" and "craft" or nil
      local trust, tw = "ok", "revente au PNJ"
      if e.sellTo == "HV" then trust, tw = Today.Reliability(e.s, e.post, group, rates) end
      local made = e.made or 1
      keep({ kind = "craft", id = e.id, s = e.s, gain = e.profit * qty,
             minutes = Today.CRAFT_SETUP_MIN + qty * Today.CRAFT_EACH_MIN, gold = e.cost * qty,
             trust = trust, trustWhy = tw, group = group,
             divisible = { qty = qty, unitGain = e.profit, unitGold = e.cost, unitMin = Today.CRAFT_EACH_MIN,
                           fixedMin = Today.CRAFT_SETUP_MIN },
             label = function(q) return ("Crafte %s ×%d (%s), vends %s : ~%s"):format(nameOf(e.id, e.s), q * made,
               plain(ns.Prof.LABEL[e.prof] or e.prof), e.sellTo == "HV" and "à l'HV" or "au PNJ", g(e.profit * q)) end,
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
      local trust, tw = "ok", "revente au PNJ"
      if up.sellTo == "HV" then
        trust, tw = Today.Reliability(ns.Analysis.Get(up.out), nil, "craft", rates)
        if up.unsure and trust == "ok" then trust, tw = "test", "aucune vente vue au prix de l'objet fabriqué" end
      end
      keep({ kind = "craft", id = up.out, gain = up.gain * up.q * crafts,
             minutes = Today.CRAFT_SETUP_MIN + crafts * Today.CRAFT_EACH_MIN, gold = up.others * crafts,
             trust = trust, trustWhy = tw, group = up.sellTo == "HV" and "craft" or nil,
             divisible = { qty = crafts, unitGain = up.gain * up.q, unitGold = up.others, unitMin = Today.CRAFT_EACH_MIN,
                           fixedMin = Today.CRAFT_SETUP_MIN },
             label = function(q) return ("Crafte %s ×%d avec tes %s, vends %s : +%s de plus que brut"):format(
               nameOf(up.out), q * (up.made or 1), nameOf(e.id, e.s), up.sellTo == "HV" and "à l'HV" or "au PNJ",
               g(up.gain * up.q * q)) end,
             why = ("%s/u au lieu de %s"):format(g(up.perUnit), g(up.raw)) })
    end
  end
  for _, a in pairs(best) do add(out, a) end
end

-- Vente au PNJ des sacs (conseil « PNJ ») : une seule action groupée, payée tout de suite
local function vendorSaleAction(out, rates)
  local c = ns.Prof.Char()
  local total, n = 0, 0
  for _, e in ipairs(ns.Bags.Advice()) do
    local have = (c.bags or {})[e.id] or 0
    if e.action == "PNJ" and have > 0 and (e.vendor or 0) > 0 then
      total, n = total + e.vendor * have, n + 1
    end
  end
  if n == 0 then return end
  local trust, tw = Today.Reliability(nil, nil, "bagNPC", rates)
  add(out, { kind = "npc", gain = total, minutes = Today.VENDOR_SELL_MIN, gold = 0, trust = trust, trustWhy = tw,
             group = "bagNPC", text = ("Vends %d objet%s des sacs au PNJ : %s"):format(n, n > 1 and "s" or "", g(total)),
             why = "l'HV ne paie pas mieux que le marchand" })
end

-- Farm : meilleure zone de tes sessions, divisible en minutes
local function farmAction(out)
  local bestZ
  for _, z in ipairs(ns.Analysis.FarmZones()) do
    if z.hours >= Today.FARM_MIN_HOURS and z.total > 0 and (not bestZ or z.total > bestZ.total) then bestZ = z end
  end
  if not bestZ then return end
  local z = bestZ
  local perMin = z.total / 60
  local trust = z.hours >= Today.FARM_OK_HOURS and "ok" or "test"
  local tw = ("%.1f h relevées"):format(z.hours)
  add(out, { kind = "farm", id = z.best, gain = perMin * Today.FARM_MAX_BLOCK, minutes = Today.FARM_MAX_BLOCK, gold = 0,
             trust = trust, trustWhy = tw, farm = true,
             divisible = { qty = Today.FARM_MAX_BLOCK, unitGain = perMin, unitGold = 0, unitMin = 1, fixedMin = 0,
                           minQty = Today.FARM_MIN_BLOCK },
             label = function(q) return ("Farm %s %d min : ~%s/h, ~%s"):format(plain(z.zone), q, g(z.total), g(perMin * q)) end,
             why = ("%d session%s, meilleur objet %s"):format(z.sessions, z.sessions > 1 and "s" or "",
               z.best and nameOf(z.best) or "-") })
end

-- Tous les conseils candidats, fiables ou non (les « bad » sont marqués, pas encore écartés)
function Today.Candidates()
  local out, rates, inQueue = {}, Today.TrackRates(), {}
  local function try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
      ns.errors[#ns.errors + 1] = "aujourd'hui/" .. label .. " : " .. tostring(err)
    end
  end
  try("ventes", sellActions, out, rates, inQueue)
  try("reposts", repostActions, out, rates)
  try("banque", premiumActions, out, rates, inQueue)
  try("flips", flipActions, out, rates)
  try("achats PNJ", vendorActions, out, rates)
  try("artisanat", craftActions, out, rates)
  try("vente PNJ", vendorSaleAction, out, rates)
  try("farm", farmAction, out)
  for _, a in ipairs(out) do
    if a.label and not a.text then a.text = a.label(a.divisible.qty) end
    a.weight = a.trust == "test" and Today.TEST_WEIGHT or 1
    a.gpm = a.gain / a.minutes
    a.score = a.gain * a.weight / a.minutes
  end
  return out
end

------------------------------------------------------------------------
-- Plan : glouton par gain/minute pondéré, sous contrainte de temps et d'or
------------------------------------------------------------------------

-- Réduit une action divisible à ce qui tient dans le temps et l'or restants ; nil si rien ne tient
local function shrink(a, timeLeft, goldLeft)
  local d = a.divisible
  local q = d.qty
  if d.unitMin > 0 then q = math.min(q, math.floor((timeLeft - d.fixedMin) / d.unitMin + 1e-9)) end
  if d.unitGold > 0 then q = math.min(q, math.floor(goldLeft / d.unitGold)) end
  if q < (d.minQty or 1) then return nil end
  local b = {}
  for k, v in pairs(a) do b[k] = v end
  b.qty, b.shrunk = q, q < d.qty
  b.gain, b.gold, b.minutes = d.unitGain * q, d.unitGold * q, d.fixedMin + d.unitMin * q
  b.text = a.label(q)
  if b.minutes > timeLeft + 1e-9 or b.gold > goldLeft then return nil end
  return b
end

-- Today.Plan(minutes, orDisponible) → liste ordonnée d'actions, résumé
--   minutes : durée de la séance (défaut DEFAULT_MINUTES) ; orDisponible : en cuivre (défaut : ton or)
--   résumé = { gain, minutes, gold, minutesMax, goldMax, excluded (non fiables écartés), skipped (ne tiennent pas) }
function Today.Plan(minutes, gold)
  minutes = tonumber(minutes) or Today.DEFAULT_MINUTES
  gold = tonumber(gold) or (ns.Analysis.Gold()) or 0
  local cands = Today.Candidates()
  local pool, excluded = {}, 0
  for _, a in ipairs(cands) do
    if a.trust == "bad" then excluded = excluded + 1 else pool[#pool + 1] = a end
  end
  table.sort(pool, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return (a.text or "") < (b.text or "")
  end)
  local plan = {}
  local timeLeft, goldLeft, skipped = minutes, gold, 0
  for _, a in ipairs(pool) do
    local pick
    if a.minutes <= timeLeft + 1e-9 and a.gold <= goldLeft then
      pick = a
    elseif a.divisible then
      pick = shrink(a, timeLeft, goldLeft)
    end
    if pick then
      plan[#plan + 1] = pick
      pick.order = #plan
      timeLeft, goldLeft = timeLeft - pick.minutes, goldLeft - pick.gold
    else
      skipped = skipped + 1
    end
    if timeLeft < Today.POST_MIN then break end
  end
  local sum = { gain = 0, minutes = 0, gold = 0, minutesMax = minutes, goldMax = gold, excluded = excluded, skipped = skipped }
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
