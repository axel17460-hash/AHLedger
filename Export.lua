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

-- Version de METHODE.md (racine du dépôt, copiée à côté de rapport.md par tools/ahledger.py sync) :
-- comment Claude lit ce rapport. À relever quand la méthode change.
Export.METHODE = 1

Export.TOP = { market = 25, rising = 10, flip = 12, craft = 12, recipes = 12, undercut = 12, bags = 25, auctions = 30, ledger = 12, vendor = 8, farm = 6, timing = 12 }

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
  add("Méthode de lecture : METHODE.md v%d (à côté de ce rapport dans Drive, ou à la racine de l'addon) : lis-la avant de conseiller.", Export.METHODE)
  add("Royaume : %s · Perso : %s niv. %s %s · Or : %s", ns.realmKey(), plain(UnitName("player")),
    tostring(UnitLevel and UnitLevel("player") or "?"), plain(UnitClass and UnitClass("player") or "?"),
    g(A.Gold() or 0))
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
  local bt = A.biasT or (ns.Ledger.BiasTable and ns.Ledger.BiasTable(db))
  if bt and bt.n > 0 then
    add("Tes ventes réelles vs prix prévu : %+.0f %% en moyenne sur %d ventes → ce qu'une vente rapporte est corrigé ×%.2f (par objet dès ta 1re vente, rapproché de la moyenne)",
      ((bt.raw or 1) - 1) * 100, bt.n, bt.global)
  end
  local budget = A.Budget()
  if budget then
    add("Budget d'un conseil d'achat : %s (%.0f %% de ton or) ; flips et achats PNJ plafonnés à ce montant", g(budget), A.BUDGET_SHARE * 100)
  end
  add("Unités : prix par unité sauf mention (g/s/c = or/argent/cuivre) ; tend = variation du prix par jour ; écoul = part des enchères vendues avant expiration ; stockJ = jours de ventes en rayon.")

  Export.Today(add)

  local all = A.All().list
  local market = {}
  for _, s in ipairs(all) do if s.perDay and s.perDay >= 1 then market[#market + 1] = s end end

  add("")
  add("## Marché : meilleurs scores (or/jour net × tendance × signaux)")
  add("objet | prix | achat min | moy 7j | tend 7j | tend 24h | vendus/j | relistes/j | stockJ | écoul | vendeurs (top) | or/jour | signaux")
  add("(relistes/j : enchères retirées ou remises en vente, écartées des ventes)")
  for _, s in ipairs(sorted(market, "score", Export.TOP.market)) do
    add("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s", nameOf(s.id, s), g(s.price), g(s.minNow), g(s.avg7),
      pct(s.trend), pct(s.trend24), num(s.perDay), num(s.relistPerDay), num(s.stockDays, "%.1f"),
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
  if (A.flipsOverBudget or 0) > 0 then
    add("%d flip%s rentable%s écarté%s : hors de ton budget (%s)", A.flipsOverBudget, A.flipsOverBudget > 1 and "s" or "",
      A.flipsOverBudget > 1 and "s" or "", A.flipsOverBudget > 1 and "s" or "", g(A.flipBudget or 0))
  end
  if #flips == 0 then add("aucun") else add("« tout de suite » = remettre en vente aussitôt ; « à stocker » = tout le marché est bas, garder jusqu'au rebond (bénéfice espéré, d'après les creux passés de l'objet)") end
  for _, f in ipairs(flips) do
    if f.kind == "stock" then
      local odds = f.known and ("%d creux sur %d remontés, délai médian %s j, lent %s j"):format(
        f.recovered, f.events, tostring(f.wait or "?"), tostring(f.slow or "?"))
        or ("rebond inconnu (%d creux vus), quantité de test"):format(f.events or 0)
      add("%s [à stocker] : acheter %d jusqu'à %s/u (coût %s), revendre %s/u au rebond (prix d'aujourd'hui %s/u) → espéré %s (si rebond %s, sinon %s ; ROI %.0f%%) — %s%s",
        nameOf(f.id, f.s), f.qty, g(f.maxBuy), g(f.cost), g(f.resale), g(f.resaleNow), g(f.profit), g(f.ifUp), g(f.ifDown),
        f.roi * 100, odds, f.weekday and (", meilleur jour de vente : " .. f.weekday.name) or "")
    else
      add("%s [tout de suite] : acheter %d jusqu'à %s/u (coût %s), revendre %s/u → bénéfice %s (ROI %.0f%%, écoulé en %.1f j)",
        nameOf(f.id, f.s), f.qty, g(f.maxBuy), g(f.cost), g(f.resale), g(f.profit), f.roi * 100, f.days)
    end
    if f.budgetCut then add("  quantité limitée par ton budget") end
    if f.mine then
      add("  tes reventes : %d achetés puis revendus, gardés ~%.1f j, %s/u", f.mine.units, f.mine.days, g(f.mine.profit))
    end
  end

  add("")
  add("## Artisanat (recettes connues)")
  local crafts = {}
  add("classées par or/jour possible : bénéfice × ta part des ventes du marché (25 %), ou 20 fabrications/j revendues au PNJ")
  for _, e in ipairs(A.Crafts()) do if e.profit then crafts[#crafts + 1] = e end end
  crafts = sorted(crafts, "daily", Export.TOP.craft)
  if #crafts == 0 then add("aucune recette relevée (ouvrir les fenêtres de métier)") end
  for _, e in ipairs(crafts) do
    add("%s (%s, %s) : coût %s, valeur %s (%s), bénéfice %s, %s vendus/j, ~%s fabrications/j → %s/j", nameOf(e.id, e.s),
      ns.Prof.LABEL[e.prof] or e.prof, e.diff or "?", g(e.cost), g(math.max(e.value or 0, e.vendorValue)), e.sellTo or "-",
      g(e.profit), num(e.perDay), num(e.vol), g(e.daily))
    if e.spike then
      add("  pic de prix : %s/u aujourd'hui contre %s d'habitude, valeur comptée au prix habituel",
        g(e.s.price), g(e.s.usual))
    end
    if e.slow and (e.ahValue or 0) > e.vendorValue then
      add("  HV écartée (%s) : vends plutôt les composants", e.slowWhy)
    end
  end

  add("")
  add("## Recettes rentables à poursuivre (apprises ou non, tous métiers)")
  local plain = function(s) return (tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
  local recs = sorted(ns.Opp.Recipes(), "daily", Export.TOP.recipes)
  if #recs == 0 then add("aucune (ouvrir les fenêtres de métier, ou installer OneForAll)") end
  for _, e in ipairs(recs) do
    add("%s (%s) : %s — coût %s, bénéfice %s (ROI %.0f%%), vente %s, %s/j%s", nameOf(e.id, e.s), ns.Prof.LABEL[e.prof] or e.prof,
      plain(e.access), g(e.cost), g(e.profit), e.roi * 100, e.sellTo, g(e.daily),
      e.payback and e.payback > 0 and (", recette amortie en %.1f j"):format(e.payback) or "")
  end

  add("")
  add("## Sous-coter : enchère la moins chère au-dessus du prix habituel")
  local ucs = sorted(ns.Opp.Undercuts(), "score", Export.TOP.undercut)
  if #ucs == 0 then add("aucune") end
  for _, e in ipairs(ucs) do
    add("%s : poster %d à %s/u (habituel %s/u, %s), gain en plus %s, %s vendus/j, %s vendeurs%s", nameOf(e.id, e.s), e.qty,
      g(e.post), g(e.fair), ns.pct(e.premium), g(e.extra), num(e.perDay), e.sellers and tostring(e.sellers) or "?",
      e.notes ~= "" and (" — " .. plain(e.notes)) or "")
  end

  for _, prof in ipairs(ns.Plan.CraftProfs()) do
    local rank = ns.Prof.Skill(prof)
    local maxRank = c.max and c.max[prof]
    if rank and maxRank and rank < maxRank then
      local p = ns.Plan.Level(prof, rank, maxRank)
      add("")
      local gold = A.Gold()
      add("## Montée %s %d → %d%s : %d fabrications, coût net %s (négatif = gain si tout se revend), à avancer %s%s", ns.Prof.LABEL[prof] or prof,
        p.from, p.reached, p.partial and " (plan partiel, seuils des recettes inconnus)" or "", math.ceil(p.crafts), g(p.total), g(p.outlay),
        (gold and p.outlay > gold) and (" (tu n'as que %s)"):format(g(gold)) or "")
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

  Export.MyAuctions(add)
  local okT, errT = pcall(Export.Timing, add)
  if not okT then add(""); add("## Meilleur moment pour vendre"); add("indisponible : %s", plain(tostring(errT))) end

  add("")
  add("## Fiabilité des conseils (vérifiés sur les scans suivants)")
  add("prix tenu = la revente annoncée était atteignable ; écoulé = le marché a acheté au moins la quantité à ce prix (estimé : une annulation compte comme une vente) ; réussi = les deux ; suivi = tu as acheté l'objet dans les 24 h")
  local track = ns.Track and ns.Track.Lines(nil, g) or {}
  if #track == 0 then add("rien de vérifié pour l'instant") end
  for _, l in ipairs(track) do add("%s", l) end

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
    local tail
    if e.realSold then tail = (" · toi : %d vendus à %s, %d expirés"):format(e.realSold, g(e.realAvg), e.realExpired or 0) else tail = "" end
    local verdict = e.reliable and "fiable" or ("à tester (%s) : %d u d'abord"):format(e.why, e.testQty or 1)
    if e.budgetCut then verdict = verdict .. ", limité par ton budget" end
    add("%s : achat %s chez %s (%s), revente %s (×%.0f), marge nette %s/u, %s vendus/j dans tout l'HV (vise %s/j) — %s%s",
      nameOf(e.id, e.s), g(e.buy), plain(e.npc), plain(e.zone), g(e.s.price), e.markup, g(e.margin), num(e.perDay), num(e.vol), verdict, tail)
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

-- Plan de séance (Today.lua) : ce qu'il y a de plus rentable à faire maintenant, en une heure
Export.TODAY_MINUTES = 60
function Export.Today(add)
  if not ns.Today then return end
  add("")
  add("## Aujourd'hui : plan de séance de %d min (classé par gain/minute, fiabilité comprise)", Export.TODAY_MINUTES)
  local ok, lines, total = pcall(ns.Today.Lines, Export.TODAY_MINUTES)
  if not ok then add("plan indisponible : %s", plain(lines)); return end
  add("%s", total)
  if #lines == 0 then add("rien à proposer (scan, sacs, métiers ou sessions de farm manquants)") end
  for _, l in ipairs(lines) do add("%s", l) end
end

-- Ce que tu as en vente en ce moment, comparé au dernier scan
function Export.MyAuctions(add)
  add("")
  local groups, t = ns.Auctions.Summary()
  if not groups then
    add("## Mes enchères en cours")
    add("liste jamais relue : ouvre l'HV une fois pour que l'addon voie tes enchères")
    return
  end
  local age = time() - t
  add("## Mes enchères en cours (liste relue le %s%s)", date("%d/%m %H:%M", t),
    age > 2 * 86400 and ", ancienne : ouvre l'HV pour la mettre à jour" or "")
  local up, upValue, soldValue, under = 0, 0, 0, 0
  for _, gr in ipairs(groups) do
    if gr.isSold then soldValue = soldValue + gr.value
    else
      up, upValue = up + gr.auctions, upValue + gr.value
      if gr.status == "sous-coté" then under = under + 1 end
    end
  end
  if #groups == 0 then add("aucune enchère en cours"); return end
  add("%d enchères en cours, %s net si tout part ; %d lots sous-cotés ; vendu en attente au courrier : %s",
    up, g(upValue), under, g(soldValue))
  table.sort(groups, function(a, b) return a.value > b.value end)
  for i = 1, math.min(#groups, Export.TOP.auctions) do
    local gr = groups[i]
    local s = gr.s
    local left = gr.left and math.max(gr.left - age, 0)
    local price = gr.unit and (g(gr.unit) .. "/u") or ("enchère " .. g(gr.bid))
    local market = s and (" · marché : moins cher %s, prix réel %s, %s vendus/j"):format(g(s.minNow), g(s.price), num(s.perDay)) or ""
    local verdict = gr.status
    if gr.gap then verdict = ("%s (%s)"):format(gr.status, pct(gr.gap)) end
    if gr.isSold then
      add("%s x%d : vendu à %s, %s net à récupérer au courrier", nameOf(gr.id, s), gr.qty, price, g(gr.value))
    else
      add("%s x%d (%d enchère%s) : %s, reste %s, %s%s%s, net si tout part %s", nameOf(gr.id, s), gr.qty, gr.auctions,
        gr.auctions > 1 and "s" or "", price, left and ns.Auctions.LeftText(left) or "?", verdict, market,
        gr.days and (", ~%.1f j pour tout vendre à 25 %% du marché"):format(gr.days) or "", g(gr.value))
    end
  end
end

-- Meilleur jour et meilleure heure pour vendre (Timing.lua)
function Export.Timing(add)
  local T = ns.Timing
  if not T then return end
  local db = ns.realmDB()
  add("")
  add("## Meilleur moment pour vendre (heure locale)")
  add("enchères vendues par heure de marché observée, comparées à la moyenne (×1.35 = 35 % de ventes en plus) ; tes heures de scan ne comptent pas, une case jamais observée est « ? »")
  local p = T.Profile(db)
  add("Tout l'HV : %s", T.Describe(p))
  if p.status ~= "low" then
    add("par jour : %s", T.IndexLine(p.days, 0, 6, function(k) return T.DAYS[k] end))
    add("par tranche : %s", T.IndexLine(p.slots, 0, T.SLOTS - 1, function(k) return T.SLOT_LABELS[k] end))
  end
  local items = T.Items(db, "hint")
  if #items == 0 then add("aucun objet avec un moment marqué pour l'instant") end
  for i = 1, math.min(#items, Export.TOP.timing) do
    local e = items[i]
    add("%s : %s", nameOf(e.id), T.Describe(e))
  end
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
