-- AHLedger - Fenêtre de classement (/ahl)
local _, ns = ...

local UI = { mode = "market", offset = 0, cat = 1, liquidOnly = true, sortDesc = true }
ns.UI = UI

local ROWS, ROW_H, WIDTH, MAX_COLS, GAP = 16, 20, 820, 8, 6

local CATS = {
  { "Tout", nil },
  { "Matériaux", { [7] = true } },
  { "Consommables", { [0] = true } },
  { "Recettes", { [9] = true } },
  { "Équipement", { [2] = true, [4] = true } },
}

local function itemLabel(id, s)
  local meta = AHLedgerDB.items[id]
  local name = (s and s.name) or (meta and meta.n) or ("#" .. tostring(id))
  local q = (s and s.quality) or (meta and meta.q)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c and c.hex then return c.hex .. name .. "|r" end
  return name
end

local function num(v, fmt) return v and (fmt or "%.0f"):format(v) or "?" end

local MODES = {
  market = {
    title = "Marché",
    sort = "score",
    help = "Classement par score « à farmer » : or échangé par jour × tendance du prix × signaux de stock.",
    cols = {
      { "Objet", 180, function(e) return itemLabel(e.id, e) end, "name" },
      { "Prix/u", 85, function(e) return ns.money(e.price) end, "price", "RIGHT" },
      { "Achat min/u", 85, function(e) return ns.money(e.minNow) end, "minNow", "RIGHT" },
      { "Tend./j", 58, function(e) return ns.pct(e.trend) end, "trend", "RIGHT" },
      { "Vendus/j", 58, function(e) return num(e.perDay) end, "perDay", "RIGHT" },
      { "Stock", 48, function(e) return num(e.stock) end, "stock", "RIGHT" },
      { "Or/jour", 90, function(e) return ns.money(e.gpd) end, "gpd", "RIGHT" },
      { "Signaux", 130, function(e) return table.concat(e.signals, " · ") end, "score" },
    },
    rows = function()
      local out, filter = {}, CATS[UI.cat][2]
      for _, s in ipairs(ns.Analysis.All().list) do
        local okCat = not filter or (s.class and filter[s.class])
        local okLiq = not UI.liquidOnly or (s.perDay and s.perDay >= 1)
        if okCat and okLiq then out[#out + 1] = s end
      end
      return out
    end,
  },
  vendor = {
    title = "Achat PNJ",
    sort = "gpd",
    help = "Objets achetables chez un marchand déjà visité et revendables à profit à l'HV (commission déduite).",
    cols = {
      { "Objet", 170, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Achat PNJ/u", 85, function(e) return ns.money(e.buy) end, "buy", "RIGHT" },
      { "Revente/u", 85, function(e) return ns.money(e.s.price) end, "price", "RIGHT" },
      { "Marge/u", 85, function(e) return ns.money(e.margin) end, "margin", "RIGHT" },
      { "ROI", 50, function(e) return ("%.0f%%"):format(e.roi * 100) end, "roi", "RIGHT" },
      { "Vendus/j", 60, function(e) return num(e.perDay) end, "perDay", "RIGHT" },
      { "Or/jour", 90, function(e) return ns.money(e.gpd) end, "gpd", "RIGHT" },
      { "Vendeur", 100, function(e) return (e.npc or "?") .. " (" .. (e.zone or "?") .. ")" end, "zone" },
    },
    rows = function() return ns.Analysis.VendorFlips() end,
  },
  snipe = {
    title = "Revente PNJ",
    sort = "profit",
    help = "Enchères moins chères que le prix de rachat du PNJ (dernier scan). Clic = rechercher l'objet dans « Parcourir » pour l'acheter.",
    cols = {
      { "Objet", 165, function(e) return itemLabel(e.id) end, "name" },
      { "Qté", 35, function(e) return tostring(e.count) end, "count", "RIGHT" },
      { "Achat/u", 80, function(e) return ns.money(e.cost / e.count) end, "unitCost", "RIGHT" },
      { "PNJ/u", 75, function(e) return ns.money(e.value / e.count) end, "unitValue", "RIGHT" },
      { "Achat total", 85, function(e) return ns.money(e.cost) end, "cost", "RIGHT" },
      { "Bénéfice", 85, function(e) return "|cff40ff40" .. ns.money(e.profit) .. "|r" end, "profit", "RIGHT" },
      { "Type", 60, function(e) return e.kind end, "kind" },
      { "Vendeur", 90, function(e) return e.owner or "?" end, "owner" },
    },
    rows = function()
      local out = {}
      for _, o in ipairs(ns.realmDB().snipes or {}) do out[#out + 1] = o end
      return out
    end,
    onClick = function(e) ns.Snipe.Search(e) end,
  },
  farm = {
    title = "Farm",
    sort = "total",
    help = "Tes sessions /ahl farm, valorisées aux prix actuels. Au-delà du volume que le marché absorbe, le loot est compté au prix PNJ.",
    cols = {
      { "Zone", 170, function(e) return e.zone end, "zone" },
      { "Heures", 55, function(e) return ("%.1f"):format(e.hours) end, "hours", "RIGHT" },
      { "Objets /h", 100, function(e) return ns.money(e.itemsPerHour) end, "itemsPerHour", "RIGHT" },
      { "Or brut /h", 100, function(e) return ns.money(e.moneyPerHour) end, "moneyPerHour", "RIGHT" },
      { "Total /h", 100, function(e) return ns.money(e.total) end, "total", "RIGHT" },
      { "Meilleur objet", 200, function(e) return e.best and itemLabel(e.best) or "-" end, "best" },
    },
    rows = function() return ns.Analysis.FarmZones() end,
  },
}

local function sortValue(e, key)
  if key == "name" then
    local meta = AHLedgerDB.items[e.id]
    return (meta and meta.n) or ""
  end
  local v = e[key]
  if v == nil and e.s then v = e.s[key] end
  return v
end

local function sortRows(rows, key, desc)
  table.sort(rows, function(a, b)
    local va, vb = sortValue(a, key), sortValue(b, key)
    if va == vb then return false end
    if va == nil then return false end
    if vb == nil then return true end
    if type(va) ~= type(vb) then va, vb = tostring(va), tostring(vb) end
    if desc then return va > vb else return va < vb end
  end)
end

local function entryItem(e) return e.id or e.best end

function UI.Build()
  if UI.frame then return end
  local f = CreateFrame("Frame", "AHLedgerFrame", UIParent, "BasicFrameTemplateWithInset")
  UI.frame = f
  f:SetSize(WIDTH, 90 + ROWS * ROW_H + 40)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, "AHLedgerFrame") end -- Échap ferme la fenêtre

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -6)
  title:SetText("AHLedger — " .. ns.realmKey())
  UI.title = title

  -- Onglets
  local x = 12
  UI.modeButtons = {}
  for _, key in ipairs({ "market", "vendor", "snipe", "farm" }) do
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(95, 22)
    b:SetPoint("TOPLEFT", x, -30)
    b:SetText(MODES[key].title)
    b:SetScript("OnClick", function() UI.SetMode(key) end)
    UI.modeButtons[key] = b
    x = x + 98
  end

  -- Filtres (onglet Marché)
  UI.catButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  UI.catButton:SetSize(120, 22)
  UI.catButton:SetPoint("TOPRIGHT", -150, -30)
  UI.catButton:SetScript("OnClick", function()
    UI.cat = UI.cat % #CATS + 1
    UI.offset = 0
    UI.Refresh()
  end)
  UI.liqButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  UI.liqButton:SetSize(130, 22)
  UI.liqButton:SetPoint("TOPRIGHT", -14, -30)
  UI.liqButton:SetScript("OnClick", function()
    UI.liquidOnly = not UI.liquidOnly
    UI.offset = 0
    UI.Refresh()
  end)

  UI.help = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  UI.help:SetPoint("TOPLEFT", 14, -58)
  UI.help:SetWidth(WIDTH - 28)
  UI.help:SetJustifyH("LEFT")

  -- En-têtes cliquables (tri)
  UI.headers = {}
  for i = 1, MAX_COLS do
    local h = CreateFrame("Button", nil, f)
    h:SetHeight(18)
    local fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints()
    h.text = fs
    h:SetScript("OnClick", function()
      local key = MODES[UI.mode].cols[i][4]
      if UI.sortKey == key then UI.sortDesc = not UI.sortDesc else UI.sortKey, UI.sortDesc = key, true end
      UI.Refresh()
    end)
    UI.headers[i] = h
  end

  -- Lignes
  UI.rows = {}
  for r = 1, ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetSize(WIDTH - 28, ROW_H)
    row:SetPoint("TOPLEFT", 14, -78 - r * ROW_H)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    row.cells = {}
    for i = 1, MAX_COLS do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetHeight(ROW_H)
      fs:SetWordWrap(false)
      row.cells[i] = fs
    end
    row:SetScript("OnEnter", function(self)
      local id = self.entry and entryItem(self.entry)
      if id then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. id)
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
      local id = self.entry and entryItem(self.entry)
      if id and IsModifiedClick and IsModifiedClick("CHATLINK") then
        local _, link = ns.GetItemInfo(id)
        if link then ChatEdit_InsertLink(link) end
      elseif self.entry and MODES[UI.mode].onClick then
        MODES[UI.mode].onClick(self.entry)
      end
    end)
    UI.rows[r] = row
  end

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    UI.offset = math.max(0, UI.offset - delta * 3)
    UI.Refresh()
  end)

  UI.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  UI.footer:SetPoint("BOTTOMLEFT", 14, 12)
  UI.footer:SetJustifyH("LEFT")

  local scanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  scanBtn:SetSize(110, 22)
  scanBtn:SetPoint("BOTTOMRIGHT", -12, 8)
  scanBtn:SetText("Scanner l'HV")
  scanBtn:SetScript("OnClick", function() ns.safe("scan", ns.Scan.Start) end)

  UI.SetMode("market")
