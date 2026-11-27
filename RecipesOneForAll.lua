-- AHLedger - Adaptateur de recettes : OneForAll
--
-- OneForAll (addon compagnon de WoW Forever, GPL-3.0) publie sa table globale `OneForAll`, qui contient
-- toutes les recettes du client Forever. On la lit au moment du calcul, sans rien en recopier.
-- Champs lus :
--   PROFESSION_RECIPES[métier] = { { s = sort, i = objet fabriqué, c = quantité, n = nom, req = niveau pour
--     apprendre, y / g / gr = seuils jaune / vert / gris, r = { { id, quantité, nom }, … }, ri = objet-recette,
--     start = connue d'office, fav = payée en faveur marchande, src = { v = marchands, d = butin, qs = quêtes } } }
--   PROFESSION_FEES[métier].fees[sort] = { cuivre, niveau }   (prix chez le maître)
--   VENDOR_PRICES[objet] = cuivre                              (prix chez les marchands)
-- Une recette sans prix connu (butin, quête, faveur) prend le prix de l'objet-recette à l'HV s'il y est vu.
local _, ns = ...

local OFA = {}
ns.RecipesOneForAll = OFA

-- clé de métier AHLedger → nom de métier chez OneForAll
OFA.PROF = {
  leatherworking = "Leatherworking", cooking = "Cooking", firstaid = "First Aid", tailoring = "Tailoring",
  blacksmithing = "Blacksmithing", alchemy = "Alchemy", engineering = "Engineering", enchanting = "Enchanting",
}

function OFA.Data()
  local D = OneForAll
  if type(D) == "table" and type(D.PROFESSION_RECIPES) == "table" then return D end
end

local function myFaction()
  local f = UnitFactionGroup and UnitFactionGroup("player")
  return f == "Alliance" and "A" or f == "Horde" and "H" or nil
end

-- Premier lieu utilisable d'une liste de sources : { idPnj, nom, zone, …, fac = "A"/"H" } ou { idQuête, nom }
local function firstPlace(list, fac)
  if type(list) ~= "table" then return nil end
  for _, v in ipairs(list) do
    if type(v) == "table" and v[2] and (not v.fac or not fac or v.fac == fac) then
      return v[3] and ("%s (%s)"):format(tostring(v[2]), tostring(v[3])) or tostring(v[2])
    end
  end
end

-- Prix de l'objet-recette à l'HV, s'il y est vu
local function ahPrice(item)
  local s = item and ns.Analysis and ns.Analysis.Get and ns.Analysis.Get(item)
  local p = s and (s.minNow or s.price)
  return p and p > 0 and p or nil
end

-- Source d'une recette : maître, marchand de ma faction, butin, quête ; coût en cuivre s'il est connu
function OFA.Source(rec, prof, D, fac)
  if rec.start then return { kind = "trainer", cost = 0, where = "connue d'office" } end
  if not rec.ri then
    local fees = D.PROFESSION_FEES and D.PROFESSION_FEES[OFA.PROF[prof]]
    local fee = fees and type(fees.fees) == "table" and fees.fees[rec.s]
    return { kind = "trainer", cost = type(fee) == "table" and fee[1] or nil, where = "maître de métier" }
  end
  local src = type(rec.src) == "table" and rec.src or {}
  local source
  local vendor = firstPlace(src.v, fac)
  if vendor then
    source = { kind = "vendor", item = rec.ri, where = vendor,
               cost = not rec.fav and D.VENDOR_PRICES and D.VENDOR_PRICES[rec.ri] or nil }
  elseif src.d then
    source = { kind = "drop", item = rec.ri, where = firstPlace(src.d) }
  elseif src.qs then
    source = { kind = "quest", item = rec.ri, where = firstPlace(src.qs) }
  else
    source = { kind = src.v and "vendor" or "drop", item = rec.ri, where = src.v and "autre faction" or nil }
  end
  if not source.cost and source.kind ~= "quest" then
    source.cost = ahPrice(rec.ri)
    if source.cost then source.where = "HV" .. (source.where and (" · " .. source.where) or "") end
  end
  return source
end

-- Une recette OneForAll au format de RecipeDB (voir l'en-tête de RecipeDB.lua)
function OFA.Convert(rec, prof, D, fac)
  if type(rec) ~= "table" or not rec.i or type(rec.r) ~= "table" then return nil end
  local r = {}
  for _, re in ipairs(rec.r) do
    if type(re) == "table" and re[1] and re[2] then r[re[1]] = (r[re[1]] or 0) + re[2] end
  end
  if not next(r) then return nil end
  local out = { out = rec.i, prof = prof, r = r, made = rec.c or 1, name = rec.n }
  if rec.y and rec.g and rec.gr then out.levels = { rec.req or 1, rec.y, rec.g, rec.gr } end
  out.source = OFA.Source(rec, prof, D, fac)
  return out
end

-- Conversion gardée tant que les données de marché ne changent pas (les prix HV des recettes en dépendent)
local cache = {}
function OFA.Recipes(prof)
  local D = OFA.Data()
  local list = D and OFA.PROF[prof] and D.PROFESSION_RECIPES[OFA.PROF[prof]]
  if type(list) ~= "table" then return {} end
  local c = cache[prof]
  if c and c.v == ns.dataVersion then return c.list end
  local fac, out = myFaction(), {}
  for _, rec in ipairs(list) do
    local ok, conv = pcall(OFA.Convert, rec, prof, D, fac)
    if ok and conv then out[#out + 1] = conv end
  end
  cache[prof] = { v = ns.dataVersion, list = out }
  return out
end

-- Nombre de recettes lues, pour /ahl diag
function OFA.Count()
  local D, n = OFA.Data(), 0
  if not D then return nil end
  for _, name in pairs(OFA.PROF) do
    local list = D.PROFESSION_RECIPES[name]
    if type(list) == "table" then n = n + #list end
  end
  return n
end

if OFA.Data() then ns.RecipeDB.Register("OneForAll", { Recipes = OFA.Recipes }) end
-- OneForAll chargé après nous (ordre inhabituel) : on se branche quand il arrive
ns.on("ADDON_LOADED", function(name)
  if name == "OneForAll" and OFA.Data() and not ns.RecipeDB.providers.OneForAll then
    ns.RecipeDB.Register("OneForAll", { Recipes = OFA.Recipes })
  end
end)
