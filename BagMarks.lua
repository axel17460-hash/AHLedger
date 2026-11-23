-- AHLedger - Pastilles HV / PNJ sur les cases des sacs et de la banque de Daylight UI :
-- vert = mieux à l'HV, jaune = à peu près pareil, rouge = au PNJ. Toujours affichées, ou seulement
-- HV ouverte, ou jamais, selon l'option « bagMarks » (/ahl options).
--
-- Passe par l'API publique de Daylight UI : me.Paint("bagslot", …) et API.Attach (voir son API.md).
-- La pastille est dessinée sur le cadre que donne API.Attach, jamais sur les pièces de Daylight UI.
local _, ns = ...

local Marks = { on = true, slots = {}, info = setmetatable({}, { __mode = "k" }) }
ns.BagMarks = Marks

local SIZE = 10

local function markFor(slot)
  local m = Marks.slots[slot]
  if m then return m end
  local A = ns.Look.API()
  local holder = A and A.Attach and A.Attach(slot)
  if not holder then return nil end
  m = {}
  m.edge = holder:CreateTexture(nil, "OVERLAY", nil, 6)
  m.edge:SetSize(SIZE + 2, SIZE + 2)
  m.edge:SetPoint("TOPLEFT", 1, -1)
  m.edge:SetColorTexture(0, 0, 0, 0.85)
  m.dot = holder:CreateTexture(nil, "OVERLAY", nil, 7)
  m.dot:SetSize(SIZE, SIZE)
  m.dot:SetPoint("CENTER", m.edge, "CENTER")
  Marks.slots[slot] = m
  return m
end

local function bound(bag, slot)
  local C = C_Container
  if C and C.GetContainerItemInfo and bag and slot then
    local i = C.GetContainerItemInfo(bag, slot)
    return i and i.isBound
  end
end

-- Type de pastille pour un objet, ou nil
function Marks.KindFor(itemID, bag, slot)
  if not (itemID and Marks.on) then return nil end
  local mode = ns.Options.Get("bagMarks")
  if mode == "off" or (mode == "ah" and not ns.ahOpen) then return nil end
  if bound(bag, slot) then return nil end
  local c = ns.Bags.Compare(itemID)
  return c and c.kind
end

local function paint(slot, info)
  local m = Marks.slots[slot]
  local kind = info and Marks.KindFor(info.itemID, info.bag, info.slot)
  if not kind then
    if m then m.edge:Hide(); m.dot:Hide() end
    return
  end
  m = m or markFor(slot)
  if not m then return end
  local c = ns.Bags.COLORS[kind]
  m.dot:SetColorTexture(c[1], c[2], c[3], 1)
  m.edge:Show(); m.dot:Show()
end

-- Repeint toutes les cases vues (nouveau scan) ; withBags = demander aussi à Daylight UI de
-- remplir ses sacs à nouveau (ouverture et fermeture de l'HV)
function Marks.Refresh(withBags)
  for slot, info in pairs(Marks.info) do ns.safe("pastilles", paint, slot, info) end
  local A = withBags and ns.Look.API()
  if A and A.RefreshBags then pcall(A.RefreshBags) end
end

function Marks.Start()
  if Marks.started then return true end
  local me = ns.Look.Me()
  if not (me and me.Paint) then return false end
  Marks.started = true
  -- info est une table par case, remplie à nouveau à chaque passage : on garde la référence
  me.Paint("bagslot", function(slot, parts, info)
    if info then Marks.info[slot] = info end
    ns.safe("pastilles", paint, slot, info)
  end)
  return true
end

ns.on("PLAYER_LOGIN", function() ns.safe("pastilles", Marks.Start) end)
local function later() C_Timer.After(0, function() ns.safe("pastilles", Marks.Refresh, true) end) end
ns.on("AUCTION_HOUSE_SHOW", later)
ns.on("AUCTION_HOUSE_CLOSED", later)
