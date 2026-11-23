-- AHLedger - Relevé automatique des prix vendeurs PNJ à chaque ouverture de marchand
local _, ns = ...

ns.on("MERCHANT_SHOW", function()
  local db = ns.realmDB()
  local npc = UnitName("npc") or "?"
  local zone = GetZoneText() or "?"
  local n = 0
  for i = 1, GetMerchantNumItems() do
    local name, price, quantity, numAvailable, extendedCost = ns.GetMerchantItem(i)
    local id = ns.itemIdFromLink(GetMerchantItemLink(i))
    -- on ignore les objets payés en monnaie spéciale (insignes, tokens…)
    if id and price and price > 0 and not extendedCost then
      ns.rememberItem(id, name)
      -- prix à l'unité sans arrondi : 10c les 200 flèches font 0,05c, pas 0c
      local per = price / math.max(quantity or 1, 1)
      local v = db.vendor[id]
      -- garde le vendeur le moins cher connu (un ancien relevé arrondi à 0c est remplacé)
      if not v or not v.p or v.p <= 0 or per <= v.p then
        db.vendor[id] = { p = per, lim = numAvailable or -1, npc = npc, zone = zone, t = time() }
      end
      n = n + 1
    end
  end
end)
