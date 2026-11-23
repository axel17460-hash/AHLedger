-- AHLedger - Pastilles HV / PNJ sur les cases des sacs et de la banque de Daylight UI :
-- vert = mieux à l'HV, jaune = à peu près pareil, rouge = au PNJ. Toujours affichées, ou seulement
-- HV ouverte, ou jamais, selon l'option « bagMarks » (/ahl options).
--
-- Passe par l'API publique de Daylight UI : me.Paint("bagslot", …) et API.Attach (voir son API.md).
-- La pastille est dessinée sur le cadre que donne API.Attach, jamais sur les pièces de Daylight UI.
local _, ns = ...

local Marks = { on = true, slots = {}, info = setmetatable({}, { __mode = "k" }) }
ns.BagMarks = Marks

local SIZE = 6     -- petite, pour ne pas cacher l'icône de l'objet
local ALPHA = 0.9

local function markFor(slot)
  local m = Marks.slots[slot]
  if m then return m end
  local A = ns.Look.API()
  local holder = A and A.Attach and A.Attach(slot)
  if not holder then return nil end
  m = {}
  m.edge = holder:CreateTexture(nil, "OVERLAY", nil, 6)
  m.edge:SetSize(SIZE + 2, SIZE + 2)
  m.edge:SetPoint("TOPLEFT", 2, -2)
  m.edge:SetColorTexture(0, 0, 0, 0.6)
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
  m.dot:SetColorTexture(c[1], c[2], c[3], ALPHA)
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

-- Allumer / éteindre les pastilles depuis les sacs. On garde le dernier mode allumé
-- (« toujours » ou « seulement à l'HV ») pour le retrouver au clic suivant.
function Marks.Toggle()
  local mode = ns.Options.Get("bagMarks")
  if mode == "off" then
    ns.Options.Set("bagMarks", ns.Options.Get("bagMarksLast") or "always")
  else
    ns.Options.Set("bagMarksLast", mode)
    ns.Options.Set("bagMarks", "off")
  end
end

-- Bouton « HV » dans la rangée d'outils de la fenêtre des sacs de Daylight UI (tri, emplacements,
-- vue, crochetage…). Daylight UI n'a pas d'appel public pour ajouter un outil : on passe par
-- me.Wrap sur Window.LayoutTools de son module Bags, comme pour l'onglet de l'HV (UI.lua). Le bouton
-- est le nôtre ; on l'ajoute seulement à la liste des outils, et c'est Daylight UI qui le place, à
-- gauche des siens, contre la recherche. Si la voie ne tient plus, l'option reste dans /ahl options.
local tools = setmetatable({}, { __mode = "k" })
local ICON_SIZE, ROW = 14, 22

local function paintTool(b)
  local A = ns.Look.API()
  if not A then return end
  local on = ns.Options.Get("bagMarks") ~= "off"
  if on or b.over then
    b.icon:SetVertexColor(A.Accent())
  else
    local c = A.Colors().LABEL or { 0.6, 0.55, 0.45 }
    b.icon:SetVertexColor(c[1], c[2], c[3])
  end
  b.icon:SetAlpha(on and 1 or 0.6)
end

local MODE_TEXT = { always = "allumées partout", ah = "allumées à l'HV seulement", off = "éteintes" }

local function makeTool(f)
  local A = ns.Look.API()
  local b = CreateFrame("Button", nil, f)
  b:SetSize(ROW, ROW)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(ICON_SIZE, ICON_SIZE)
  b.icon:SetPoint("CENTER")
  b.icon:SetTexture(A and A.Media and A.Media("ui-section-auction.png") or "Interface\\Icons\\INV_Misc_Coin_01")
  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then ns.safe("options", ns.Options.Show) else ns.safe("pastilles", Marks.Toggle) end
  end)
  b:SetScript("OnEnter", function(self)
    self.over = true; paintTool(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("AHLedger : pastilles HV / PNJ")
    GameTooltip:AddLine(("Vert = mieux à l'HV, jaune = pareil, rouge = au PNJ. Actuellement %s."):format(
      MODE_TEXT[ns.Options.Get("bagMarks")] or "?"), 1, 1, 1, true)
    GameTooltip:AddLine("Clic : allumer / éteindre · Clic droit : options", 0.5, 0.8, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self) self.over = false; paintTool(self); GameTooltip:Hide() end)
  paintTool(b)
  return b
end

local function addTool(f)
  if tools[f] or type(f) ~= "table" or type(f.tools) ~= "table" then return end
  local b = makeTool(f)
  tools[f] = b
  f.tools[#f.tools + 1] = b -- dernier de la liste = le plus à gauche, contre la recherche
end

function Marks.SyncTools()
  for _, b in pairs(tools) do paintTool(b) end
end

function Marks.HookBagTools()
  if Marks.toolHooked then return true end
  local me, A = ns.Look.Me(), ns.Look.API()
  local D = DaylightUI
  local mod = type(D) == "table" and type(D.GetModule) == "function" and D:GetModule("Bags")
  local W = type(mod) == "table" and type(mod.ns) == "table" and mod.ns.Window
  if not (me and me.Wrap and A and A.GetFrame and type(W) == "table" and type(W.LayoutTools) == "function") then
    return false
  end
  Marks.toolHooked = true
  me.Wrap(W, "LayoutTools", function(original, f, ...)
    if f and f == A.GetFrame("bags") then ns.safe("bouton des sacs", addTool, f) end
    return original(f, ...)
  end)
  -- fenêtre déjà construite : on y ajoute le bouton tout de suite
  local f = A.GetFrame("bags")
  if f and not tools[f] then W.LayoutTools(f) end
  return true
end

ns.on("ADDON_LOADED", function(name)
  if name == "AHLedger" then ns.safe("bouton des sacs", Marks.HookBagTools) end
end)
ns.on("PLAYER_LOGIN", function() ns.safe("pastilles", Marks.Start); ns.safe("bouton des sacs", Marks.HookBagTools) end)
local function later() C_Timer.After(0, function() ns.safe("pastilles", Marks.Refresh, true) end) end
ns.on("AUCTION_HOUSE_SHOW", later)
ns.on("AUCTION_HOUSE_CLOSED", later)
