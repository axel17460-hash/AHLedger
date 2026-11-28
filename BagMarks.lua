-- AHLedger - Pastilles HV / PNJ sur les cases des sacs et de la banque de Daylight UI :
-- vert = mieux à l'HV, jaune = à peu près pareil, rouge = au PNJ. Seulement HV ouverte (hors de l'HV,
-- AHLedger ne fait rien), et si l'option « bagMarks » est allumée (/ahl options).
--
-- Verdicts du bilan (bouton à bandes de couleur des sacs, ou /ahl verdicts ; éteints par défaut) :
-- une bande en haut de la case, avec son mot, pour ce qui ne marche pas d'après tes courriers des
-- 30 derniers jours et tes flips en cours : rouge « perte » = flip perdant, violet « stop » = ne se
-- vend pas, orange « prix » = se vend, mais tes enchères expirent (prix trop haut).
--
-- Passe par l'API publique de Daylight UI : me.Paint("bagslot", …) et API.Attach (voir son API.md).
-- Tout est dessiné sur le cadre que donne API.Attach, jamais sur les pièces de Daylight UI. Pas de
-- bordure colorée : l'anneau des cases de Daylight UI a déjà la couleur de qualité de l'objet.
local _, ns = ...

local Marks = { on = true, slots = {}, info = setmetatable({}, { __mode = "k" }) }
ns.BagMarks = Marks

local SIZE = 6     -- petite, pour ne pas cacher l'icône de l'objet
local ALPHA = 0.9
local BAND_H = 10  -- bande de verdict : la hauteur du petit texte de Daylight UI

-- Du plus grave au moins grave : un objet qui en a plusieurs prend le premier
Marks.VERDICTS = {
  { kind = "loss", word = "perte", label = "flip perdant", color = { 0.92, 0.18, 0.18 } },
  { kind = "stop", word = "stop", label = "ne se vend pas", color = { 0.64, 0.32, 0.96 } },
  { kind = "price", word = "prix", label = "prix trop haut", color = { 1, 0.55, 0.1 } },
}
local VERDICT = {}
for i, v in ipairs(Marks.VERDICTS) do v.rank = i; VERDICT[v.kind] = v end
Marks.VERDICT = VERDICT

-- Cadre posé par Daylight UI sur la case, pour nos pièces
local function markFor(slot)
  local m = Marks.slots[slot]
  if m then return m end
  local A = ns.Look.API()
  local holder = A and A.Attach and A.Attach(slot)
  if not holder then return nil end
  m = { holder = holder }
  Marks.slots[slot] = m
  return m
end

local function dotOf(m)
  if m.dot then return m end
  m.edge = m.holder:CreateTexture(nil, "OVERLAY", nil, 6)
  m.edge:SetSize(SIZE + 2, SIZE + 2)
  m.edge:SetPoint("TOPLEFT", 2, -2)
  m.edge:SetColorTexture(0, 0, 0, 0.6)
  m.dot = m.holder:CreateTexture(nil, "OVERLAY", nil, 7)
  m.dot:SetSize(SIZE, SIZE)
  m.dot:SetPoint("CENTER", m.edge, "CENTER")
  return m
end

-- Le mot est calé à droite : la pastille HV / PNJ reste lisible à gauche, par-dessus la bande
local function bandOf(m)
  if m.band then return m end
  -- le mot d'abord : si sa création échoue, la case reste sans bande (et sera refaite), jamais à moitié
  local word = ns.Look.Text(m.holder, "tiny")
  local band = m.holder:CreateTexture(nil, "OVERLAY", nil, 4)
  band:SetPoint("TOPLEFT", 1, -1)
  band:SetPoint("TOPRIGHT", -1, -1)
  band:SetHeight(BAND_H)
  m.band, m.word = band, word
  m.word:SetPoint("RIGHT", m.band, "RIGHT", -2, 0)
  if m.word.SetDrawLayer then m.word:SetDrawLayer("OVERLAY", 5) end
  m.word:SetTextColor(1, 1, 1)
  return m
