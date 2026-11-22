-- AHLedger - Infos marché dans les tooltips d'objets
local _, ns = ...

local function addLines(tooltip, id)
  if not id or not AHLedgerDB then return end
  local s = ns.Analysis.Get(id)
  if not s then return end
  tooltip:AddLine(" ")
  tooltip:AddDoubleLine("|cff33ccffAHLedger|r " .. (s.realPrice and "prix de vente réel" or "prix affiché"),
    ns.money(s.price), 1, 1, 1, 1, 1, 1)
  if s.minNow then
    tooltip:AddDoubleLine("Achat le moins cher /u (dernier scan)", ns.money(s.minNow), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  tooltip:AddDoubleLine("Tendance /jour", ns.pct(s.trend), 0.8, 0.8, 0.8, 1, 1, 1)
  tooltip:AddDoubleLine("Vendus /jour (estim.)",
    s.perDay and ("%.0f  (stock %.0f)"):format(s.perDay, s.stock or 0) or "?", 0.8, 0.8, 0.8, 1, 1, 1)
  if #s.signals > 0 then
    tooltip:AddLine(table.concat(s.signals, " · "), 1, 0.82, 0)
  end
  tooltip:Show()
end

local function idFromTooltip(tooltip)
  local _, link = tooltip:GetItem()
  return ns.itemIdFromLink(link)
end

-- Clients récents (API TooltipDataProcessor) ou client Classic (OnTooltipSetItem)
if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip == GameTooltip or tooltip == ItemRefTooltip then
      addLines(tooltip, data and data.id or idFromTooltip(tooltip))
    end
  end)
else
  for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tt then tt:HookScript("OnTooltipSetItem", function(self) addLines(self, idFromTooltip(self)) end) end
  end
end
