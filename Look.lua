-- AHLedger - Apparence des fenêtres
--
-- Avec Daylight UI, les fenêtres d'AHLedger prennent son allure (coque de fenêtre, police, couleurs
-- et boutons du joueur) par son API publique DaylightUI.API (voir son API.md). Sans Daylight UI,
-- ce sont les modèles du jeu, comme avant. Aucun code de Daylight UI n'est repris ici : on appelle
-- seulement ses fonctions publiques.
local _, ns = ...

local Look = {}
ns.Look = Look

-- L'API de Daylight UI, ou nil (absente, ou version majeure inconnue)
local function api()
  local D = DaylightUI
  local A = type(D) == "table" and D.API
  if type(A) == "table" and A.major == 1 and A.Skin and A.Text and A.Button and A.Close and A.Colors then
    return A
  end
end
Look.API = api

function Look.Daylight() return api() ~= nil end

-- Hauteur de la barre de titre de la coque Daylight UI (titre à gauche, croix à droite)
function Look.Top() return api() and 14 or 0 end

-- Tailles de texte : celles de Daylight UI, sinon les polices du jeu équivalentes
local FONTS = {
  title = "GameFontHighlight", head = "GameFontNormal", body = "GameFontHighlightSmall",
  small = "GameFontHighlightSmall", tiny = "GameFontDisableSmall",
}

-- Couleur de texte Daylight UI (VALUE, TEXT, LABEL, OFF, GOOD, WARN, BAD) ; sans Daylight UI on
-- garde la couleur de la police du jeu
function Look.Color(fs, key)
  local A = api()
  local c = A and key and A.Colors()[key]
  if c then fs:SetTextColor(c[1], c[2], c[3]) end
  return fs
end

function Look.Text(parent, size, color, gameFont)
  local A = api()
  local fs
  if A then
    fs = A.Text(parent, size)
  else
    fs = parent:CreateFontString(nil, "OVERLAY", gameFont or FONTS[size] or FONTS.body)
  end
  return Look.Color(fs, color)
end

function Look.Button(parent, text, width, height)
  local A = api()
  local b
  if A then
    b = A.Button(parent, text, height or 22)
    -- le libellé d'un bouton Daylight UI est sa propre police b.text, pas celle du bouton du jeu
    b.SetText = function(self, t) self.text:SetText(t) end
  else
    b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetText(text)
  end
  b:SetSize(width, height or 22)
  return b
end

-- Onglet actif : texte à la couleur d'accent avec Daylight UI, surbrillance verrouillée sinon
function Look.Selected(b, on)
  local A = api()
  if A and b.text then
    if on then
      b.text:SetTextColor(A.Accent())
    else
      Look.Color(b.text, "TEXT")
    end
  elseif b.LockHighlight then
    if on then b:LockHighlight() else b:UnlockHighlight() end
  end
end

-- Surbrillance d'une ligne survolée
function Look.RowHighlight(row)
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  local A = api()
  if A then
    local r, g, b = A.Accent()
    hl:SetColorTexture(r, g, b, 0.12)
  else
    hl:SetColorTexture(1, 1, 1, 0.08)
  end
  return hl
end

-- Fond légèrement plus sombre pour une zone de texte (rapport)
function Look.Inset(frame)
  local A = api()
  if A then A.Skin(frame, { noBevel = true, bgAlpha = 0.35 }) end
end

-- Fenêtre déplaçable, fermée par Échap. Renvoie la fenêtre ; f.titleText est son titre.
function Look.Window(name, width, height, strata)
  local A = api()
  local f
  if A then
    f = CreateFrame("Frame", name, UIParent)
    f:SetSize(width, height + Look.Top())
    A.Skin(f, { window = true })
    f.titleText = A.Text(f, "title")
    f.titleText:SetPoint("TOPLEFT", 16, -12)
    f.closeButton = A.Close(f, function() f:Hide() end)
    f.closeButton:SetPoint("TOPRIGHT", -10, -10)
  else
    f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(width, height)
    f.titleText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.titleText:SetPoint("TOP", 0, -6)
  end
  f:SetPoint("CENTER")
  f:SetFrameStrata(strata or "HIGH")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, name) end -- Échap ferme la fenêtre
  return f
end

-- À rappeler après avoir changé la taille d'une fenêtre (la coque Daylight UI suit sa taille)
function Look.Reskin(f)
  local A = api()
  if A then A.Skin(f, { window = true }) end
end

-- Appels de Daylight UI liés au nom de l'addon (movers, etc.), ou nil
function Look.Me()
  local A = api()
  if A and A.For then
    if not Look.me then Look.me = A.For("AHLedger") end
    return Look.me
  end
end

-- DaylightUI_AuctionHouse remplace la fenêtre HV du jeu (gardée ouverte mais invisible) :
-- l'onglet ajouté par LibAHTab ne se voit plus.
function Look.DaylightAH()
  local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
  return api() ~= nil and loaded ~= nil and loaded("DaylightUI_AuctionHouse") and true or false
end