end

function UI.SetMode(mode)
  UI.mode = mode
  UI.offset = 0
  UI.sortKey = MODES[mode].sort
  UI.sortDesc = true
  local cols = MODES[mode].cols
  local x = 14
  for i = 1, MAX_COLS do
    local col, h = cols[i], UI.headers[i]
    if col then
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", UI.frame, "TOPLEFT", x, -78)
      h:SetWidth(col[2])
      h.text:SetText(col[1])
      h.text:SetJustifyH(col[5] or "LEFT")
      h:Show()
      for _, row in ipairs(UI.rows) do
        local fs = row.cells[i]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", row, "LEFT", x - 14, 0)
        fs:SetWidth(col[2] - 4)
        fs:SetJustifyH(col[5] or "LEFT")
        fs:Show()
      end
      x = x + col[2] + GAP
    else
      h:Hide()
      for _, row in ipairs(UI.rows) do row.cells[i]:SetText(""); row.cells[i]:Hide() end
    end
  end
  local isMarket = mode == "market"
  if isMarket then UI.catButton:Show(); UI.liqButton:Show() else UI.catButton:Hide(); UI.liqButton:Hide() end
  UI.help:SetText(MODES[mode].help)
  UI.Refresh()
end

function UI.Refresh()
  if not UI.frame then return end
  local m = MODES[UI.mode]
  UI.catButton:SetText("Catégorie : " .. CATS[UI.cat][1])
  UI.liqButton:SetText(UI.liquidOnly and "Liquides seulement" or "Tous les volumes")
  UI.title:SetText("AHLedger — " .. ns.realmKey())

  local data = m.rows()
  sortRows(data, UI.sortKey, UI.sortDesc)
  UI.offset = math.min(UI.offset, math.max(0, #data - ROWS))
  for r, row in ipairs(UI.rows) do
    local e = data[UI.offset + r]
    row.entry = e
    if e then
      for i, col in ipairs(m.cols) do row.cells[i]:SetText(col[3](e)) end
      row:Show()
    else
      row:Hide()
    end
  end

  local db = ns.realmDB()
  local nDays, obs = 0, 0
  for _, d in pairs(db.days) do
    nDays = nDays + 1
    obs = obs + d.obs
  end
  UI.footer:SetText(("%d lignes · historique %d j · %.1f h de marché observées · dernier scan : %s"):format(
    #data, nDays, obs / 3600,
    db.lastScanTime and date("%d/%m %H:%M", db.lastScanTime) or "jamais"))
end

function UI.Toggle()
  UI.Build()
  local f = UI.frame
  if UI.embedded then -- ressort la fenêtre de l'HV pour l'afficher seule
    f:SetParent(UIParent)
    f:ClearAllPoints()
    f:SetSize(WIDTH, 90 + ROWS * ROW_H + 40)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    UI.embedded = false
    f:Show(); UI.Refresh()
    return
  end
  if f:IsShown() then f:Hide() else f:Show(); UI.Refresh() end
end

-- Rafraîchit la fenêtre après un scan
function UI.OnData()
  if UI.frame and UI.frame:IsShown() then UI.Refresh() end
end

-- Onglet "AHLedger" dans la barre d'onglets de l'HV (via LibAHTab, fournie par Auctionator)
local function embed(container)
  UI.Build()
  local f = UI.frame
  f:SetParent(container)
  f:ClearAllPoints()
  f:SetAllPoints(container)
  f:SetMovable(false)
  UI.embedded = true
  f:Show()
  UI.Refresh()
end

local function createAHTab()
  if UI.ahTab or not AuctionHouseFrame or not LibStub then return end
  local lib = LibStub("LibAHTab-1-0", true)
  if not lib or lib:DoesIDExist("AHLedger") then return end
  local container = CreateFrame("Frame", nil, AuctionHouseFrame)
  container:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 4, -60)
  container:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -4, 4)
  container:SetScript("OnShow", function() embed(container) end)
  container:SetScript("OnHide", function() if UI.embedded and UI.frame then UI.frame:Hide() end end)
  lib:CreateTab("AHLedger", container, "AHLedger", "AHLedger — analyse du marché")
  UI.ahTab = container
end

ns.on("AUCTION_HOUSE_SHOW", function() ns.safe("onglet HV", createAHTab) end)
-- Rien d'AHLedger ne reste à l'écran quand on quitte l'HV
ns.on("AUCTION_HOUSE_CLOSED", function()
  if UI.embedded and UI.frame then UI.frame:Hide() end
end)
