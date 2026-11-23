-- AHLedger - Rapport pour Claude : un résumé texte de tout ce que l'addon sait
-- (marché, flips, artisanat, sacs, bilan, métiers), à copier-coller dans une conversation
-- avec Claude pour obtenir des conseils.
--
-- * /ahl claude ouvre une fenêtre avec le rapport déjà sélectionné : Ctrl+C puis colle-le dans Claude.
-- * Le rapport est aussi enregistré dans les SavedVariables (AHLedgerDB.brief) après chaque scan
--   et à la déconnexion : `python tools/ahledger.py brief <fichier>` le ressort hors du jeu.
-- Aucun envoi réseau : un addon ne peut pas communiquer avec l'extérieur, c'est toi qui copies.
local _, ns = ...

local Export = {}
ns.Export = Export

Export.TOP = { market = 25, rising = 10, flip = 12, craft = 12, bags = 25, ledger = 12, vendor = 8, farm = 6 }

local function plain(s) return (tostring(s or "?"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
-- cuivre -> "12g 34s" / "3s 05c" (sans codes couleur)
local function g(c)
  if not c then return "-" end
  return plain(ns.money(c))
end
local function pct(v) return v and ("%+.1f%%"):format(v * 100) or "-" end
local function num(v, fmt) return v and (fmt or "%.0f"):format(v) or "-" end

local function sorted(list, key, n)
  table.sort(list, function(a, b) return (a[key] or -math.huge) > (b[key] or -math.huge) end)
  local out = {}
  for i = 1, math.min(n, #list) do out[i] = list[i] end
  return out
end

local function nameOf(id, s)
  local meta = AHLedgerDB.items[id]
  return plain((s and s.name) or (meta and meta.n) or ("#" .. tostring(id)))
end

function Export.Build()
  if ns.Diag then ns.safe("diag", ns.Diag.Run) end
  local L = {}
  local function add(fmt, ...) L[#L + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end
  local db = ns.realmDB()
  local A = ns.Analysis
  local c = ns.Prof.Char()

  add("# AHLedger — rapport pour Claude (%s)", date("%Y-%m-%d %H:%M"))
  add("Royaume : %s · Perso : %s niv. %s %s · Or : %s", ns.realmKey(), plain(UnitName("player")),
    tostring(UnitLevel and UnitLevel("player") or "?"), plain(UnitClass and UnitClass("player") or "?"),
    g(GetMoney and GetMoney() or 0))
  local skills = {}
  for k, r in pairs(c.skills) do skills[#skills + 1] = ("%s %d/%d"):format(ns.Prof.LABEL[k] or k, r, c.max and c.max[k] or 0) end
  table.sort(skills)
  add("Métiers : %s", #skills > 0 and table.concat(skills, ", ") or "inconnus")
  local nDays, obs = 0, 0
  for _, d in pairs(db.days or {}) do nDays, obs = nDays + 1, obs + d.obs end
  local cal = db.calib or {}
  add("Données : %d j d'historique, %.0f h de marché observées, dernier scan %s · commission %.1f%% (%s), dépôt %.0f%% du prix PNJ",
    nDays, obs / 3600, db.lastScanTime and date("%Y-%m-%d %H:%M", db.lastScanTime) or "jamais",
    A.AH_CUT * 100, cal.cut and "mesurée" or "supposée", A.DEPOSIT_RATE * 100)
  add("Unités : prix par unité sauf mention (g/s/c = or/argent/cuivre) ; tend = variation du prix par jour ; écoul = part des enchères vendues avant expiration ; stockJ = jours de ventes en rayon.")

  local all = A.All().list
  local market = {}
  for _, s in ipairs(all) do if s.perDay and s.perDay >= 1 then market[#market + 1] = s end end

  add("")
  add("## Marché : meilleurs scores (or/jour net × tendance × signaux)")
  add("objet | prix | achat min | moy 7j | tend 7j | tend 24h | vendus/j | stockJ | écoul | vendeurs (top) | or/jour | signaux")
  for _, s in ipairs(sorted(market, "score", Export.TOP.market)) do
    add("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s", nameOf(s.id, s), g(s.price), g(s.minNow), g(s.avg7),
      pct(s.trend), pct(s.trend24), num(s.perDay), num(s.stockDays, "%.1f"),
      s.sellThrough and ("%.0f%%"):format(s.sellThrough * 100) or "-",
      s.sellers and ("%d (%.0f%%)"):format(s.sellers, (s.topShare or 0) * 100) or "-", g(s.gpd), table.concat(s.signals, ", "))
  end

  local moving = {}
  for _, s in ipairs(market) do
    if s.trend and (s.confidence or 0) >= 0.5 then moving[#moving + 1] = { s = s, abs = math.abs(s.trend) } end
  end
  add("")
  add("## Plus fortes variations de prix (marchés liquides)")
  if #moving == 0 then add("pas encore de tendance fiable (il faut 3 jours de prix)") end
  for _, m in ipairs(sorted(moving, "abs", Export.TOP.rising)) do
    local s = m.s
    add("%s : %s/j sur 7 j, %s sur 24 h, prix %s, %s vendus/j", nameOf(s.id, s), pct(s.trend), pct(s.trend24), g(s.price), num(s.perDay))
  end

  add("")
  add("## Flips HV possibles (dernier scan)")
  local flips = sorted(A.Flips(), "profit", Export.TOP.flip)
  if #flips == 0 then add("aucun") end
  for _, f in ipairs(flips) do
    add("%s : acheter %d jusqu'à %s/u (coût %s), revendre %s/u → bénéfice %s (ROI %.0f%%, écoulé en %.1f j)",
      nameOf(f.id, f.s), f.qty, g(f.maxBuy), g(f.cost), g(f.resale), g(f.profit), f.roi * 100, f.days)
  end

  add("")
  add("## Artisanat (recettes connues)")
  local crafts = {}
  for _, e in ipairs(A.Crafts()) do if e.profit then crafts[#crafts + 1] = e end end
  crafts = sorted(crafts, "profit", Export.TOP.craft)
  if #crafts == 0 then add("aucune recette relevée (ouvrir les fenêtres de métier)") end
  for _, e in ipairs(crafts) do
    add("%s (%s, %s) : coût %s, valeur %s (%s), bénéfice %s, %s vendus/j", nameOf(e.id, e.s), ns.Prof.LABEL[e.prof] or e.prof,
      e.diff or "?", g(e.cost), g(math.max(e.value or 0, e.vendorValue)), e.sellTo or "-", g(e.profit), num(e.perDay))
  end

  for _, prof in ipairs(ns.Plan.CraftProfs()) do
    local rank = ns.Prof.Skill(prof)
    local maxRank = c.max and c.max[prof]
    if rank and maxRank and rank < maxRank then
      local p = ns.Plan.Level(prof, rank, maxRank)
      add("")
      add("## Montée %s %d → %d%s : %d fabrications, coût net %s", ns.Prof.LABEL[prof] or prof, p.from, p.reached,
        p.partial and " (plan partiel, seuils des recettes inconnus)" or "", math.ceil(p.crafts), g(p.total))
      for _, l in ipairs(ns.Plan.Describe(p)) do add("%s", l) end
    end
  end

  add("")
  add("## Mes objets (sacs%s)", c.bankTime and (" + banque vue le " .. date("%d/%m", c.bankTime)) or "")
  local bags = sorted(ns.Bags.Advice(), "value", Export.TOP.bags)
  if #bags == 0 then add("rien de valeur") end
  for _, e in ipairs(bags) do
    add("%s x%d (%s) : %s%s, valeur nette %s — %s", nameOf(e.id, e.s), e.count, e.where, e.action,
      e.post and (" à " .. g(e.post) .. "/u, " .. (e.postQty or e.count) .. " à la fois") or "", g(e.value), plain(e.why))
  end

  local rows, tot = ns.Ledger.Summary()
  add("")
  add("## Bilan réel %d j (courriers d'HV)", ns.Ledger.DAYS)
  add("recettes %s, achats %s, solde %s, %d vendus, %d expirés", g(tot.revenue), g(tot.spent), g(tot.revenue - tot.spent), tot.sold, tot.expired)
  for _, r in ipairs(sorted(rows, "balance", Export.TOP.ledger)) do
    add("%s : %d achetés (%s), %d vendus (%s, moy. %s/u, %s vs prévu), %d expirés, solde %s", r.id and nameOf(r.id) or plain(r.name),
      r.bought, g(r.spent), r.sold, g(r.revenue), g(r.avgSale), pct(r.gap), r.expired, g(r.balance))
  end

  add("")
  add("## Achat PNJ → revente HV")
  local vf = sorted(A.VendorFlips(), "gpd", Export.TOP.vendor)
  if #vf == 0 then add("aucun") end
  for _, e in ipairs(vf) do
    add("%s : achat %s chez %s (%s), revente %s, marge %s/u, %s vendus/j", nameOf(e.id, e.s), g(e.buy), plain(e.npc), plain(e.zone),
      g(e.s.price), g(e.margin), num(e.perDay))
  end

  add("")
  add("## Zones de farm (sessions /ahl farm)")
  local farm = sorted(A.FarmZones(), "total", Export.TOP.farm)
  if #farm == 0 then add("aucune session") end
  for _, z in ipairs(farm) do
    add("%s : %.1f h, %s/h au total (objets %s/h, or ramassé %s/h), meilleur objet %s", plain(z.zone), z.hours, g(z.total),
      g(z.itemsPerHour), g(z.moneyPerHour), z.best and nameOf(z.best) or "-")
  end

  local snipes = db.snipes or {}
  if #snipes > 0 then
    local total = 0
    for _, o in ipairs(snipes) do total = total + o.profit end
    add("")
    add("## Revente PNJ : %d enchères sous le prix du marchand, %s de bénéfice au total", #snipes, g(total))
  end

  add("")
  local diag = AHLedgerDB.diag
  if diag then
    add("## Diagnostic du client (%s)", date("%Y-%m-%d %H:%M", diag.t))
    for _, l in ipairs(diag.lines) do add("%s", l) end
    add("")
  end
  add("Question : d'après ces données, que dois-je faire en priorité pour gagner de l'or (vendre, acheter, fabriquer, farmer) ?")
  return table.concat(L, "\n")
end

function Export.Save()
  AHLedgerDB.brief = { t = time(), realm = ns.realmKey(), text = Export.Build() }
end

-- Fenêtre de copie
function Export.Show()
  local text = Export.Build()
  AHLedgerDB.brief = { t = time(), realm = ns.realmKey(), text = text }
  local f = Export.frame
  if not f then
    local Look = ns.Look
    local T = Look.Top()
    f = Look.Window("AHLedgerExportFrame", 640, 460, "DIALOG")
    Export.frame = f
    f.titleText:SetText("AHLedger — rapport pour Claude : Ctrl+C puis colle-le dans Claude")
    local sf
    if Look.Daylight() then
      -- zone de texte un ton plus sombre, défilement à la molette (pas de barre du jeu)
      local box = CreateFrame("Frame", nil, f)
      box:SetPoint("TOPLEFT", 12, -30 - T)
      box:SetPoint("BOTTOMRIGHT", -12, 12)
      Look.Inset(box)
      sf = CreateFrame("ScrollFrame", nil, box)
      sf:SetPoint("TOPLEFT", 8, -8)
      sf:SetPoint("BOTTOMRIGHT", -8, 8)
      sf:EnableMouseWheel(true)
      sf:SetScript("OnMouseWheel", function(self, delta)
        local y = self:GetVerticalScroll() - delta * 40
        self:SetVerticalScroll(math.max(0, math.min(y, self:GetVerticalScrollRange())))
      end)
    else
      sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
      sf:SetPoint("TOPLEFT", 12, -30)
      sf:SetPoint("BOTTOMRIGHT", -32, 12)
    end
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetMaxLetters(0)
    eb:SetFontObject(ChatFontNormal)
    if Look.Daylight() then
      local font = Look.API().Font and Look.API().Font()
      if font then eb:SetFont(font, 12, "") end
    end
    eb:SetWidth(590)
    eb:SetAutoFocus(true)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    sf:SetScrollChild(eb)
    f.edit = eb
  end
  f.edit:SetText(text)
  f:Show()
  f.edit:SetFocus()
  f.edit:HighlightText()
  ns.print(("Rapport prêt (%d caractères) : Ctrl+C dans la fenêtre, puis colle-le dans Claude."):format(#text))
end

ns.on("PLAYER_LOGOUT", function() ns.safe("rapport", Export.Save) end)
