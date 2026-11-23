-- AHLedger - Base de recettes et planificateur de montée de métier
--
-- Les recettes viennent de « fournisseurs » :
--   * "connues" : tes recettes, relevées à l'ouverture des fenêtres de métier (Professions.lua) ;
--   * d'autres addons de recettes, branchés avec RecipeDB.Register (un petit adaptateur par addon).
--
-- Format d'une recette (tous les champs sauf out, prof et r sont facultatifs) :
--   { out = idObjetFabriqué, prof = "leatherworking", r = { [idComposant] = quantité }, made = quantité produite,
--     name = "…", learned = true/false, diff = "optimal"/"medium"/"easy"/"trivial" (couleur actuelle),
--     levels = { learn, yellow, green, grey },            -- seuils de compétence de la recette
--     source = { kind = "trainer"/"vendor"/"drop"/"quest", cost = cuivre, item = idObjetRecette, where = "…" } }
--
-- Fournisseur : { Recipes = function(profKey) return { recette, recette, … } end, Professions = function() … end (facultatif) }
local _, ns = ...

local RecipeDB = {}
ns.RecipeDB = RecipeDB

RecipeDB.providers = {}
RecipeDB.order = {}

function RecipeDB.Register(name, provider)
  if not RecipeDB.providers[name] then RecipeDB.order[#RecipeDB.order + 1] = name end
  RecipeDB.providers[name] = provider
  RecipeDB.cache = nil
  ns.dataVersion = (ns.dataVersion or 0) + 1
end

function RecipeDB.ProviderNames()
  local out = {}
  for _, n in ipairs(RecipeDB.order) do out[#out + 1] = n end
  return out
end

-- Fournisseur intégré : tes recettes connues
RecipeDB.Register("connues", {
  Recipes = function(prof)
    local out = {}
    for outId, r in pairs((ns.Prof.Recipes() or {})[prof] or {}) do
      out[#out + 1] = { out = outId, prof = prof, r = r.r, made = r.m, name = r.n, learned = true, diff = r.d }
    end
    return out
  end,
})

-- Toutes les recettes d'un métier, fusionnées par objet fabriqué : les fournisseurs externes
-- apportent seuils et sources, tes recettes connues apportent « apprise » et la couleur actuelle.
function RecipeDB.All(prof)
  local merged = {}
  for _, name in ipairs(RecipeDB.order) do
    local ok, list = pcall(RecipeDB.providers[name].Recipes, prof)
    if ok and type(list) == "table" then
      for _, rec in ipairs(list) do
        if rec.out and rec.r then
          local m = merged[rec.out]
          if not m then
            m = { out = rec.out, prof = prof, r = rec.r }
            merged[rec.out] = m
          end
          for k, v in pairs(rec) do
            if m[k] == nil or k == "learned" and v then m[k] = v end
          end
        end
      end
    end
  end
  local out = {}
  for _, m in pairs(merged) do out[#out + 1] = m end
  return out
end

------------------------------------------------------------------------
-- Planificateur de montée
------------------------------------------------------------------------
local Plan = {}
ns.Plan = Plan

-- Chance de gagner un point (formule Classic) : 100 % sous le jaune, puis
-- (gris - compétence) / (gris - jaune) jusqu'au gris.
function Plan.Chance(rec, rank, startRank)
  local lv = rec.levels
  if lv and lv[2] and lv[4] then
    if lv[1] and rank < lv[1] then return 0 end
    if rank < lv[2] then return 1 end
    if rank >= lv[4] then return 0 end
    return (lv[4] - rank) / math.max(lv[4] - lv[2], 1)
  end
  -- sans seuils : on ne connaît que la couleur au niveau actuel, valable quelques points seulement
  if rank - startRank > 5 then return 0 end
  return ({ optimal = 1, medium = 0.75, easy = 0.3 })[rec.diff] or 0
end

-- Coût net d'une fabrication : composants (le moins cher PNJ/HV) − ce que rapporte l'objet fabriqué
-- (HV nette si le marché l'absorbe, sinon prix PNJ). Renvoie nil si un composant n'a pas de prix.
function Plan.CraftCost(rec)
  local cost = 0
  for rid, n in pairs(rec.r) do
    local c = ns.Analysis.ReagentCost(rid)
    if not c then return nil, rid end
    cost = cost + c * n
  end
  local made = rec.made or 1
  local s = ns.Analysis.Get(rec.out)
  local meta = AHLedgerDB.items[rec.out]
  local vendor = (meta and meta.s or 0) * made
  local ah = (s and s.perDay and s.perDay >= 1) and math.max(s.netExp, 0) * made or 0
  local value = math.max(vendor, ah)
  return cost - value, cost, value
end

-- Plan de fromRank à toRank. Renvoie { steps = { … }, total = cuivre, crafts = n, reached = rang atteint, partial = bool }
function Plan.Level(prof, fromRank, toRank)
  local recipes = RecipeDB.All(prof)
  local costs = {}
  for _, rec in ipairs(recipes) do
    local net, cost, value = Plan.CraftCost(rec)
    if net then costs[rec] = { net = net, cost = cost, value = value } end
  end
  local steps, total, crafts, learnedNow = {}, 0, 0, {}
  local rank = fromRank
  local partial = false
  while rank < toRank do
    local best, bestScore, bestChance
    for rec, c in pairs(costs) do
      local learnable = rec.learned or (rec.source and rec.source.cost)
      local chance = learnable and Plan.Chance(rec, rank, fromRank) or 0
      if chance > 0 then
        -- coût par point espéré ; une recette à acheter est pénalisée de son prix réparti sur 10 points
        local learnCost = (not rec.learned and not learnedNow[rec]) and rec.source.cost or 0
        local score = c.net / chance + learnCost / 10
        if not best or score < bestScore then best, bestScore, bestChance = rec, score, chance end
      end
    end
    if not best then partial = true; break end
    if not best.levels then partial = true end
    local c = costs[best]
    local n = 1 / bestChance
    local last = steps[#steps]
    if not (last and last.rec == best) then
      last = { rec = best, from = rank, to = rank, crafts = 0, cost = 0, learnCost = 0 }
      if not best.learned and not learnedNow[best] then
        last.learnCost = best.source.cost
        total = total + best.source.cost
        learnedNow[best] = true
      end
      steps[#steps + 1] = last
    end
    last.to = rank + 1
    last.crafts = last.crafts + n
    last.cost = last.cost + c.net * n
    crafts = crafts + n
    total = total + c.net * n
    rank = rank + 1
  end
  for _, st in ipairs(steps) do
    st.craftsRounded = math.ceil(st.crafts - 0.01)
    st.mats = {}
    for rid, q in pairs(st.rec.r) do st.mats[rid] = q * st.craftsRounded end
  end
  return { steps = steps, total = total, crafts = crafts, reached = rank, partial = partial, from = fromRank, to = toRank }
end

-- Recettes classées par coût d'un point de compétence au niveau actuel (onglet Artisanat, vue « Montée »)
function Plan.NextPoints(prof)
  local rank = ns.Prof.Skill(prof)
  if not rank then return {} end
  local out = {}
  for _, rec in ipairs(RecipeDB.All(prof)) do
    local chance = (rec.learned or (rec.source and rec.source.cost)) and Plan.Chance(rec, rank, rank) or 0
    if chance > 0 then
      local net, cost, value = Plan.CraftCost(rec)
      out[#out + 1] = { id = rec.out, s = ns.Analysis.Get(rec.out), prof = prof, rec = rec, chance = chance, diff = rec.diff,
                        net = net, cost = cost, value = value, perPoint = net and net / chance,
                        learnCost = not rec.learned and rec.source and rec.source.cost or nil }
    end
  end
  return out
end

-- Métiers de fabrication que tu as (ceux qui ont des recettes)
function Plan.CraftProfs()
  local out = {}
  for prof in pairs(ns.Prof.Char().skills) do
    if #RecipeDB.All(prof) > 0 then out[#out + 1] = prof end
  end
  table.sort(out)
  return out
end

-- /ahl monter <métier> [niveau visé]
local ALIASES = { cuir = "leatherworking", lw = "leatherworking", cuisine = "cooking", secourisme = "firstaid",
                  soins = "firstaid", couture = "tailoring", forge = "blacksmithing", alchimie = "alchemy",
                  ingenierie = "engineering", ["ingénierie"] = "engineering", enchantement = "enchanting" }

local function plain(s) return (tostring(s or "?"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local function itemName(id)
  local m = AHLedgerDB.items[id]
  return plain(m and m.n or ("#" .. id))
end

function Plan.Describe(p)
  local lines = {}
  for _, st in ipairs(p.steps) do
    local mats = {}
    for rid, q in pairs(st.mats) do mats[#mats + 1] = ("%d %s"):format(q, itemName(rid)) end
    table.sort(mats)
    lines[#lines + 1] = ("%d → %d : %s ×%d (%s)%s — %s"):format(st.from, st.to, itemName(st.rec.out), st.craftsRounded,
      table.concat(mats, ", "), st.learnCost > 0 and (" + recette " .. plain(ns.money(st.learnCost))) or "",
      st.cost >= 0 and ("coût net " .. plain(ns.money(st.cost))) or ("gain " .. plain(ns.money(-st.cost))))
  end
  return lines
end

function Plan.Command(args)
  local word, target = (args or ""):match("^(%S*)%s*(%d*)")
  local prof = ALIASES[(word or ""):lower()] or ns.Prof.KeyFor(word)
  if not prof then
    local list = Plan.CraftProfs()
    prof = list[1]
    if not prof then ns.print("Aucune recette relevée : ouvre une fenêtre de métier."); return end
  end
  local rank = ns.Prof.Skill(prof)
  if not rank then ns.print("Métier inconnu pour ce personnage : " .. prof); return end
  local maxRank = ns.Prof.Char().max and ns.Prof.Char().max[prof] or rank + 25
  local p = Plan.Level(prof, rank, tonumber(target) or maxRank)
  ns.print(("Montée %s %d → %d : %d fabrications, coût net %s"):format(ns.Prof.LABEL[prof] or prof, p.from, p.reached,
    math.ceil(p.crafts), plain(ns.money(p.total))))
  for _, l in ipairs(Plan.Describe(p)) do ns.print("  " .. l) end
  if p.partial then
    ns.print("|cffffd100Plan partiel : sans base de recettes (seuils jaune/vert/gris), seule la couleur actuelle de tes recettes est connue. Branche un addon de recettes pour le plan complet.|r")
  end
end
