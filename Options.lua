-- AHLedger - Options : AHLedgerDB.opt, fenêtre « /ahl options » et page dans les options du jeu
local _, ns = ...

local Options = {}
ns.Options = Options

-- Hors de l'HV, AHLedger ne fait rien : infobulles et pastilles ne se montrent qu'à l'HV.
-- ttAH : infobulle à l'HV ("full", "compact", "off") ; ttShift : Maj affiche le détail complet
-- bagMarks : pastilles des sacs ("on" / "off") ; minimap : bouton sur la minicarte ; mmAngle : sa position (degrés)
local DEFAULTS = { ttAH = "full", ttShift = true, bagMarks = "on", minimap = true }
-- Réglages d'avant, sans objet depuis que tout se passe à l'HV
local OLD_KEYS = { "ttAway", "bagMarksLast" }

function Options.Get(key)
  local o = AHLedgerDB and AHLedgerDB.opt
  local v = o and o[key]
  if v == nil then
    if key == "keepRaw" then return not (AHLedgerDB and AHLedgerDB.keepRaw == false) end
    return DEFAULTS[key]
  end
  -- anciennes valeurs des pastilles : case à cocher, « toujours », « seulement à l'HV » = allumées
  if key == "bagMarks" then return (v == false or v == "off") and "off" or "on" end
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
  -- vide le cache des infobulles. Pas ns.dataVersion : les données n'ont pas changé, et la changer
  -- referait toute l'analyse du royaume (~0,2 s) à chaque clic d'option ou déplacement du bouton
  ns.optVersion = (ns.optVersion or 0) + 1
  if (key == "bagMarks" or key == "bagVerdicts") and ns.BagMarks then
    -- nos cases seulement : redemander à Daylight UI de refaire ses sacs coûte une image de plus
    ns.safe("pastilles", ns.BagMarks.Refresh)
    ns.safe("pastilles", ns.BagMarks.SyncTools)
  end
  if key == "minimap" and ns.MinimapButton then ns.safe("bouton minicarte", ns.MinimapButton.Sync) end
  for _, p in ipairs(panels) do p.Sync() end
end

-- Mode d'infobulle à utiliser maintenant : "full", "compact" ou "off"
-- (hors de l'HV : toujours "off")
function Options.TooltipMode()
  if not ns.isAHOpen() then return "off" end
  local mode = Options.Get("ttAH")
  if mode == "off" then return "off" end
  if Options.Get("ttShift") and IsShiftKeyDown and IsShiftKeyDown() then return "full" end
  return mode
end

-- Retire les réglages d'avant de la sauvegarde
function Options.Cleanup()
  local o = AHLedgerDB and AHLedgerDB.opt
  if not o then return end
  for _, k in ipairs(OLD_KEYS) do o[k] = nil end
  if o.bagMarks ~= nil then o.bagMarks = Options.Get("bagMarks") end
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

  title("Infobulles (à l'hôtel des ventes)")
  radio("ttAH", {
    { "full", "Complète" },
    { "compact", "Courte : HV ou PNJ, prix et tendance" },
    { "off", "Rien" },
  })
  y = y - 6
  check("Maj (Shift) enfoncée : infobulle complète", function() return Options.Get("ttShift") end,
    function(v) Options.Set("ttShift", v) end)
  y = y - 6
  title("Sacs (à l'hôtel des ventes)")
  check("Pastilles HV / PNJ sur les cases", function() return Options.Get("bagMarks") == "on" end,
    function(v) Options.Set("bagMarks", v and "on" or "off") end)
  -- bagVerdicts : éteint par défaut (absent de DEFAULTS), on l'allume pour faire le tri dans ses sacs
  check("Verdicts du bilan sur les cases : perte, stop, prix", function() return Options.Get("bagVerdicts") and true or false end,
    function(v) Options.Set("bagVerdicts", v) end)
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

ns.on("PLAYER_LOGIN", function() ns.safe("options", Options.Cleanup); ns.safe("options", register) end)

-- Maj enfoncée ou relâchée : on redessine l'infobulle d'objet affichée
ns.on("MODIFIER_STATE_CHANGED", function(key)
  if not ns.ahOpen or not (key == "LSHIFT" or key == "RSHIFT") or not Options.Get("ttShift") then return end
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
