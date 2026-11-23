-- AHLedger - Options : AHLedgerDB.opt, fenêtre « /ahl options » et page dans les options du jeu
local _, ns = ...

local Options = {}
ns.Options = Options

-- ttAway : infobulle hors de l'HV ; ttAH : infobulle à l'HV ; ttShift : Maj affiche le détail complet
-- minimap : bouton sur la minicarte ; mmAngle : sa position autour de la carte (degrés)
local DEFAULTS = { ttAway = "compact", ttAH = "full", ttShift = true, bagMarks = "always", minimap = true }

function Options.Get(key)
  local o = AHLedgerDB and AHLedgerDB.opt
  local v = o and o[key]
  if v == nil then
    if key == "keepRaw" then return not (AHLedgerDB and AHLedgerDB.keepRaw == false) end
    return DEFAULTS[key]
  end
  -- ancienne case à cocher des pastilles : coché = toujours, décoché = jamais
  if key == "bagMarks" and type(v) == "boolean" then return v and "always" or "off" end
  return v
end

local panels = {}

function Options.Set(key, value)
  if key == "keepRaw" then
    AHLedgerDB.keepRaw = value and true or false
  else
    AHLedgerDB.opt = AHLedgerDB.opt or {}
    AHLedgerDB.opt[key] = value
  end
  ns.dataVersion = (ns.dataVersion or 0) + 1 -- vide le cache des infobulles
  if key == "bagMarks" and ns.BagMarks then ns.safe("pastilles", ns.BagMarks.Refresh, true) end
  if key == "minimap" and ns.MinimapButton then ns.safe("bouton minicarte", ns.MinimapButton.Sync) end
  for _, p in ipairs(panels) do p.Sync() end
end

-- Mode d'infobulle à utiliser maintenant : "full", "compact" ou "off"
function Options.TooltipMode()
  if Options.Get("ttShift") and IsShiftKeyDown and IsShiftKeyDown() then return "full" end
  return ns.isAHOpen() and Options.Get("ttAH") or Options.Get("ttAway")
end

-- Contenu (cases à cocher), construit dans un cadre parent ; renvoie la hauteur utilisée
local function build(parent, top)
  local Look = ns.Look
  local syncs = {}
  local y = top or -16

  local function title(text)
    local fs = Look.Text(parent, "head", "LABEL", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    y = y - 22
  end

  local function check(text, isOn, onClick, indent)
    local b = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    b:SetSize(24, 24)
    b:SetPoint("TOPLEFT", 16 + (indent or 0), y)
    local fs = Look.Text(parent, "body", "TEXT", "GameFontHighlight")
    fs:SetPoint("LEFT", b, "RIGHT", 4, 0)
    fs:SetText(text)
    b:SetScript("OnClick", function(self) ns.safe("options", onClick, self:GetChecked() and true or false) end)
    syncs[#syncs + 1] = function() b:SetChecked(isOn()) end
    y = y - 26
  end

  -- Choix exclusif entre plusieurs valeurs d'une même option
  local function radio(key, choices)
    for _, c in ipairs(choices) do
      check(c[2], function() return Options.Get(key) == c[1] end, function() Options.Set(key, c[1]) end, 12)
    end
  end

  title("Infobulles hors de l'hôtel des ventes")
  radio("ttAway", {
    { "compact", "Courte : HV ou PNJ, prix et tendance" },
    { "full", "Complète" },
    { "off", "Rien" },
  })
  y = y - 6
  title("Infobulles à l'hôtel des ventes")
  radio("ttAH", {
    { "full", "Complète" },
    { "compact", "Courte" },
  })
  y = y - 6
  check("Maj (Shift) enfoncée : infobulle complète", function() return Options.Get("ttShift") end,
    function(v) Options.Set("ttShift", v) end)
  y = y - 6
  title("Pastilles HV / PNJ sur les sacs et la banque")
  radio("bagMarks", {
    { "always", "Toujours" },
    { "ah", "Seulement à l'hôtel des ventes" },
    { "off", "Jamais" },
  })
  y = y - 6
  title("Divers")
  check("Bouton sur la minicarte", function() return Options.Get("minimap") end,
    function(v) Options.Set("minimap", v) end)
  check("Garder les scans bruts pour l'export Python", function() return Options.Get("keepRaw") end,
    function(v) Options.Set("keepRaw", v) end)

  local p = { Sync = function() for _, s in ipairs(syncs) do s() end end }
  panels[#panels + 1] = p
  p.Sync()
  return -y + 10
end

-- Fenêtre propre (skin Daylight UI si présent), ouverte par /ahl options ou le bouton de la fenêtre
function Options.Show()
  if not Options.window then
    local w = ns.Look.Window("AHLedgerOptions", 360, 100, "DIALOG")
    w.titleText:SetText("AHLedger – Options")
    local h = build(w, -40 - ns.Look.Top())
    w:SetHeight(h)
    ns.Look.Reskin(w)
    Options.window = w
  end
  for _, p in ipairs(panels) do p.Sync() end
  Options.window:Show()
end

function Options.Toggle()
  if Options.window and Options.window:IsShown() then Options.window:Hide() else Options.Show() end
end

-- Page « AHLedger » dans les options d'interface du jeu (selon l'API du client)
local function register()
  local panel = CreateFrame("Frame")
  panel.name = "AHLedger"
  local head = ns.Look.Text(panel, "title", "LABEL", "GameFontNormalLarge")
  head:SetPoint("TOPLEFT", 16, -16)
  head:SetText("AHLedger")
  build(panel, -44)
  panel:SetScript("OnShow", function() for _, p in ipairs(panels) do p.Sync() end end)
  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local cat = Settings.RegisterCanvasLayoutCategory(panel, "AHLedger")
    Settings.RegisterAddOnCategory(cat)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
end

ns.on("PLAYER_LOGIN", function() ns.safe("options", register) end)

-- Maj enfoncée ou relâchée : on redessine l'infobulle d'objet affichée
ns.on("MODIFIER_STATE_CHANGED", function(key)
  if not (key == "LSHIFT" or key == "RSHIFT") or not Options.Get("ttShift") then return end
  ns.safe("infobulle Maj", function()
    if GameTooltip and GameTooltip:IsShown() and GameTooltip:GetItem() then
      local owner = GameTooltip:GetOwner()
      local onEnter = owner and owner.GetScript and owner:GetScript("OnEnter")
      if onEnter then onEnter(owner)
      elseif owner and owner.UpdateTooltip then owner:UpdateTooltip() end
    end
    if ItemRefTooltip and ItemRefTooltip:IsShown() then
      local _, link = ItemRefTooltip:GetItem()
      if link then ItemRefTooltip:SetHyperlink(link) end
    end
  end)
end)
