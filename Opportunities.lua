-- AHLedger - Opportunités : recettes rentables à poursuivre, et marchés où sous-coter
--
-- * Recettes rentables : toutes les recettes de la base (tes recettes connues + addon de recettes,
--   OneForAll par exemple), même celles que tu n'as pas encore apprises ou dont tu n'as pas le niveau,
--   et même dans des métiers que tu n'as pas. Pour chacune : bénéfice par fabrication, or/jour que le
--   marché peut absorber, et ce qu'il faut pour y accéder (recette à acheter, niveau à monter).
-- * Sous-coter : objets dont l'enchère la moins chère est nettement au-dessus du prix habituel. En te
--   plaçant juste dessous, tu vends plus cher que d'habitude, et en premier.
local _, ns = ...

local Opp = {}
ns.Opp = Opp

Opp.RECIPE_MIN_PROFIT = 100     -- 1 pa de bénéfice mini par fabrication
Opp.RECIPE_MIN_ROI = 0.15       -- et 15 % de marge sur les composants
Opp.UNDERCUT_MIN_PREMIUM = 0.10 -- l'enchère la moins chère doit dépasser d'au moins 10 % le prix habituel
Opp.UNDERCUT_MIN_GAIN = 200     -- au moins 2 pa de plus que d'habitude sur la quantité à poster
Opp.UNDERCUT_STEP = 1           -- on se place 1 pc sous l'enchère la moins chère
Opp.UNDERCUT_POST_DAYS = 1      -- on ne poste qu'un jour de ventes : au-delà, d'autres te sous-cotent

------------------------------------------------------------------------
-- Recettes rentables à poursuivre
------------------------------------------------------------------------

-- Couleur d'une recette à un niveau donné, d'après ses seuils
local function colorAt(levels, rank)
  if not (levels and levels[2] and levels[3] and levels[4] and rank) then return nil end
  if rank < levels[2] then return "optimal" end
  if rank < levels[3] then return "medium" end
  if rank < levels[4] then return "easy" end
  return "trivial"
end

local SOURCE = { trainer = "maître", vendor = "PNJ", drop = "butin", quest = "quête" }

-- Accès à une recette : rang de tri (1 = déjà apprise … 5 = hors de portée) et texte affiché
function Opp.Access(rec, rank)
  if rec.learned then return 1, "|cff40ff40apprise|r" end
  if not rank then return 4, "|cff808080métier non appris|r" end
  local need = rec.levels and rec.levels[1]
  local src = rec.source or {}
  local how = SOURCE[src.kind] or "?"
  if src.cost and src.cost > 0 then how = how .. " " .. ns.money(src.cost) end
  if need and rank < need then
    return 3, ("|cffffd100niv. %d|r (toi %d) · %s"):format(need, rank, how)
  end
  if src.cost then return 2, "|cff66ccffà apprendre|r · " .. how end
  return 5, "|cffff8040" .. how .. "|r" .. (src.where and (" · " .. src.where) or "")
end