end

local function bound(bag, slot)
  if not (bag and slot) then return nil end
  local _, _, isBound = ns.Bags.SlotItem(bag, slot)
  return isBound
end

-- Type de pastille pour un objet, ou nil
function Marks.KindFor(itemID, bag, slot)
  if not (itemID and Marks.on and ns.ahOpen) then return nil end
  local mode = ns.Options.Get("bagMarks")
  if mode == "off" then return nil end
  if bound(bag, slot) then return nil end
  local c = ns.Bags.Compare(itemID)
  return c and c.kind
end

-- Verdict de chaque objet qui ne marche pas : { kind, why }. Calculé une fois par version des données
-- (scan, courrier, achat…), et seulement quand l'option est allumée : rien ne tourne pendant l'affichage.
local verdicts, verdictsVer
local function collect(out)
  local function put(id, kind, why)
    local cur = out[id]
    if id and VERDICT[kind] and not (cur and VERDICT[cur.kind].rank <= VERDICT[kind].rank) then
      out[id] = { kind = kind, why = why }
    end
  end
  -- bilan 30 j (courriers) : achat-revente perdant, 0 vendu, ventes qui expirent
  for _, e in ipairs(ns.Advisor.Review()) do put(e.id, e.verdict, e.advice) end
  -- flips en cours pas remontés après deux fois le délai prévu (Mes flips)
  for _, p in ipairs(ns.Positions.DB().positions) do
    if not p.done then
      local e = ns.Positions.Evaluate(p)
      if e.verdict == "loss" then
        put(p.id, "loss", ("flip en cours : acheté %s/u, %s"):format(ns.money(p.unit or 0), e.why or ""))
      end
    end
  end
end

function Marks.Verdicts()
  if verdicts and verdictsVer == ns.dataVersion then return verdicts end
  local out = {}
  ns.safe("verdicts des sacs", collect, out) -- une erreur : liste vide jusqu'aux données suivantes
  verdicts, verdictsVer = out, ns.dataVersion
  return out
end

-- Verdict à montrer pour un objet (option allumée), ou nil
function Marks.VerdictFor(itemID, bag, slot)
  if not (itemID and Marks.on and ns.ahOpen and ns.Options.Get("bagVerdicts")) then return nil end
  if bound(bag, slot) then return nil end
  return Marks.Verdicts()[itemID]
end

-- Calculs à l'avance, par morceaux de quelques millisecondes par image. Daylight UI repeint toutes
-- les cases d'un coup à l'ouverture des sacs : si les données ont changé depuis (scan, courrier,
-- option…), calculer là toute l'analyse du royaume et chaque décision ferait sauter des images.
-- Une case dont le calcul n'est pas prêt garde sa pastille d'avant (même objet) ou n'en a pas,
-- puis est repeinte quand tout est prêt.
local warm = { running = false, dirty = false }
local function verdictsReady() return verdicts ~= nil and verdictsVer == ns.dataVersion end

local function needsKind()
  local mode = ns.Options.Get("bagMarks")
  return Marks.on and ns.ahOpen and mode ~= "off"
end
local function needsVerdicts() return Marks.on and ns.ahOpen and ns.Options.Get("bagVerdicts") end

local function countFor(id) return math.max(ns.Bags.Count(id), 1) end

local function isCold(info, isBound)
  local id = info and info.itemID
  if not id or isBound then return false end
  if needsKind() and not ns.Decide.Ready(id, countFor(id)) then return true end
  return needsVerdicts() and not verdictsReady() or false
end

local function stopper()
  local clock = debugprofilestop
  if clock then
    local t0 = clock()
    return function() return clock() - t0 > 3 end
  end
  local n = 0 -- hors jeu (tests) : par paquets
  return function() n = n + 1; return n % 25 == 0 end
