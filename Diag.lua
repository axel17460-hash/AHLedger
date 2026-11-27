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
  }, skip = function()
    -- AuctionHouseFrame n'existe qu'une fois l'interface de l'HV chargée : pas un manque avant
    if ns.UI and ns.UI.dlTab then return "onglet Daylight UI utilisé" end
    if not AuctionHouseFrame then return "interface de l'HV pas encore chargée : refais /ahl diag à l'HV" end
  end },
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
  { "Relevés (achats PNJ, fabrications)", {
    { "Classic", { "hooksecurefunc", "BuyMerchantItem", "DoTradeSkill", "GetItemCount" } },
    { "Retail", { "hooksecurefunc", "BuyMerchantItem", "C_TradeSkillUI.CraftRecipe", "C_Item.GetItemCount" } },
  } },
  { "Tooltips", {
    { "Retail", { "TooltipDataProcessor.AddTooltipPostCall" } },
    { "Classic", { "GameTooltip.HookScript" } },
  } },
}

local function version(addon)
  local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
  if not get then return nil end
  local okV, v = pcall(get, addon, "Version")
  if okV and type(v) == "string" and v ~= "" then return v end
end

local function loaded(addon)
  local f = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
  return f ~= nil and f(addon) and true or false
end

Diag.HISTORY_SAMPLE = 300 -- objets suivis dont on demande l'historique à Auctionator
Diag.HISTORY_MIN = 20     -- en dessous, trop peu d'objets pour conclure à un format changé

