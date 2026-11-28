-- AHLedger - Tes sacs et ta banque : ce que tu as, et pour chaque objet la décision de Decide.lua
-- (vendre à l'HV, au PNJ, tester, fabriquer, attendre).
--
-- Les sacs sont relus seulement à l'HV ; la banque garde sa dernière photo, refaite par
-- /ahl banque, banque ouverte.
local _, ns = ...

local Bags = {}
ns.Bags = Bags


-- C_Container lu à chaque appel (pas figé au chargement)
local function numSlots(bag)
  local C = C_Container
  if C and C.GetContainerNumSlots then return C.GetContainerNumSlots(bag) or 0 end
  return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end
local function slotItem(bag, slot)
  local C = C_Container
  if C and C.GetContainerItemInfo then
    local i = C.GetContainerItemInfo(bag, slot)
    if i then return i.itemID, i.stackCount, i.isBound end
    return nil
  end
  if GetContainerItemInfo then
    local _, count, _, _, _, _, link, _, _, id, isBound = GetContainerItemInfo(bag, slot)
    return id or ns.itemIdFromLink(link), count, isBound
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

-- Sacs portés : 0 (sac à dos) à 4, plus le sac de composants (5) sur les clients récents comme
-- Forever (NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5). La banque : -1, puis ses sacs, qui suivent les tiens.
local function lastBag() return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 end
local function range(a, b, t)
  t = t or {}
  for i = a, b do t[#t + 1] = i end
  return t
end
local function bagList() return range(0, lastBag()) end
local function bankList()
  local first = lastBag() + 1
  return range(first, first + (NUM_BANKBAGSLOTS or 7) - 1, { -1 })
end
Bags.BagList, Bags.BankList = bagList, bankList
-- Lecture d'une case avec repli sur les anciennes fonctions (BagMarks s'en sert aussi)
Bags.NumSlots, Bags.SlotItem = numSlots, slotItem

function Bags.ScanBags()
  local c = ns.Prof.Char()
  c.bags = read(bagList())
  -- Avant la 0.9, le sac de composants était lu avec la banque : on retire une fois son contenu de
  -- l'ancienne photo de la banque (refaite proprement à ta prochaine visite)
  if c.bank and (c.bankLayout or 1) < 2 and lastBag() >= 5 then
    for id, n in pairs(read(range(5, lastBag()))) do
      local b = c.bank[id]
      if b then c.bank[id] = b > n and b - n or nil end
    end
  end
  c.bankLayout = 2
  ns.bagVersion = (ns.bagVersion or 0) + 1
  for id in pairs(c.bags) do ns.rememberItem(id) end
  if ns.UI then ns.UI.OnData() end
end

function Bags.ScanBank()
  local c = ns.Prof.Char()
  c.bank = read(bankList())
  c.bankLayout = 2
  ns.bagVersion = (ns.bagVersion or 0) + 1
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
-- Hors de l'HV, AHLedger ne fait rien : les sacs sont relus à l'ouverture de l'HV et quand ils
-- changent pendant qu'elle est ouverte. La banque n'est relue que par /ahl banque.
ns.on("AUCTION_HOUSE_SHOW", scheduleBags)
ns.on("BAG_UPDATE_DELAYED", function() if ns.ahOpen then scheduleBags() end end)

-- Conseil pour un objet possédé en n exemplaires : la décision de Decide, sous la forme qu'attendent
-- l'vue « Sacs et banque » et le rapport. nil : moins de 1 pa en tout, ou rien à en faire.
function Bags.Advise(id, n)
  local d = ns.Decide.For(id, n)
  if not d or (d.value or 0) < ns.Decide.MIN_VALUE then return nil end
  return { id = id, s = d.s, count = n, vendor = d.vendor, d = d, action = d.action,
           post = (d.action == "HV" or d.action == "Tester") and d.post or nil, postQty = d.qty,
           unit = d.unit, value = d.value, why = ns.Decide.Why(d), craftUp = d.craft }
end

-- Combien tu en as (sacs + banque)
function Bags.Count(id)
  local c = ns.Prof.Char()
  return ((c.bags or {})[id] or 0) + ((c.bank or {})[id] or 0)
end

-- Pastille d'un objet des sacs : { kind = décision } ou nil (garder, attendre, rien à dire)
Bags.COLORS = ns.Decide.COLORS
function Bags.Compare(id)
  local d = ns.Decide.For(id, math.max(Bags.Count(id), 1))
  if d and ns.Decide.MARKS[d.action] then return { kind = d.action, d = d } end
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
    if e then
      e.where, e.bags, e.bank = v[2], (c.bags or {})[id] or 0, (c.bank or {})[id] or 0
      out[#out + 1] = e
    end
  end
  return out
end