end

local warmStep
-- Échecs du calcul pour la version de données en cours : au-delà de 2, on attend les données
-- suivantes (scan, courrier…) au lieu de relancer à chaque case repeinte et de remplir le chat
local fails, failsVer = 0, nil
local MAX_FAILS = 2
local function again()
  C_Timer.After(0, function()
    -- une erreur ne doit pas laisser warm.running à true : sinon plus aucun calcul jusqu'au /reload
    if not ns.safe("pastilles", warmStep) then
      warm.running = false
      if failsVer ~= ns.dataVersion then fails, failsVer = 0, ns.dataVersion end
      fails = fails + 1
    end
  end)
end
function warmStep()
  local stop = stopper()
  -- l'analyse du royaume d'abord, par morceaux : les pastilles et le bilan des verdicts la lisent
  local wantVerdicts = needsVerdicts() and not verdictsReady()
  if (needsKind() or wantVerdicts) and not ns.Analysis.Build(stop) then return again() end
  if needsKind() then
    local seen = {}
    for _, info in pairs(Marks.info) do
      local id = info.itemID
      if id and not seen[id] then
        seen[id] = true
        local n = countFor(id)
        if not ns.Decide.Ready(id, n) then
          ns.Decide.For(id, n)
          if stop() then return again() end
        end
      end
    end
  end
  if needsVerdicts() and not verdictsReady() then
    Marks.Verdicts()
  end
  warm.running = false
  if warm.dirty then
    warm.dirty = false
    Marks.Refresh()
  end
end

local function warmSoon()
  warm.dirty = true
  if warm.running then return end
  if failsVer == ns.dataVersion and fails >= MAX_FAILS then return end
  warm.running = true
  again()
end
Marks.Warm = warmSoon

-- Pour l'infobulle : le verdict seulement s'il est déjà calculé. Sinon on lance le calcul par
-- morceaux plutôt que tout le bilan (Advisor.Review) d'un coup au survol d'une case.
function Marks.VerdictIfReady(itemID)
  if not (itemID and Marks.on and ns.ahOpen and ns.Options.Get("bagVerdicts")) then return nil end
  if not verdictsReady() then warmSoon(); return nil end
  return verdicts[itemID]
end

local function paint(slot, info)
  local m = Marks.slots[slot]
  local isBound = info and bound(info.bag, info.slot)
  if isCold(info, isBound) then
    warmSoon()
    if m and m.item == info.itemID then return end -- même objet : on garde ce qui est affiché
    info = nil -- autre objet : rien en attendant
  end
  if m then m.item = info and info.itemID end
  local kind = info and not isBound and Marks.KindFor(info.itemID)
  local v = info and not isBound and Marks.VerdictFor(info.itemID)
  if not (kind or v) then
    if m and m.dot then m.edge:Hide(); m.dot:Hide() end
    if m and m.band then m.band:Hide(); m.word:Hide() end
    return
  end
  m = m or markFor(slot)
  if not m then return end
  m.item = info and info.itemID
  if kind then
    dotOf(m)
    local c = ns.Bags.COLORS[kind]
    m.dot:SetColorTexture(c[1], c[2], c[3], ALPHA)
    m.edge:Show(); m.dot:Show()
  elseif m.dot then
    m.edge:Hide(); m.dot:Hide()
  end
  if v then
    bandOf(m)
    local spec = VERDICT[v.kind]
    m.band:SetColorTexture(spec.color[1], spec.color[2], spec.color[3], 0.85)
    m.word:SetText(spec.word)
    m.band:Show(); m.word:Show()
  elseif m.band then
    m.band:Hide(); m.word:Hide()
  end
end