-- Ce qu'AHLedger emprunte à Auctionator et à Daylight UI hors de leurs API promises : ça peut
-- changer à chaque mise à jour. Vérifié en direct, sur ce qui est chargé (pas sur leurs fichiers).
-- Renvoie false si une accroche ne tient plus ; AHLedger a un repli pour chacune.
function Diag.Addons(lines)
  local ok = true
  local function check(good, text, why)
    lines[#lines + 1] = good and ("OK   " .. text) or ("MANQUE " .. text .. (why and (" (" .. why .. ")") or ""))
    if not good then ok = false end
  end
  local vers = {}
  for _, a in ipairs({ "Auctionator", "DaylightUI" }) do
    local v = loaded(a) and version(a)
    if v then vers[#vers + 1] = a .. " " .. v end
  end
  local D = rawget(_G, "DaylightUI")
  local dapi = type(D) == "table" and type(D.API) == "table" and D.API
  if dapi and dapi.major then vers[#vers + 1] = ("API Daylight %s.%s"):format(tostring(dapi.major), tostring(dapi.minor or "?")) end
  if #vers > 0 then lines[#lines + 1] = "Versions : " .. table.concat(vers, " · ") end
  -- Midas : source facultative du prix d'équilibre et des chances de vente (lecture seule)
  if ns.MidasLink then lines[#lines + 1] = "Midas : " .. ns.MidasLink.Status() end

  -- relevés de la phase 3 : accrochés à la connexion, sinon rien n'est noté (sans autre message)
  check(ns.Vendor and ns.Vendor.hooked, "Achats chez le marchand relevés à ton clic", "BuyMerchantItem absent ou pas accroché")
  check(ns.Prof and ns.Prof.craftHooked, "Fabrications relevées à ton clic", "DoTradeSkill et C_TradeSkillUI.CraftRecipe absents ou pas accrochés")

  if ns.Bridge.HasAuctionator() then
    check(ns.Bridge.hooked, "Fin de scan Auctionator écoutée",
      "Auctionator.FullScan.Events.ScanComplete absent : AHLedger lit alors la liste du jeu lui-même")
    local A = Auctionator
    if not (A.Database and type(A.Database.db) == "table" and A.Constants and A.Constants.SCAN_DAY_0) then
      check(false, "Historique Auctionator", "Auctionator.Database.db ou Constants.SCAN_DAY_0 absent : tendances sur les scans AHLedger seulement")
    else
      -- Un format de base changé ne fait pas d'erreur : l'historique revient vide. On le voit ici.
      local asked, got = 0, 0
      for id in pairs(ns.realmDB().hist or {}) do
        if asked >= Diag.HISTORY_SAMPLE then break end
        asked = asked + 1
        local h = ns.Bridge.History(id, 14)
        if h and #h > 0 then got = got + 1 end
      end
      if asked < Diag.HISTORY_MIN then
        lines[#lines + 1] = ("Historique Auctionator : %d objets suivis, trop peu pour juger"):format(asked)
      else
        check(got > 0, ("Historique Auctionator : %d objets suivis sur %d ont des prix (14 j)"):format(got, asked),
          "aucun prix lu : format de sa base changé ?")
      end
    end
  end

  if dapi then
    check(ns.Look.Daylight(), "API publique de Daylight UI",
      "version majeure inconnue : fenêtres AHLedger à l'allure du jeu")
  end
  if ns.Look.Daylight() then
    if ns.Look.DaylightAH() then
      local UI = ns.UI or {}
      local Main = UI.dlMain
      local built = type(Main) == "table" and type(Main.frame) == "table"
      local inTabs = false
      for _, t in ipairs(built and type(Main.TABS) == "table" and Main.TABS or {}) do
        if t.id == "ahledger" then inTabs = true end
      end
      check(UI.dlTab and (inTabs or not built) and true or false,
        "Onglet AHLedger dans l'HV de Daylight UI" .. ((UI.dlTab and not built) and " (fenêtre pas encore construite)" or ""),
        "accroche refusée ou fonctions renommées : bouton « AHLedger » à la place")
    end
    if loaded("DaylightUI_Bags") then
      check(ns.BagMarks and ns.BagMarks.toolHooked, "Bouton HV dans les sacs de Daylight UI",
        "accroche refusée : pastilles réglables dans /ahl options")
      check(ns.BagMarks and ns.BagMarks.started, "Pastilles HV / PNJ sur les cases des sacs", "me.Paint absent")
      if ns.BagMarks and ns.BagMarks.Probe then ns.safe("diag des verdicts", ns.BagMarks.Probe, lines) end
    end
  end
  return ok
end

function Diag.Run()
  local lines, ok = {}, true
  for _, f in ipairs(Diag.FEATURES) do
    local used, firstMissing
    for _, variant in ipairs(f[2]) do
      local good, missing = all(variant[2])
      if good then used = variant[1]; break end
      firstMissing = firstMissing or (variant[1] .. " : " .. missing)
    end
    local skipped = not used and f.skip and f.skip()
    if used then
      lines[#lines + 1] = ("OK   %s : %s"):format(f[1], used)
    elseif skipped then
      lines[#lines + 1] = ("--   %s : sans objet (%s)"):format(f[1], skipped)
    else
      ok = false
      lines[#lines + 1] = ("MANQUE %s (%s)"):format(f[1], firstMissing or "?")
    end
  end
  if not Diag.Addons(lines) then ok = false end
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
  local usual = ns.Scan.UsualSize(db)
  local rej = db.rejected
  lines[#lines + 1] = ("Scans : dernier %s%s%s"):format(
    db.lastScanTime and date("%d/%m %H:%M", db.lastScanTime) or "jamais",
    usual and (", taille habituelle ~%d enchères"):format(usual) or "",
    rej and (" · scan incomplet ignoré le %s (%d enchères au lieu de ~%d)"):format(date("%d/%m %H:%M", rej.t), rej.n, rej.usual) or "")
  local part = db.partial
  if part then
    lines[#lines + 1] = ("Dernier scan partiel : %s, %d enchères%s, %d lignes illisibles (prix gardés, ventes non comptées)"):format(
      date("%d/%m %H:%M", part.t), part.n or 0, part.usual and (" au lieu de ~%d"):format(part.usual) or "", part.missing or 0)
  end
  if type(AHLedgerDB.errors) == "table" and #AHLedgerDB.errors > 0 then
    lines[#lines + 1] = ("Erreurs gardées : %d, la dernière : %s"):format(#AHLedgerDB.errors, AHLedgerDB.errors[#AHLedgerDB.errors])
  end
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

-- Diagnostic silencieux à la première ouverture de l'HV, pour qu'il figure toujours dans le rapport
ns.on("AUCTION_HOUSE_SHOW", function()
  if Diag.ranAtAH then return end
  Diag.ranAtAH = true
  C_Timer.After(10, function() ns.safe("diag", Diag.Run) end)
end)