-- Résultat gardé tant que les données ne changent pas (la molette rafraîchit l'onglet à chaque cran)
local cache = {}
local function cached(key, fn)
  local c = cache[key]
  local realm = ns.realmKey()
  if c and c.v == ns.dataVersion and c.realm == realm then return c.list end
  local list = fn()
  cache[key] = { v = ns.dataVersion, realm = realm, list = list }
  return list
end

-- Copie de la liste : l'interface la trie sur place
local function copy(list)
  local out = {}
  for i, e in ipairs(list) do out[i] = e end
  return out
end

function Opp.Recipes() return copy(cached("recipes", Opp.BuildRecipes)) end
function Opp.Undercuts() return copy(cached("undercuts", Opp.BuildUndercuts)) end

function Opp.BuildRecipes()
  local out = {}
  local chars = ns.Prof.Char()
  local profs = {}
  for prof in pairs(ns.Prof.LABEL) do profs[#profs + 1] = prof end
  for _, prof in ipairs(profs) do
    local rank = chars.skills[prof]
    for _, rec in ipairs(ns.RecipeDB.All(prof)) do
      local net, cost, value, vendor = ns.Plan.CraftCost(rec)
      if net and cost > 0 then
        local profit = -net
        local roi = profit / cost
        if profit >= Opp.RECIPE_MIN_PROFIT and roi >= Opp.RECIPE_MIN_ROI then
          local s = ns.Analysis.Get(rec.out)
          local made = rec.made or 1
          local sellTo = value > vendor and "HV" or "PNJ"
          local trust = sellTo == "HV" and s and s.trust or "ok"
          if trust == "bad" then sellTo = nil end -- le prix de revente n'est pas tenu : pas une opportunité
        if sellTo then
          -- fabrications par jour : ta part des ventes du marché à l'HV, ou une quantité fixe au PNJ
          local vol = sellTo == "HV" and (s and s.perDay or 0) * ns.Analysis.VENDOR_SHARE / made
            or ns.Analysis.CRAFT_VENDOR_PER_DAY
          local daily = profit * vol * (sellTo == "HV" and s and s.confidence or 1)
          local order, access = Opp.Access(rec, rank)
          local learnCost = not rec.learned and rec.source and rec.source.cost or nil
          out[#out + 1] = {
            id = rec.out, s = s, prof = prof, rec = rec, name = rec.name, made = made,
            cost = cost, value = value, profit = profit, roi = roi, sellTo = sellTo, vol = vol, daily = daily,
            perDay = s and s.perDay, access = access, accessOrder = order, learnCost = learnCost,
            -- jours de bénéfice pour rembourser la recette (0 si déjà apprise ou gratuite)
            payback = learnCost and learnCost > 0 and daily > 0 and learnCost / daily or (learnCost == 0 or rec.learned) and 0 or nil,
            diff = rec.diff or colorAt(rec.levels, rank), gap = rank and rec.levels and rec.levels[1] and math.max(rec.levels[1] - rank, 0),
            trust = trust, trustWhy = s and s.trustWhy,
          }
        end
        end
      end
    end
  end
  return out
end

------------------------------------------------------------------------
-- Sous-coter
------------------------------------------------------------------------

-- Ce que tu as ou peux produire de cet objet : sacs/banque, enchères en cours, fabrication, récolte
local function forYou(id, post)
  local c = ns.Prof.Char()
  local have = ((c.bags or {})[id] or 0) + ((c.bank or {})[id] or 0)
  local parts, rank = {}, 0
  if have > 0 then parts[#parts + 1] = ("tu en as %d"):format(have); rank = 3 end
  for prof, list in pairs(ns.Prof.Recipes() or {}) do
    local r = list[id]
    if r then
      local cost = 0
      for rid, n in pairs(r.r) do
        local p = ns.Analysis.ReagentCost(rid)
        if not p then cost = nil; break end
        cost = cost + p * n
      end
      local unit = cost and cost / (r.m or 1)
      if unit and unit < post * (1 - ns.Analysis.AH_CUT) then
        parts[#parts + 1] = ("fabricable (%s, %s/u)"):format(ns.Prof.LABEL[prof] or prof, ns.money(unit))
        rank = math.max(rank, 2)
      end
    end
  end
  local tag = ns.Prof.Tag(id)
  if tag then parts[#parts + 1] = tag; rank = math.max(rank, 1) end
  return rank, table.concat(parts, " · "), have
end

-- Tes propres enchères les moins chères, par objet (ne pas te sous-coter toi-même)
local function myLowest()
  local by = {}
  local a = ns.Prof.Char().auctions
  for _, e in ipairs(a and a.list or {}) do
    if not e.sold and e.unit and (not by[e.id] or e.unit < by[e.id]) then by[e.id] = e.unit end
  end
  return by
end

function Opp.UndercutFor(s, book, mine)
  if not (s and book and book.levels and book.levels[1] and s.perDay and s.perDay >= 1) then return nil end
  local low = book.levels[1][1]
  if not low or low <= Opp.UNDERCUT_STEP then return nil end
  if mine and mine <= low then return nil end -- c'est déjà toi le moins cher
  local fair = s.price -- prix réel de vente, sinon prix affiché plafonné au plus haut prix vu vendu
  if not fair or fair <= 0 then return nil end
  local post = low - Opp.UNDERCUT_STEP
  local premium = post / fair - 1
  if premium < Opp.UNDERCUT_MIN_PREMIUM then return nil end
  local st = math.max(s.sellThrough or 0.67, 0.1)
  local depLoss = (s.deposit or 0) * (1 - st) / st
  local netPost = post * (1 - ns.Analysis.AH_CUT) - depLoss
  if netPost <= 0 then return nil end
  local qty = math.max(1, math.floor(s.perDay * Opp.UNDERCUT_POST_DAYS))
  local extra = (post - fair) * (1 - ns.Analysis.AH_CUT) * qty * (s.confidence or 1)
  if extra < Opp.UNDERCUT_MIN_GAIN then return nil end
  local trust, trustWhy = "ok", nil
  if ns.Trust then
    trust, trustWhy = ns.Trust.Check(s, post)
    if trust == "bad" then return nil end -- personne n'a acheté aussi cher : ce n'est pas un marché à sous-coter
  end
  local warn = {}
  if trust == "test" then warn[#warn + 1] = "à tester : " .. trustWhy end
  if s.topShare and s.sellers and s.sellers >= 2 and s.topShare >= 0.6 then warn[#warn + 1] = "dominé" end
  if s.stockDays and s.stockDays > ns.Analysis.HEAVY_STOCK_DAYS then warn[#warn + 1] = "stock lourd" end
  if s.sellThrough and s.sellThrough < 0.4 then warn[#warn + 1] = "invendus" end
  if s.trend and s.trend <= -0.03 then warn[#warn + 1] = "baisse" end
  if s.obsHours and s.obsHours < 6 then warn[#warn + 1] = "peu de données" end
  local nextLevel = book.levels[2] and book.levels[2][1]
  return { id = s.id, s = s, name = s.name, low = low, post = post, fair = fair, premium = premium, netPost = netPost,
           qty = qty, extra = extra, lowQty = book.levels[1][2], nextLevel = nextLevel,
           perDay = s.perDay, sellers = s.sellers, stockDays = s.stockDays, warn = warn,
           -- les risques réduisent l'ordre de tri par défaut
           score = extra * (#warn > 0 and 0.75 ^ #warn or 1) }
end

function Opp.BuildUndercuts()
  local db, out = ns.realmDB(), {}
  if not db.book then return out end
  local mine = myLowest()
  for id, s in pairs(ns.Analysis.All().byId) do
    local e = Opp.UndercutFor(s, ns.Scan.UnpackBook(db.book[id]), mine[id])
    if e then
      e.forYouOrder, e.forYou, e.have = forYou(id, e.post)
      local notes = {}
      if e.forYou ~= "" then notes[#notes + 1] = "|cff40ff40" .. e.forYou .. "|r" end
      if #e.warn > 0 then notes[#notes + 1] = "|cffff8040" .. table.concat(e.warn, ", ") .. "|r" end
      e.notes = table.concat(notes, " · ")
      out[#out + 1] = e
    end
  end
  return out
end
