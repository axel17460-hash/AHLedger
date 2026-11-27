-- AHLedger - Bouton sur la minicarte (clic : fenêtre, clic droit : options)
--
-- Avec Daylight UI : un carré de plus dans la colonne de boutons du coin haut-droit de sa carte,
-- sous le calendrier et la loupe, avec leur allure (fond sombre, pictogramme gris, couleur d'accent
-- au survol) et comme eux visible seulement quand la souris passe sur la carte. Tout passe par son
-- API publique (Skin, Media, Colors, Accent). Le bouton est rattaché à UIParent et non à la carte :
-- le tiroir à boutons de Daylight UI ramasse les enfants de la carte et l'aurait rangé dans sa bande.
--
-- Sans Daylight UI : le bouton rond habituel au bord de la carte, qu'on fait glisser autour.
local _, ns = ...

local MM = {}
ns.MinimapButton = MM

MM.SIZE = 24          -- comme les boutons de la carte de Daylight UI
MM.INSET, MM.GAP = 4, 2
MM.SLOT = 3           -- 1 = calendrier, 2 = loupe (suivi), 3 = AHLedger
MM.GLYPH = 14
MM.GLYPH_FILE = "ui-section-auction.png"
MM.ICON = "Interface\\Icons\\INV_Misc_Coin_01"
MM.DEFAULT_ANGLE = 200 -- sans Daylight UI : degrés, 0 = droite, bas-gauche de la carte
MM.FADE = 6           -- vitesse du fondu (opacité par seconde)

local function daylight() return ns.Look.API() end

-- Sans Daylight UI : au bord de la carte, à l'angle donné (carte ronde : sur l'anneau ; carrée :
-- le long du bord, juste à l'intérieur)
function MM.Place(angle)
  local b = MM.button
  if not b or not Minimap then return end
  b:ClearAllPoints()
  if daylight() then
    b:SetPoint("TOPRIGHT", Minimap, "TOPRIGHT", -MM.INSET, -MM.INSET - (MM.SLOT - 1) * (MM.SIZE + MM.GAP))
    return
  end
  local a = math.rad(angle or MM.DEFAULT_ANGLE)
  local x, y = math.cos(a), math.sin(a)
  local w, h = Minimap:GetWidth() / 2, Minimap:GetHeight() / 2
  if type(GetMinimapShape) == "function" and GetMinimapShape() == "SQUARE" then
    local inset = b:GetWidth() / 2 + 2
    local m = math.max(math.abs(x), math.abs(y))
    x, y = x / m * (w - inset), y / m * (h - inset)
  else
    x, y = x * (w + 10), y * (h + 10)
  end
  b:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function angle() return ns.Options.Get("mmAngle") or MM.DEFAULT_ANGLE end

local function cursorAngle()
  local cx, cy = Minimap:GetCenter()
  local s = Minimap:GetEffectiveScale()
  local mx, my = GetCursorPosition()
  return math.deg(math.atan2(my / s - cy, mx / s - cx)) % 360
end

local function tooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("AHLedger")
  local db = ns.realmDB()
  GameTooltip:AddDoubleLine("Dernier scan", db.lastScanTime and date("%d/%m %H:%M", db.lastScanTime) or "jamais",
    0.8, 0.8, 0.8, 1, 1, 1)
  local ok, _, t = pcall(ns.Ledger.Summary)
  if ok and type(t) == "table" and t.revenue then
    local net = t.revenue - t.spent
    GameTooltip:AddDoubleLine(("Bilan %d j"):format(ns.Ledger.DAYS), (net >= 0 and "|cff40ff40" or "|cffff5050") .. ns.money(net) .. "|r",
      0.8, 0.8, 0.8)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Clic : ouvrir / fermer la fenêtre", 0.5, 0.8, 1)
  GameTooltip:AddLine("Clic droit : options", 0.5, 0.8, 1)
  if not daylight() then GameTooltip:AddLine("Glisser : déplacer autour de la carte", 0.5, 0.8, 1) end
  GameTooltip:Show()
end

-- Pictogramme gris au repos, couleur d'accent sous la souris (comme la loupe de Daylight UI)
local function paint(b)
  local A = daylight()
  if not (A and b.glyph) then return end
  if b:IsMouseOver() then
    b.glyph:SetVertexColor(A.Accent())
  else
    local c = A.Colors().LABEL
    if c then b.glyph:SetVertexColor(c[1], c[2], c[3]) end
  end
end

-- Fondu : visible quand la souris est sur la carte ou sur le bouton, comme les autres boutons
local function fade(b, elapsed)
  local want = (Minimap:IsMouseOver() or b:IsMouseOver()) and 1 or 0
  local a = b:GetAlpha()
  if a ~= want then
    local step = (elapsed or 0.1) * MM.FADE
    b:SetAlpha(want > a and math.min(want, a + step) or math.max(want, a - step))
  end
  paint(b)
end

local function dressDaylight(b, A)
  b:SetSize(MM.SIZE, MM.SIZE)
  A.Skin(b, { noBevel = true, bgAlpha = 0.6 })
  local g = b:CreateTexture(nil, "OVERLAY")
  g:SetTexture(A.Media and A.Media(MM.GLYPH_FILE) or ("Interface\\AddOns\\DaylightUI\\Media\\" .. MM.GLYPH_FILE))
  g:SetSize(MM.GLYPH, MM.GLYPH)
  g:SetPoint("CENTER")
  b.glyph = g
  b:SetAlpha(0)
  b:SetScript("OnUpdate", fade)
  paint(b)
end

local function dressClassic(b)
  b:SetSize(31, 31)
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(MM.ICON)
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER", 0, 1)
  local ring = b:CreateTexture(nil, "OVERLAY")
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetSize(53, 53)
  ring:SetPoint("TOPLEFT")
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20)
  bg:SetPoint("CENTER", 0, 1)
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", function(self)
    GameTooltip:Hide()
    self:SetScript("OnUpdate", function() MM.Place(cursorAngle()) end)
  end)
  b:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    ns.Options.Set("mmAngle", math.floor(cursorAngle() + 0.5))
  end)
end

function MM.Build()
  if MM.button or not Minimap then return MM.button end
  local b = CreateFrame("Button", "AHLedgerMinimapButton", UIParent)
  b:SetFrameStrata(Minimap:GetFrameStrata() or "LOW")
  b:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 6)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local A = daylight()
  if A then dressDaylight(b, A) else dressClassic(b) end
  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then ns.safe("options", ns.Options.Toggle) else ns.safe("fenêtre", ns.UI.Toggle) end
  end)
  b:SetScript("OnEnter", function(self) paint(self); ns.safe("bouton minicarte", tooltip, self) end)
  b:SetScript("OnLeave", function(self) paint(self); GameTooltip:Hide() end)
  MM.button = b
  return b
end

-- Affiche ou cache le bouton selon l'option
function MM.Sync()
  if ns.Options.Get("minimap") then
    local b = MM.Build()
    if b then MM.Place(angle()); b:Show() end
  elseif MM.button then
    MM.button:Hide()
  end
end

ns.on("PLAYER_LOGIN", function() ns.safe("bouton minicarte", MM.Sync) end)
