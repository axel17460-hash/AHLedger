-- AHLedger - Infos marché dans les tooltips d'objets : ce qu'Auctionator n'affiche pas
local _, ns = ...

local UP = "|TInterface\\Buttons\\Arrow-Up-Up:14:14|t"
local DOWN = "|TInterface\\Buttons\\Arrow-Down-Up:14:14|t"

-- "+4.2 %/j" coloré avec flèche
local function trendText(v, suffix)
  if not v then return "|cff808080pas assez de scans|r" end
  local arrow = v >= 0.02 and UP or (v <= -0.02 and DOWN or "")
  return arrow .. ns.pct(v) .. (suffix or "")
end

local function verdict(s)
  local t = s.trend24 or s.trend
  if not t then return nil end
  local rising, falling = t >= 0.03, t <= -0.03
  local cheap = s.vsAvg and s.vsAvg <= -0.10
  local dear = s.vsAvg and s.vsAvg >= 0.10
  if rising and cheap then return "|cff40ff40Prix en hausse et sous la moyenne : bon moment pour acheter / farmer|r" end
  if rising then return "|cff40ff40Prix en hausse : garder son stock, farmer|r" end
  if falling and dear then return "|cffff5050Prix en baisse et encore cher : vendre maintenant|r" end
  if falling then return "|cffff5050Prix en baisse : vendre vite, ne pas stocker|r" end
  if cheap then return "|cffffd100Prix stable mais sous la moyenne : achat intéressant|r" end
  return "|cffccccccMarché stable|r"
end

local function addLines(tooltip, id)
  if not id or not AHLedgerDB then return end
  local s = ns.Analysis.Get(id)
  if not s then return end
  tooltip:AddLine(" ")
  tooltip:AddLine("|cff33ccffAHLedger|r")
  tooltip:AddDoubleLine("Tendance 24 h",
    trendText(s.trend24, s.n24 and (" /j  (%d scans, %.0f h)"):format(s.n24, s.span24) or nil), 0.8, 0.8, 0.8, 1, 1, 1)
  tooltip:AddDoubleLine("Tendance 7 j" .. (s.trendSrc and " (Auctionator)" or ""), trendText(s.trend, " /j"),
    0.8, 0.8, 0.8, 1, 1, 1)
  if s.minNow then
    local vs = s.vsAvg and ("  (%s vs moy. 7 j)"):format(ns.pct(s.vsAvg)) or ""
    tooltip:AddDoubleLine("Achat le moins cher /u", ns.money(s.minNow) .. vs, 0.8, 0.8, 0.8, 1, 1, 1)
  end
  if s.realPrice then
    tooltip:AddDoubleLine("Prix réel de vente /u", ns.money(s.realPrice), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  if s.perDay then
    tooltip:AddDoubleLine("Vendus /jour (estim.)", ("%.0f  (stock %.0f)"):format(s.perDay, s.stock or 0),
      0.8, 0.8, 0.8, 1, 1, 1)
  end
  if s.sellThrough or s.sellers then
    local parts = {}
    if s.sellThrough then parts[#parts + 1] = ("%.0f%% vendues"):format(s.sellThrough * 100) end
    if s.stockDays then parts[#parts + 1] = ("%.1f j de stock"):format(s.stockDays) end
    if s.sellers then parts[#parts + 1] = ("%d vendeurs (top %.0f%%)"):format(s.sellers, (s.topShare or 0) * 100) end
    tooltip:AddDoubleLine("Écoulement", table.concat(parts, " · "), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  if s.netExp then
    tooltip:AddDoubleLine("Net /u (commission, dépôts)", ns.money(s.netExp), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  local rel = ns.Prof and ns.Prof.Related()[id]
  if rel then
    local label = { ["dépeçage"] = "Tu peux le dépecer", artisanat = "Tu sais le fabriquer", composant = "Composant d'une de tes recettes" }
    tooltip:AddLine(label[rel] or rel, 0.6, 0.9, 1)
  end
  local v = verdict(s)
  if v then tooltip:AddLine(v, 1, 1, 1, true) end
  local sig = {}
  for _, x in ipairs(s.signals) do if x ~= "hausse" and x ~= "baisse" then sig[#sig + 1] = x end end
  if #sig > 0 then tooltip:AddLine(table.concat(sig, " · "), 1, 0.82, 0) end
  tooltip:Show()
end

local function idFromTooltip(tooltip)
  local _, link = tooltip:GetItem()
  return ns.itemIdFromLink(link)
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip == GameTooltip or tooltip == ItemRefTooltip then
      ns.safe("tooltip", addLines, tooltip, data and data.id or idFromTooltip(tooltip))
    end
  end)
else
  for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tt then tt:HookScript("OnTooltipSetItem", function(self) ns.safe("tooltip", addLines, self, idFromTooltip(self)) end) end
  end
end
