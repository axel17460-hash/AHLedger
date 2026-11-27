-- AHLedger - Métiers du personnage : niveaux, recettes connues, objets que tu peux récolter
--
-- * Les niveaux de métier sont lus à la connexion et à chaque montée de compétence.
-- * Les recettes (composants, quantité produite, couleur de difficulté) sont relevées quand tu
--   ouvres une fenêtre de métier : ouvre chacun de tes métiers une fois pour remplir l'onglet Artisanat.
-- * Le dépeçage est relié aux cuirs et écailles du marché : l'onglet Marché les signale quand
--   ton niveau suffit pour les récolter.
local _, ns = ...

local Prof = {}
ns.Prof = Prof

-- Noms (anglais / français) et identifiants de ligne de compétence -> clé interne
local NAMES = {
  skinning = { 393, "skinning", "dépeçage" },
  leatherworking = { 165, "leatherworking", "travail du cuir" },
  cooking = { 185, "cooking", "cuisine" },
  firstaid = { 129, "first aid", "secourisme" },
  fishing = { 356, "fishing", "pêche" },
  herbalism = { 182, "herbalism", "herboristerie" },
  mining = { 186, "mining", "minage" },
  tailoring = { 197, "tailoring", "couture" },
  alchemy = { 171, "alchemy", "alchimie" },
  blacksmithing = { 164, "blacksmithing", "forge" },
  enchanting = { 333, "enchanting", "enchantement" },
  engineering = { 202, "engineering", "ingénierie" },
  lockpicking = { 633, "lockpicking", "crochetage" },
}
Prof.LABEL = {
  skinning = "Dépeçage", leatherworking = "Cuir", cooking = "Cuisine", firstaid = "Secourisme",
  fishing = "Pêche", herbalism = "Herbo.", mining = "Minage", tailoring = "Couture", alchemy = "Alchimie",
  blacksmithing = "Forge", enchanting = "Enchant.", engineering = "Ingé.", lockpicking = "Crochetage",
}

local byName, byLine = {}, {}
for key, t in pairs(NAMES) do
  byLine[t[1]] = key
  for i = 2, #t do byName[t[i]] = key end
end

function Prof.KeyFor(name, skillLine)
  if skillLine and byLine[skillLine] then return byLine[skillLine] end
  return name and byName[name:lower()] or nil
end

-- Cuirs, peaux et écailles : niveau de dépeçage approximatif à partir duquel on les obtient
-- couramment (dépecer un monstre demande niveau × 5 au-delà du niveau 20, (niveau - 10) × 10 avant).
Prof.SKINNING = {
  [2934] = 1,    -- Ruined Leather Scraps
  [2318] = 1,    -- Light Leather
  [783] = 1,     -- Light Hide
  [2319] = 75,   -- Medium Leather
  [4232] = 75,   -- Medium Hide
  [4234] = 125,  -- Heavy Leather
  [4235] = 125,  -- Heavy Hide
  [4461] = 150,  -- Raptor Hide
  [4304] = 175,  -- Thick Leather
  [8169] = 175,  -- Thick Hide
  [8167] = 175,  -- Turtle Scale
  [8170] = 225,  -- Rugged Leather
  [8171] = 225,  -- Rugged Hide
  [8154] = 225,  -- Scorpid Scale
  [8165] = 225,  -- Worn Dragonscale
  [15419] = 250, -- Warbear Leather
  [15412] = 260, -- Green Dragonscale
  [15417] = 270, -- Devilsaur Leather
  [15416] = 275, -- Black Dragonscale
  [15415] = 275, -- Blue Dragonscale
  [15422] = 275, -- Frostsaber Leather
  [15423] = 275, -- Chimera Leather
  [17012] = 300, -- Core Leather
}

-- Niveau de monstre maximum que tu peux dépecer
function Prof.MaxSkinLevel(rank)
  if not rank then return nil end
  if rank <= 100 then return math.floor(rank / 10) + 10 end
  return math.floor(rank / 5)
end

local function charKey()
  return (UnitName("player") or "?") .. "-" .. ns.realmName()
end

function Prof.Char()
  AHLedgerDB.chars = AHLedgerDB.chars or {}
  local k = charKey()
  local c = AHLedgerDB.chars[k]
  if not c then c = { skills = {}, recipes = {} }; AHLedgerDB.chars[k] = c end
  c.skills = c.skills or {}
  c.recipes = c.recipes or {}
  return c
end

function Prof.Skill(key) return Prof.Char().skills[key] end
function Prof.Recipes() return Prof.Char().recipes end

-- Lecture des niveaux de métier (API Classic, sinon API Retail)
function Prof.ScanSkills()
  local skills = {}
  if GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
      local key = not isHeader and Prof.KeyFor(name)
      if key then skills[key] = { rank, maxRank } end
    end
  end
  if GetProfessions and GetProfessionInfo then
    for _, idx in ipairs({ GetProfessions() }) do
      if idx then
        local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(idx)
        local key = Prof.KeyFor(name, skillLine)
        if key then skills[key] = { rank, maxRank } end
      end
    end
  end
  if next(skills) then
    local c = Prof.Char()
    c.skills = {}
    for k, v in pairs(skills) do c.skills[k] = v[1] end
    c.max = {}
    for k, v in pairs(skills) do c.max[k] = v[2] end
    Prof.related = nil
    ns.dataVersion = (ns.dataVersion or 0) + 1
  end
end

-- Difficulté : orange (optimal) / jaune (medium) / vert (easy) / gris (trivial)
local RETAIL_DIFF = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }

local function readClassic()
  if not (GetNumTradeSkills and GetTradeSkillLine) then return nil end
  local profName = GetTradeSkillLine()
  local key = Prof.KeyFor(profName)
  if not key then return nil end
  local list = {}
  for i = 1, GetNumTradeSkills() do
    local name, kind = GetTradeSkillInfo(i)
    local outId = kind ~= "header" and kind ~= "subheader" and ns.itemIdFromLink(GetTradeSkillItemLink(i))
    if outId then
      local lo, hi = GetTradeSkillNumMade(i)
      local r, ok = {}, true
      for j = 1, GetTradeSkillNumReagents(i) do
        local rname, _, count = GetTradeSkillReagentInfo(i, j)
        local rid = ns.itemIdFromLink(GetTradeSkillReagentItemLink(i, j))
        if rid and count then r[rid] = count; ns.rememberItem(rid, rname) else ok = false end
      end
      if ok then
        ns.rememberItem(outId, name)
        list[outId] = { n = name, m = ((lo or 1) + (hi or lo or 1)) / 2, r = r, d = kind }
      end
    end
  end
  return key, list
end

local function readRetail()
  local T = C_TradeSkillUI
  if not (T and T.GetAllRecipeIDs and T.GetRecipeSchematic) then return nil end
  local info = T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
  local key = info and Prof.KeyFor(info.professionName, info.parentProfessionID or info.professionID)
  if not key and GetTradeSkillLine then key = Prof.KeyFor(GetTradeSkillLine()) end
  if not key then return nil end
  local list = {}
  for _, rid in ipairs(T.GetAllRecipeIDs() or {}) do
    local ri = T.GetRecipeInfo and T.GetRecipeInfo(rid)
    local sch = (not ri or ri.learned) and T.GetRecipeSchematic(rid, false)
    if sch and sch.outputItemID then
      local r, ok = {}, true
      for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
        local first = slot.reagents and slot.reagents[1]
        if first and first.itemID and (slot.reagentType == nil or slot.reagentType == 1) then
          r[first.itemID] = (r[first.itemID] or 0) + (slot.quantityRequired or 1)
          ns.rememberItem(first.itemID)
        elseif slot.reagentType == nil or slot.reagentType == 1 then
          ok = false
        end
      end
      if ok then
        ns.rememberItem(sch.outputItemID, ri and ri.name)
        list[sch.outputItemID] = { n = ri and ri.name or sch.name, m = ((sch.quantityMin or 1) + (sch.quantityMax or 1)) / 2,
                                   r = r, d = ri and RETAIL_DIFF[ri.relativeDifficulty] }
      end
    end
  end
  return key, list
end

function Prof.ScanRecipes()
  local key, list = readClassic()
  if not key then key, list = readRetail() end
  if not key or not next(list) then return end
  local n = 0
  for _ in pairs(list) do n = n + 1 end
  local c = Prof.Char()
  local isNew = not c.recipes[key]
  c.recipes[key] = list
  Prof.related = nil
  ns.dataVersion = (ns.dataVersion or 0) + 1
  if isNew then ns.print(("%s : %d recettes enregistrées (onglet Artisanat)."):format(Prof.LABEL[key] or key, n)) end
  if ns.UI then ns.UI.OnData() end
end

-- Les événements de métier arrivent en rafale : on attend qu'ils se calment
local pending = false
local function schedule()
  if pending then return end
  pending = true
  C_Timer.After(0.5, function()
    pending = false
    ns.safe("recettes", Prof.ScanRecipes)
  end)
end
for _, ev in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
  ns.on(ev, schedule)
end
ns.on("PLAYER_LOGIN", function() Prof.ScanSkills() end)
ns.on("SKILL_LINES_CHANGED", function() Prof.ScanSkills() end)

-- Objets liés à tes métiers : ce que tu récoltes, ce que tu fabriques et leurs composants
function Prof.Related()
  if Prof.related then return Prof.related end
  local rel = {}
  local skin = Prof.Skill("skinning")
  if skin then
    for id, req in pairs(Prof.SKINNING) do if skin >= req then rel[id] = "dépeçage" end end
  end
  for _, list in pairs(Prof.Recipes()) do
    for outId, r in pairs(list) do
      rel[outId] = rel[outId] or "artisanat"
      for rid in pairs(r.r) do rel[rid] = rel[rid] or "composant" end
    end
  end
  Prof.related = rel
  return rel
end

-- Étiquette affichée dans les signaux du marché (seulement pour ce que tu peux récolter toi-même)
function Prof.Tag(id)
  local r = Prof.Related()[id]
  return r == "dépeçage" and r or nil
end

-- /ahl metiers
function Prof.Report()
  Prof.ScanSkills()
  local c = Prof.Char()
  local parts = {}
  for k, rank in pairs(c.skills) do
    local nRec = 0
    for _ in pairs(c.recipes[k] or {}) do nRec = nRec + 1 end
    parts[#parts + 1] = ("%s %d/%d%s"):format(Prof.LABEL[k] or k, rank, c.max and c.max[k] or 0,
      nRec > 0 and (" (" .. nRec .. " recettes)") or "")
  end
  table.sort(parts)
  ns.print(#parts > 0 and table.concat(parts, " · ") or "Aucun métier détecté.")
  local skin = c.skills.skinning
  if skin then
    ns.print(("Dépeçage %d : monstres jusqu'au niveau %d."):format(skin, Prof.MaxSkinLevel(skin)))
  end
  local missing = {}
  for k in pairs(c.skills) do
    if k ~= "skinning" and k ~= "fishing" and k ~= "lockpicking" and k ~= "herbalism" and k ~= "mining" and not c.recipes[k] then
      missing[#missing + 1] = Prof.LABEL[k] or k
    end
  end
  if #missing > 0 then ns.print("Ouvre ces fenêtres de métier une fois pour relever tes recettes : " .. table.concat(missing, ", ")) end
end
