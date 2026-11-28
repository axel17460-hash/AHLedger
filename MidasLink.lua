-- AHLedger - Lien avec Midas (addon MIT de Rebo), facultatif
--
-- Midas publie une API pour les autres addons (table globale MidasAPI, voir son API.lua) :
-- un « prix juste » tiré de ses scans quotidiens et une chance de vente d'une enchère de 48 h à un
-- prix donné. AHLedger s'en sert seulement en second recours, quand ses propres scans n'ont pas
-- encore vu assez de ventes (prix d'équilibre, chances de vente). Midas absent : rien ne change.
-- Lecture seule : aucune fonction de Midas qui scanne, achète ou poste n'est appelée.
local _, ns = ...

local Link = {}
ns.MidasLink = Link

-- Midas chargé et prêt (ses données sont lues après PLAYER_LOGIN)
function Link.Ready()
  local api = _G.MidasAPI
  if type(api) ~= "table" or type(api.IsReady) ~= "function" then return false end
  local ok, ready = pcall(api.IsReady)
  return ok and ready == true
end

local function call(name, ...)
  if not Link.Ready() then return nil end
  local fn = _G.MidasAPI[name]
  if type(fn) ~= "function" then return nil end
  local ok, a = pcall(fn, ...)
  if ok then return a end
  return nil
end

-- Prix juste de Midas (cuivre) ou nil
function Link.Fair(id)
  local v = call("GetFairPrice", id)
  if type(v) == "number" and v > 0 then return math.floor(v) end
  return nil
end

-- Chance (0 à 1) qu'UNE enchère de 48 h à price se vende, selon Midas ; nil sans données
function Link.Odds(id, price)
  local v = call("GetSellOdds", id, price)
  if type(v) == "number" and v >= 0 and v <= 1 then return v end
  return nil
end

-- Pour /ahl diag : « présent, version x » ou « absent »
function Link.Status()
  local api = _G.MidasAPI
  if type(api) ~= "table" then return "absent" end
  local v = "?"
  if type(api.GetVersion) == "function" then
    local ok, ver = pcall(api.GetVersion)
    if ok and ver then v = ver end
  end
  return ("présent (version %s, %s)"):format(tostring(v), Link.Ready() and "données prêtes" or "pas encore prêt")
end
