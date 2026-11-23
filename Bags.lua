-- AHLedger - Conseiller d'inventaire : pour chaque objet de tes sacs et de ta banque,
-- vendre à l'HV (à quel prix, combien par jour), garder, vendre au PNJ, ou attendre.
--
-- Les sacs sont relus à chaque changement ; la banque seulement quand tu l'ouvres.
local _, ns = ...

local Bags = {}
ns.Bags = Bags

Bags.HOLD_TREND = 0.03     -- prix en hausse de 3 %/j ou plus : on garde
Bags.UNDERCUT_FLOOR = 0.85 -- enchère la moins chère à moins de 85 % du prix réel : marché bradé, on attend
Bags.MIN_VALUE = 100       -- on ignore les objets qui valent moins de 1 pa en tout
Bags.SLOW_PER_DAY = 0.5    -- moins d'une vente tous les 2 jours : l'HV risque de ne rien vendre

local C = C_Container
local function numSlots(bag)
  if C and C.GetContainerNumSlots then return C.GetContainerNumSlots(bag) or 0 end
  return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end
local function slotItem(bag, slot)
  if C and C.GetContainerItemInfo then
    local i = C.GetContainerItemInfo(bag, slot)
    if i then return i.itemID, i.stackCount, i.isBound end
    return nil
  end
  if GetContainerItemInfo then
    local _, count, _, _, _, _, link, _, _, id = GetContainerItemInfo(bag, slot)
    return id or ns.itemIdFromLink(link), count
  end
end

local function read(bagList)
  local out = {}
  for _, bag in ipairs(bagList) do
    for slot = 1, numSlots(bag) do
      local id, count, bound = slotItem(bag, slot)
      if id and not bound then out[id] = (out[id] or 0) + (count or 1) end
    end
  end
  return out
end

local BAGS = { 0, 1, 2, 3, 4 }
local BANK = { -1, 5, 6, 7, 8, 9, 10, 11 }

function Bags.ScanBags()
  local c = ns.Prof.Char()
  c.bags = read(BAGS)
  for id in pairs(c.bags) do ns.rememberItem(id) end
  if ns.UI then ns.UI.OnData() end
end

function Bags.ScanBank()
  local c = ns.Prof.Char()
  c.bank = read(BANK)
  c.bankTime = time()
  for id in pairs(c.bank) do ns.rememberItem(id) end
  if ns.UI then ns.UI.OnData() end
end

local pending = false
local function scheduleBags()
  if pending then return end
  pending = true
  C_Timer.After(1, function()
    pending = false
    ns.safe("sacs", Bags.ScanBags)
  end)
end
ns.on("PLAYER_LOGIN", scheduleBags)
ns.on("BAG_UPDATE_DELAYED", scheduleBags)
ns.on("BANKFRAME_OPENED", function() C_Timer.After(0.5, function() ns.safe("banque", Bags.ScanBank) end) end)
ns.on("PLAYERBANKSLOTS_CHANGED", function() if ns.bankOpen then ns.safe("banque", Bags.ScanBank) end end)
ns.on("BANKFRAME_OPENED", function() ns.bankOpen = true end)
ns.on("BANKFRAME_CLOSED", function() ns.bankOpen = false end)

