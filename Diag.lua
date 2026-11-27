-- AHLedger - Diagnostic (/ahl diag) : quelles fonctions du jeu sont présentes sur ce client,
-- quelle variante (Classic ou Retail) chaque module utilise, et ce que l'addon a déjà collecté.
-- Le résultat est aussi enregistré (AHLedgerDB.diag) et ajouté au rapport pour Claude.
local _, ns = ...

local Diag = {}
ns.Diag = Diag

-- Résout "C_AuctionHouse.ReplicateItems" dans l'environnement global
local function has(path)
  local v = _G
  for part in path:gmatch("[^%.]+") do
    if type(v) ~= "table" then return false end
    v = v[part]
  end
  return v ~= nil
end

local function all(list)
  for _, p in ipairs(list) do if not has(p) then return false, p end end
  return true
end

-- Chaque module : liste de variantes { nom, { fonctions requises } } ; la première complète est utilisée
Diag.FEATURES = {
  { "Scan HV", {
    { "Auctionator", { "Auctionator.State.FullScanFrameRef", "Auctionator.EventBus" } },
    { "Retail (ReplicateItems)", { "C_AuctionHouse.ReplicateItems", "C_AuctionHouse.GetNumReplicateItems",
                                   "C_AuctionHouse.GetReplicateItemInfo", "C_AuctionHouse.GetReplicateItemTimeLeft" } },
    { "Classic (getAll)", { "QueryAuctionItems", "GetNumAuctionItems", "GetAuctionItemInfo", "CanSendAuctionQuery" } },
  } },
  { "Infos objets", {
    { "C_Item", { "C_Item.GetItemInfo" } },
    { "Classic", { "GetItemInfo" } },
  } },
  { "Recherche d'un objet", {
    { "Auctionator", { "Auctionator.API.v1.MultiSearch" } },
    { "Classic", { "QueryAuctionItems" } },
  } },
  { "Onglet dans l'HV", {
    { "LibAHTab", { "LibStub", "AuctionHouseFrame" } },
  } },
  { "Marchands", {
    { "Classic", { "GetMerchantNumItems", "GetMerchantItemInfo", "GetMerchantItemLink" } },
    { "Retail", { "GetMerchantNumItems", "C_MerchantFrame.GetItemInfo", "GetMerchantItemLink" } },
  } },
  { "Sacs et banque", {
    { "Retail", { "C_Container.GetContainerNumSlots", "C_Container.GetContainerItemInfo" } },
    { "Classic", { "GetContainerNumSlots", "GetContainerItemInfo" } },
  } },
  { "Courrier (bilan)", {
    { "Factures", { "GetInboxNumItems", "GetInboxHeaderInfo", "GetInboxInvoiceInfo", "GetInboxItemLink",
                    "AUCTION_EXPIRED_MAIL_SUBJECT" } },
  } },
  { "Mes enchères", {
    { "Retail", { "C_AuctionHouse.GetNumOwnedAuctions", "C_AuctionHouse.GetOwnedAuctionInfo" } },
    { "Classic", { "GetNumAuctionItems", "GetAuctionItemInfo" } },
  } },
  { "Niveaux de métier", {
    { "Classic", { "GetNumSkillLines", "GetSkillLineInfo" } },
    { "Retail", { "GetProfessions", "GetProfessionInfo" } },
  } },
  { "Recettes", {
    { "Classic", { "GetNumTradeSkills", "GetTradeSkillLine", "GetTradeSkillInfo", "GetTradeSkillItemLink",
                   "GetTradeSkillNumReagents", "GetTradeSkillReagentInfo", "GetTradeSkillReagentItemLink" } },
    { "Retail", { "C_TradeSkillUI.GetAllRecipeIDs", "C_TradeSkillUI.GetRecipeSchematic", "C_TradeSkillUI.GetRecipeInfo" } },
  } },
  { "Tooltips", {
    { "Retail", { "TooltipDataProcessor.AddTooltipPostCall" } },
    { "Classic", { "GameTooltip.HookScript" } },
  } },
}