-- Repeint toutes les cases vues (nouveau scan) ; withBags = demander aussi à Daylight UI de
-- remplir ses sacs à nouveau (ouverture et fermeture de l'HV)
function Marks.Refresh(withBags)
  for slot, info in pairs(Marks.info) do ns.safe("pastilles", paint, slot, info) end
  local A = withBags and ns.Look.API()
  if A and A.RefreshBags then pcall(A.RefreshBags) end
end

-- Objets à bande là où tu es (sacs, et banque quand elle est ouverte), d'après le jeu lui-même :
-- { bag, slot, id, v }. Sert à l'infobulle du bouton, à /ahl verdicts et à /ahl diag.
function Marks.InBags()
  local out = {}
  if not ns.Options.Get("bagVerdicts") then return out end
  local list = Marks.Verdicts()
  local bags = ns.Bags.BagList()
  for _, b in ipairs(ns.Bags.BankList()) do bags[#bags + 1] = b end
  for _, bag in ipairs(bags) do
    for slot = 1, ns.Bags.NumSlots(bag) do
      local id, _, isBound = ns.Bags.SlotItem(bag, slot)
      local v = id and not isBound and list[id]
      if v then out[#out + 1] = { bag = bag, slot = slot, id = id, v = v } end
    end
  end
  return out
end

local function plain(id)
  local m = id and AHLedgerDB.items[id]
  return m and m.n or ("#" .. tostring(id))
end
Marks.Plain = plain

-- Noms des objets à bande dans tes sacs, sans doublon : « Raptor Hide (stop), Spider Ichor (stop) »
function Marks.InBagsText()
  local names, seen = {}, {}
  for _, e in ipairs(Marks.InBags()) do
    if not seen[e.id] then
      seen[e.id] = true
      names[#names + 1] = ("%s (%s)"):format(plain(e.id), VERDICT[e.v.kind].word)
    end
  end
  return names
end

-- Contrôle pour /ahl diag : de la liste du bilan jusqu'au dessin sur la case, où ça coince.
local function yes(b) return b and "oui" or "non" end
local function ask(r, method, ...)
  local f = type(r) == "table" and r[method]
  if type(f) ~= "function" then return nil end
  local ok, a, b = pcall(f, r, ...)
  if ok then return a, b end
end

function Marks.Probe(lines)
  local on = ns.Options.Get("bagVerdicts") and true or false
  local nList = 0
  if on then for _ in pairs(Marks.Verdicts()) do nList = nList + 1 end end
  local here = Marks.InBags()
  -- une même case peut venir de plusieurs cadres (cadres réutilisés, copie d'un perso) : on garde
  -- celui qui montre sa bande, sinon un cadre visible
  local seen, withItem, byKey = 0, 0, {}
  local function score(frame)
    local m = Marks.slots[frame]
    if m and m.band and m.band:IsShown() then return 2 end
    return ask(frame, "IsVisible") and 1 or 0
  end
  for frame, info in pairs(Marks.info) do
    seen = seen + 1
    if info.itemID then withItem = withItem + 1 end
    if info.bag and info.slot then
      local key = info.bag .. ":" .. info.slot
      local cur = byKey[key]
      if not cur or score(frame) > score(cur) then byKey[key] = frame end
    end
  end
  local A = ns.Look.API()
  local bagsFrame = A and A.GetFrame and A.GetFrame("bags")
  lines[#lines + 1] = ("Verdicts sur les cases : %s ; %d objet(s) au bilan, %d case(s) concernée(s) dans tes sacs ; Daylight UI nous a passé %d case(s), dont %d avec un objet ; fenêtre des sacs ouverte : %s"):format(
    on and "allumés" or "éteints", nList, #here, seen, withItem, yes(ask(bagsFrame, "IsVisible")))
  for k = 1, math.min(#here, 4) do
    local e = here[k]
    local frame = byKey[e.bag .. ":" .. e.slot]
    local m = frame and Marks.slots[frame]
    local state
    if not frame then state = "case jamais passée par Daylight UI"
    elseif not m then state = "pas de cadre API.Attach"
    elseif not m.band then state = "bande jamais dessinée"
    else
      local function num(x) return type(x) == "number" and x or -1 end
      local w, h = ask(m.holder, "GetSize")
      state = ("bande %s, visible %s ; cadre visible %s, opacité %.2f, niveau %s (case %s), %dx%d ; mot « %s »"):format(
        m.band:IsShown() and "montrée" or "cachée", yes(ask(m.band, "IsVisible")), yes(ask(m.holder, "IsVisible")),
        num(ask(m.holder, "GetEffectiveAlpha")), tostring(ask(m.holder, "GetFrameLevel")), tostring(ask(frame, "GetFrameLevel")),
        math.floor(num(w)), math.floor(num(h)), tostring(ask(m.word, "GetText")))
    end
    lines[#lines + 1] = ("  %s (%d:%d, %s) : %s"):format(plain(e.id), e.bag, e.slot, e.v.kind, state)
  end
end

function Marks.Start()
  if Marks.started then return true end
  local me = ns.Look.Me()
  if not (me and me.Paint) then return false end
  Marks.started = true
  -- info est une table par case, remplie à nouveau à chaque passage : on garde la référence
  me.Paint("bagslot", function(slot, parts, info)
    if info then Marks.info[slot] = info end
    ns.safe("pastilles", paint, slot, info)
  end)
  return true
end

-- Allumer / éteindre les pastilles depuis les sacs
function Marks.Toggle()
  ns.Options.Set("bagMarks", ns.Options.Get("bagMarks") == "off" and "on" or "off")
end

-- Boutons dans la rangée d'outils de la fenêtre des sacs de Daylight UI (tri, emplacements, vue,
-- crochetage…) : « HV » pour les pastilles, et trois barres de couleur pour les verdicts du bilan.
-- Daylight UI n'a pas d'appel public pour ajouter un outil : on passe par me.Wrap sur
-- Window.LayoutTools de son module Bags, comme pour l'onglet de l'HV (UI.lua). Les boutons sont les
-- nôtres ; on les ajoute seulement à la liste des outils, et c'est Daylight UI qui les place, à
-- gauche des siens, contre la recherche. Si la voie ne tient plus, les options restent dans /ahl options.
local tools = setmetatable({}, { __mode = "k" }) -- fenêtre des sacs → { hv = bouton, verdict = bouton }
local ICON_SIZE, ROW = 14, 22
local BAR_W, BAR_GAP = 3, 2

function Marks.ToggleVerdicts()
  ns.Options.Set("bagVerdicts", not ns.Options.Get("bagVerdicts"))
  return ns.Options.Get("bagVerdicts")
end

local function paintTool(b)
  local A = ns.Look.API()
  if not A then return end
  local c = A.Colors().LABEL or { 0.6, 0.55, 0.45 }
  if b.kind == "verdict" then
    -- les trois couleurs des bandes, éteintes = grisées
    local on = ns.Options.Get("bagVerdicts") and true or false
    for i, bar in ipairs(b.bars) do
      local col = (on or b.over) and Marks.VERDICTS[i].color or c
      bar:SetColorTexture(col[1], col[2], col[3], on and 1 or 0.6)
    end
    return
  end
  local on = ns.Options.Get("bagMarks") ~= "off"
  if on or b.over then
    b.icon:SetVertexColor(A.Accent())
  else
    b.icon:SetVertexColor(c[1], c[2], c[3])
  end
  b.icon:SetAlpha(on and 1 or 0.6)
end

local MODE_TEXT = { on = "allumées (à l'HV seulement)", off = "éteintes" }

local function verdictTip()
  local on = ns.Options.Get("bagVerdicts")
  GameTooltip:AddLine("AHLedger : verdicts du bilan")
  GameTooltip:AddLine("Une bande en haut des cases des sacs et de la banque, pour ce qui ne marche pas d'après tes courriers des 30 derniers jours et tes flips en cours :", 1, 1, 1, true)
  local tips = { loss = "achat-revente perdant : n'en rachète plus à ce prix", stop = "0 vendu : arrête l'HV, vends au PNJ",
                 price = "se vend, mais tes enchères expirent : mets moins cher" }
  for _, v in ipairs(Marks.VERDICTS) do
    GameTooltip:AddLine(("%s = %s (%s)"):format(v.word, v.label, tips[v.kind]), v.color[1], v.color[2], v.color[3], true)
  end
  if not on then
    GameTooltip:AddLine("Éteints.", 0.8, 0.8, 0.8, true)
    return
  end
  local n = 0
  for _ in pairs(Marks.Verdicts()) do n = n + 1 end
  local names = Marks.InBagsText()
  if #names == 0 then
    GameTooltip:AddLine(("Allumés. Aucun des %d objet%s du bilan n'est dans tes sacs (ni dans ta banque, si elle est ouverte)."):format(
      n, n > 1 and "s" or ""), 0.8, 0.8, 0.8, true)
  else
    GameTooltip:AddLine(("Allumés. Dans tes sacs (%d sur %d objet%s du bilan) : %s."):format(#names, n, n > 1 and "s" or "",
      table.concat(names, ", ")), 0.8, 0.8, 0.8, true)
  end
end

local function makeTool(f, kind)
  local A = ns.Look.API()
  local b = CreateFrame("Button", nil, f)
  b.kind = kind
  b:SetSize(ROW, ROW)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  if kind == "verdict" then
    b.bars = {}
    local left = -(3 * BAR_W + 2 * BAR_GAP) / 2
    for i = 1, #Marks.VERDICTS do
      local bar = b:CreateTexture(nil, "ARTWORK")
      bar:SetSize(BAR_W, ICON_SIZE - 2)
      bar:SetPoint("LEFT", b, "CENTER", left + (i - 1) * (BAR_W + BAR_GAP), 0)
      b.bars[i] = bar
    end
  else
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(ICON_SIZE, ICON_SIZE)
    b.icon:SetPoint("CENTER")
    b.icon:SetTexture(A and A.Media and A.Media("ui-section-auction.png") or "Interface\\Icons\\INV_Misc_Coin_01")
  end
  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then ns.safe("options", ns.Options.Show)
    elseif kind == "verdict" then ns.safe("verdicts", Marks.ToggleVerdicts)
    else ns.safe("pastilles", Marks.Toggle) end
  end)
  b:SetScript("OnEnter", function(self) ns.safe("bouton des sacs", function()
    self.over = true; paintTool(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if kind == "verdict" then
      verdictTip()
    else
      GameTooltip:AddLine("AHLedger : pastilles HV / PNJ")
      GameTooltip:AddLine(("Vert = mieux à l'HV, jaune = pareil, rouge = au PNJ. Actuellement %s."):format(
        MODE_TEXT[ns.Options.Get("bagMarks")] or "?"), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Clic : allumer / éteindre · Clic droit : options", 0.5, 0.8, 1)
    GameTooltip:Show()
  end) end)
  b:SetScript("OnLeave", function(self) ns.safe("bouton des sacs", function()
    self.over = false; paintTool(self); GameTooltip:Hide()
  end) end)
  paintTool(b)
  return b
end

local function addTool(f)
  if tools[f] or type(f) ~= "table" or type(f.tools) ~= "table" then return end
  local set = { hv = makeTool(f, "hv"), verdict = makeTool(f, "verdict") }
  tools[f] = set
  -- dernier de la liste = le plus à gauche, contre la recherche
  f.tools[#f.tools + 1] = set.hv
  f.tools[#f.tools + 1] = set.verdict
end

function Marks.SyncTools()
  for _, set in pairs(tools) do paintTool(set.hv); paintTool(set.verdict) end
end

function Marks.HookBagTools()
  if Marks.toolHooked then return true end
  local me, A = ns.Look.Me(), ns.Look.API()
  local D = DaylightUI
  local mod = type(D) == "table" and type(D.GetModule) == "function" and D:GetModule("Bags")
  local W = type(mod) == "table" and type(mod.ns) == "table" and mod.ns.Window
  if not (me and me.Wrap and A and A.GetFrame and type(W) == "table" and type(W.LayoutTools) == "function") then
    return false
  end
  -- false = accroche refusée par Daylight UI : pas de bouton, l'option reste dans /ahl options
  if not me.Wrap(W, "LayoutTools", function(original, f, ...)
    if f and f == A.GetFrame("bags") then ns.safe("bouton des sacs", addTool, f) end
    return original(f, ...)
  end) then return false end
  Marks.toolHooked = true
  -- fenêtre déjà construite : on y ajoute le bouton tout de suite
  local f = A.GetFrame("bags")
  if f and not tools[f] then W.LayoutTools(f) end
  return true
end

-- Garde-fou pour Daylight UI (vu en 2.2.5, puis encore en 2.2.7) : quand beaucoup d'objets bougent
-- d'un coup (tri, gros butin), ses sacs fondent toute la grille, déplacent les objets puis la refont
-- apparaître. Si ce fondu ne va pas au bout, la grille reste transparente (à 0 : objets invisibles
-- mais survolables ; à mi-chemin : objets grisés). Ses fondus durent moins de 0,4 s ; une grille
-- encore sous 1 et figée sur deux relevés à 0,5 s d'écart est donc bloquée, et on la remet à 1.
-- On ne touche qu'à l'opacité de la fenêtre, jamais au code de Daylight UI.
local function bagWindows()
  local D = DaylightUI
  local mod = type(D) == "table" and type(D.GetModule) == "function" and D:GetModule("Bags")
  local mns = type(mod) == "table" and type(mod.ns) == "table" and mod.ns
  return mns and (mns.windows or (mns.window and { mns.window })) or {}
end

function Marks.Unstick(first)
  for _, w in ipairs(bagWindows()) do
    local items = type(w) == "table" and w.items
    if items and items.GetAlpha and w:IsVisible() then
      local a = items:GetAlpha()
      if first == nil then
        if a < 0.99 then
          C_Timer.After(0.5, function() ns.safe("sacs grisés", Marks.Unstick, { [w] = a }) end)
        end
      elseif first[w] and a < 0.99 and math.abs(a - first[w]) < 0.01 then
        items:SetAlpha(1)
      end
    end
  end
end

local unstickDue = false
local function unstickSoon()
  if unstickDue then return end
  unstickDue = true
  C_Timer.After(1, function() unstickDue = false; ns.safe("sacs grisés", Marks.Unstick) end)
end
Marks.UnstickSoon = unstickSoon

-- Les fenêtres (sacs, banque) peuvent naître après la connexion : on accroche celles qu'on voit
local showHooked = setmetatable({}, { __mode = "k" })
local function hookShow()
  for _, w in ipairs(bagWindows()) do
    if type(w) == "table" and w.HookScript and not showHooked[w] then
      showHooked[w] = true
      w:HookScript("OnShow", unstickSoon)
    end
  end
end
Marks.HookShow = hookShow

ns.on("BAG_UPDATE_DELAYED", function() ns.safe("sacs grisés", hookShow); unstickSoon() end)

ns.on("ADDON_LOADED", function(name)
  if name == "AHLedger" then ns.safe("bouton des sacs", Marks.HookBagTools) end
end)
ns.on("PLAYER_LOGIN", function()
  ns.safe("pastilles", Marks.Start); ns.safe("bouton des sacs", Marks.HookBagTools)
  ns.safe("sacs grisés", hookShow)
end)
local function later() C_Timer.After(0, function() ns.safe("pastilles", Marks.Refresh, true) end) end
ns.on("AUCTION_HOUSE_SHOW", later)
ns.on("AUCTION_HOUSE_CLOSED", later)