-- Conseil pour un objet possédé en n exemplaires
function Bags.Advise(id, n)
  local s = ns.Analysis.Get(id)
  local meta = AHLedgerDB.items[id]
  local vsell = meta and meta.s or 0
  local e = { id = id, s = s, count = n, vendor = vsell }
  if not s then
    if vsell <= 0 then return nil end
    e.action, e.unit, e.why = "PNJ", vsell, "pas de marché à l'HV"
  elseif s.netExp <= vsell then
    e.action, e.unit, e.why = "PNJ", vsell, "le marchand paie plus que l'HV"
  elseif s.trend and s.trend >= Bags.HOLD_TREND and not (s.stockDays and s.stockDays > ns.Analysis.HEAVY_STOCK_DAYS) then
    e.action, e.unit = "Garder", s.netExp
    e.why = ("prix en hausse (%+.0f %%/j)"):format(s.trend * 100)
  elseif s.minNow and s.price and s.minNow < s.price * Bags.UNDERCUT_FLOOR then
    e.action, e.unit = "Attendre", s.netExp
    e.why = ("HV bradé : %s/u contre %s d'habitude"):format(ns.money(s.minNow), ns.money(s.price))
  elseif s.perDay and s.perDay < Bags.SLOW_PER_DAY then
    -- presque personne n'achète : chaque mise en vente qui expire coûte son dépôt
    local slow = ("se vend peu à l'HV (~%.1f/j)"):format(s.perDay)
    if vsell > 0 and vsell >= s.netExp * 0.5 then
      e.action, e.unit, e.why = "PNJ", vsell, slow .. " : le marchand paie tout de suite"
    else
      e.action, e.unit = "Garder", s.netExp
      e.why = slow .. " : utilise-le, ou mets-en 1 seul en vente pour tester"
    end
  else
    -- juste sous l'enchère la moins chère, sans dépasser le prix réel de vente de plus de 20 %
    local post = math.floor(s.minNow and (s.minNow - 1) or s.price)
    if post > s.price * 1.2 then post = math.floor(s.price * 1.2) end
    e.action, e.post, e.unit = "Vendre HV", post, post * (1 - ns.Analysis.AH_CUT)
    -- ne pas inonder le marché : environ une journée de ventes à la fois
    e.postQty = s.perDay and math.max(1, math.min(n, math.ceil(s.perDay))) or n
    e.why = s.perDay and ("~%.0f vendus/j"):format(s.perDay) or "volume inconnu"
    if s.trend and s.trend <= -0.03 then e.why = e.why .. ", prix en baisse : vends vite" end
  end
  e.value = e.unit * n
  if e.value < Bags.MIN_VALUE then return nil end
  -- composant d'une de tes recettes rentables ?
  local rel = ns.Prof.Related()[id]
  local up = ns.Analysis.CraftUp(id)
  if up then
    -- mieux vaut le transformer que le vendre tel quel
    local name = up.name or (AHLedgerDB.items[up.out] and AHLedgerDB.items[up.out].n) or ("#" .. up.out)
    e.craftUp = up
    e.action, e.post, e.postQty = "Fabriquer", nil, nil
    e.why = ("%s : %s/u au lieu de %s%s"):format(name, ns.money(up.perUnit), ns.money(up.raw),
      up.learnCost and " (recette à apprendre)" or "")
  elseif rel == "composant" then e.why = e.why .. " · composant d'une de tes recettes" end
  return e
end

-- HV ou PNJ ? Compare le net attendu à l'HV (commission et dépôts perdus déduits, d'après le
-- dernier scan) au rachat par le marchand. Écart dans ±SAME_BAND : à peu près pareil, et le PNJ
-- est alors plus simple (paiement immédiat, rien à surveiller).
Bags.SAME_BAND = 0.10

-- { kind = "ah" | "same" | "vendor", ah = net HV /u, vendor = PNJ /u, gain = HV/PNJ − 1 (nil sans PNJ),
--   slow = se vend peu, unsure = aucune vente vue au prix } ; nil sans marché HV observé
function Bags.Compare(id)
  local s = ns.Analysis.Get(id)
  if not s then return nil end
  local meta = AHLedgerDB.items[id]
  local vsell = meta and meta.s or 0
  local ah = math.max(s.netExp or 0, 0)
  local r = { ah = ah, vendor = vsell, s = s,
              slow = s.perDay ~= nil and s.perDay < Bags.SLOW_PER_DAY, unsure = s.realPrice == nil }
  if vsell <= 0 then
    r.kind = ah > 0 and "ah" or "vendor"
  else
    r.gain = ah / vsell - 1
    r.kind = (r.gain > Bags.SAME_BAND and "ah") or (r.gain < -Bags.SAME_BAND and "vendor") or "same"
  end
  return r
end

-- Phrase courte et colorée pour le tooltip
Bags.COLORS = { ah = { 0.25, 1, 0.25 }, same = { 1, 0.82, 0 }, vendor = { 1, 0.31, 0.31 } }
function Bags.CompareText(c)
  local pct = c.gain and (" (HV %+.0f %%)"):format(c.gain * 100) or ""
  local prices = c.vendor > 0 and ("HV %s net · PNJ %s"):format(ns.money(c.ah), ns.money(c.vendor))
    or ("HV %s net · le PNJ ne le rachète pas"):format(ns.money(c.ah))
  local head
  if c.kind == "ah" then head = "Vendre à l'HV" .. pct
  elseif c.kind == "same" then head = "HV ≈ PNJ" .. pct .. " : PNJ plus simple"
  else head = "Au PNJ, pas la peine à l'HV" .. pct end
  local warn = {}
  if c.slow then warn[#warn + 1] = ("se vend peu (~%.1f/j)"):format(c.s.perDay) end
  if c.unsure then warn[#warn + 1] = "prix affiché, aucune vente vue" end
  return head, prices .. (#warn > 0 and (" · " .. table.concat(warn, ", ")) or "")
end

function Bags.Advice()
  local c = ns.Prof.Char()
  local all = {}
  for id, n in pairs(c.bags or {}) do all[id] = { n, "sacs" } end
  for id, n in pairs(c.bank or {}) do
    if all[id] then all[id][1], all[id][2] = all[id][1] + n, "sacs+banque" else all[id] = { n, "banque" } end
  end
  local out = {}
  for id, v in pairs(all) do
    local e = Bags.Advise(id, v[1])
    if e then e.where = v[2]; out[#out + 1] = e end
  end
  return out
end