function Diag.Run()
  local lines, ok = {}, true
  for _, f in ipairs(Diag.FEATURES) do
    local used, firstMissing
    for _, variant in ipairs(f[2]) do
      local good, missing = all(variant[2])
      if good then used = variant[1]; break end
      firstMissing = firstMissing or (variant[1] .. " : " .. missing)
    end
    if used then
      lines[#lines + 1] = ("OK   %s : %s"):format(f[1], used)
    else
      ok = false
      lines[#lines + 1] = ("MANQUE %s (%s)"):format(f[1], firstMissing or "?")
    end
  end
  -- événements que le client ne connaît pas (ignorés à l'enregistrement)
  local bad = {}
  for ev in pairs(ns.invalidEvents or {}) do bad[#bad + 1] = ev end
  table.sort(bad)
  if #bad > 0 then lines[#lines + 1] = "Événements inconnus de ce client : " .. table.concat(bad, ", ") end
  if ns.errors and #ns.errors > 0 then
    lines[#lines + 1] = ("Erreurs depuis la connexion : %d (dernière : %s)"):format(#ns.errors, ns.errors[#ns.errors])
  end

  -- données collectées
  local db = ns.realmDB()
  local nItems, nHist, nVendor = 0, 0, 0
  for _ in pairs(AHLedgerDB.items) do nItems = nItems + 1 end
  for _ in pairs(db.hist or {}) do nHist = nHist + 1 end
  for _ in pairs(db.vendor or {}) do nVendor = nVendor + 1 end
  local c = ns.Prof.Char()
  local nSkills, nRecipes, nBags = 0, 0, 0
  for _ in pairs(c.skills) do nSkills = nSkills + 1 end
  for _, list in pairs(c.recipes) do for _ in pairs(list) do nRecipes = nRecipes + 1 end end
  for _ in pairs(c.bags or {}) do nBags = nBags + 1 end
  lines[#lines + 1] = ("Données : %d objets connus, %d suivis à l'HV, %d prix PNJ, %d métiers, %d recettes, %d objets en sac, %d courriers d'HV, version client %s"):format(
    nItems, nHist, nVendor, nSkills, nRecipes, nBags, #(db.ledger or {}),
    GetBuildInfo and table.concat({ tostring((GetBuildInfo())), tostring(select(4, GetBuildInfo())) }, " / ") or "?")
  local recipesSrc = ns.RecipeDB and ns.RecipeDB.ProviderNames() or {}
  lines[#lines + 1] = "Sources de recettes : " .. (#recipesSrc > 0 and table.concat(recipesSrc, ", ") or "aucune")
  local ofa = ns.RecipesOneForAll and ns.RecipesOneForAll.Count()
  lines[#lines + 1] = ofa and ("Recettes OneForAll : %d (seuils, sources et prix)"):format(ofa)
    or "Recettes OneForAll : addon absent (plan de montée limité à tes recettes connues)"

  AHLedgerDB.diag = { t = time(), ok = ok, lines = lines }
  return ok, lines
end

function Diag.Print()
  local ok, lines = Diag.Run()
  for _, l in ipairs(lines) do
    local color = l:sub(1, 2) == "OK" and "|cff40ff40" or (l:sub(1, 6) == "MANQUE" and "|cffff5050" or "|cffcccccc")
    ns.print(color .. l .. "|r")
  end
  ns.print(ok and "Tout est en place." or "Certaines fonctions manquent : envoie ces lignes à Claude (elles sont aussi dans /ahl claude).")
end

-- Diagnostic silencieux à la connexion, pour qu'il figure toujours dans le rapport
ns.on("PLAYER_LOGIN", function() C_Timer.After(10, function() ns.safe("diag", Diag.Run) end) end)
