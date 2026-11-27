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

Export.TOP = { market = 25, rising = 10, flip = 12, craft = 12, bags = 25, auctions = 30, ledger = 12, vendor = 8, farm = 6 }

local function plain(s) return (tostring(s or "?"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
-- cuivre -> "12g 34s" / "3s 05c" (sans codes couleur)
local function g(c)
  if not c then return "-" end
  return plain(ns.money(c))
end
local function pct(v) return v and ("%+.1f%%"):format(v * 100) or "-" end
local function num(v, fmt) return v and (fmt or "%.0f"):format(v) or "-" end

-- Pourquoi une liste d'achats est vide sur un scan périmé (nil si le scan est récent)
local function staleWhy()
  local stale, age = ns.Analysis.Stale()
  if not stale then return nil end
  return age and ("scan vieux de %.0f h : aucun achat conseillé, rescanne l'HV"):format(age) or "pas de scan : aucun achat conseillé"
end

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
  add("Unités : prix par unité sauf mention (g/s/c = or/argent/cuivre) ; ventes/j = ventes sûres (enchères parties bien avant la fin de leur durée, annulations exclues) ; écoul = part des enchères vendues avant expiration (« - » tant que pas mesuré) ; tend = variation du prix par jour sur 4 j au moins ; stockJ = jours de ventes en rayon.")

  if ns.Advisor then ns.safe("conseils (rapport)", Export.Advice, add) end

  local all = A.All().list
  local market = {}
  for _, s in ipairs(all) do if s.surePerDay and s.surePerDay >= 1 then market[#market + 1] = s end end

  add("")
  add("## Marché : meilleurs scores (or/jour net des ventes sûres)")
  add("objet | prix | achat min | moy 7j | tend 7j | ventes/j | jours avec ventes | stockJ | écoul | or/jour | signaux")
  for _, s in ipairs(sorted(market, "score", Export.TOP.market)) do
    add("%s | %s | %s | %s | %s | %s | %d/7 | %s | %s | %s | %s", nameOf(s.id, s), g(s.price), g(s.minNow), g(s.avg7),
      pct(s.trend), num(s.surePerDay, "%.1f"), s.salesDays or 0, num(s.stockDays, "%.1f"),
      s.stReliable and ("%.0f%%"):format(s.sellThrough * 100) or "-", g(s.gpd), table.concat(s.signals, ", "))
  end

  add("")
  add("## Flips HV possibles (dernier scan)")
  local flips = sorted(A.Flips(), "profit", Export.TOP.flip)
  if #flips == 0 then add(staleWhy() or "aucun") else add("seulement des objets aux ventes prouvées (1 vente sûre/j au moins, 2 jours sur 7). « tout de suite » = remettre en vente aussitôt ; « à stocker » = tout le marché est bas, garder jusqu'au rebond (d'après les creux passés de l'objet)") end
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
    if f.mine then
      add("  tes reventes : %d achetés puis revendus, %s/u net", f.mine.units, g(f.mine.profit))
    end
  end

  add("")
  add("## Artisanat (recettes connues)")
  local crafts = {}
  add("classées par or/jour possible : bénéfice × ta part des ventes sûres (25 %), ou 20 fabrications/j revendues au PNJ ; 0 si le verdict n'est pas « fabriquer » (marge sous 15 %, ou l'objet ne se vend pas)")
  for _, e in ipairs(A.Crafts()) do if e.profit then crafts[#crafts + 1] = e end end
  crafts = sorted(crafts, "daily", Export.TOP.craft)
  if #crafts == 0 then add("aucune recette relevée (ouvrir les fenêtres de métier)") end
  for _, e in ipairs(crafts) do
    add("%s (%s, %s) : composants vendus bruts %s, coût %s, fabriqué %s (%s), bénéfice %s → %s, se vend : %s, %s ventes sûres/j, ~%s fabrications/j → %s/j", nameOf(e.id, e.s),
      ns.Prof.LABEL[e.prof] or e.prof, e.diff or "?", g(e.raw), g(e.cost), g(e.value), e.sellTo or "-",
      g(e.profit), e.ok and "fabriquer" or "ne pas fabriquer", e.sells or "?", num(e.perDay, "%.1f"), num(e.vol), g(e.daily))
  end

  for _, prof in ipairs(ns.Plan.CraftProfs()) do
    local rank = ns.Prof.Skill(prof)
    local maxRank = c.max and c.max[prof]
    if rank and maxRank and rank < maxRank then
      local p = ns.Plan.Level(prof, rank, maxRank)
      add("")
      add("## Montée %s %d → %d%s : %d fabrications, coût net %s (négatif = gain si tout se revend), à avancer %s", ns.Prof.LABEL[prof] or prof,
        p.from, p.reached, p.partial and " (plan partiel, seuils des recettes inconnus)" or "", math.ceil(p.crafts), g(p.total), g(p.outlay))
      for _, l in ipairs(ns.Plan.Describe(p)) do add("%s", l) end
    end
  end

  add("")
  add("## Mes objets (sacs%s)", c.bankTime and (" + banque vue le " .. date("%d/%m", c.bankTime)) or "")
  local bags = sorted(ns.Bags.Advice(), "value", Export.TOP.bags)
  if #bags == 0 then add("rien de valeur") end
  add("décision d'AHLedger, puis sa raison et ses preuves (source : fait)")
  for _, e in ipairs(bags) do
    add("%s x%d (%s) : %s, valeur %s — %s%s", nameOf(e.id, e.s), e.count, e.where, plain(ns.Decide.Line(e.d)), g(e.value),
      plain(e.why), #e.d.warn > 0 and (" — attention : " .. plain(table.concat(e.d.warn, " ; "))) or "")
  end

  Export.MyAuctions(add)
  if ns.Undercut then
    add("")
    add("## Sous-cotes de mes enchères (%d j ; délai = maximum, vendeurs inconnus sur Forever)", ns.Undercut.KEEP_DAYS)
    for _, l in ipairs(ns.Undercut.Lines(8)) do add("%s", plain(l)) end
  end

  -- même calcul que l'onglet Bilan et /ahl bilan (Tracker) : farm + reventes + fabrication − dépôts perdus
  local _, _, ttot, items = ns.Tracker.Compute()
  add("")
  add("## Bilan réel %d j (achats relevés à l'HV et chez le marchand, fabrications relevées, ventes et expirations des courriers)", ns.Ledger.DAYS)
  add("%s", plain(ns.Tracker.Headline(ttot)))
  local rows = {}
  for _, it in pairs(items) do
    if it.sold + it.bought + it.crafted > 0 or it.lostDep > 0 then it.impact = math.abs(it.real); rows[#rows + 1] = it end
  end
  -- les plus gros gains ET les plus grosses pertes d'abord
  for _, it in ipairs(sorted(rows, "impact", Export.TOP.ledger)) do
    add("%s : bilan réel %s (farm %s, reventes %s, fabrication %s, dépôts perdus %s) · %d achetés %s, %d fabriqués, %d vendus %s net%s",
      it.id and nameOf(it.id) or plain(it.name or "?"), g(it.real), g(it.farm), g(it.gain), g(it.craftGain), g(it.lostDep),
      it.bought + it.boughtPNJ, g(it.spent + it.spentPNJ), it.crafted, it.sold, g(it.revenue),
      it.left > 0 and (" · stock %d (prix de revient %s, vaut %s)"):format(it.left, g(it.leftCost), g(it.leftValue)) or "")
  end

  add("")
  add("## Achat PNJ → revente HV (prouvées seulement)")
  local vf = sorted(A.VendorFlips(), "gpd", Export.TOP.vendor)
  if #vf == 0 then add(staleWhy() or "aucun") end
  for _, e in ipairs(vf) do
    local tail
    if e.realSold then tail = (" · toi : %d vendus à %s, %d expirés"):format(e.realSold, g(e.realAvg), e.realExpired or 0) else tail = "" end
    local verdict = e.reliable and "fiable" or ("à tester (%s) : %d u d'abord"):format(e.why, e.testQty or 1)
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

  local snipes = A.Stale() and {} or db.snipes or {}
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

-- Ce que tu as en vente en ce moment, comparé au dernier scan
-- En tête du rapport : les conseils de l'onglet Conseils, puis ce que le bilan dit d'arrêter
local VERB = { mail = "Courrier", sell = "Vendre HV", test = "Tester HV", craftup = "Fabriquer puis vendre", npc = "Vendre PNJ",
               relist = "Reprendre l'enchère", flipsell = "Revendre (flip)", flip = "Flip HV", vendor = "Acheter PNJ",
               craft = "Fabriquer", farm = "Farmer", level = "Monter le métier" }
Export.TOP.advice = 15
function Export.Advice(add)
  local Adv = ns.Advisor
  local rows = {}
  for _, e in ipairs(Adv.Actions()) do rows[#rows + 1] = e end
  table.sort(rows, function(a, b) return a.rank > b.rank end)
  add("")
  add("## À faire maintenant (conseils AHLedger, du plus immédiat au plus lointain)")
  add(plain(Adv.Headline(rows)))
  add("action | quoi | qté | prix/u | gain | sûr ? | pourquoi")
  for i = 1, math.min(Export.TOP.advice, #rows) do
    local e = rows[i]
    local gain = e.kind == "level" and (g(math.abs(e.gold or 0)) .. (e.gold >= 0 and " gagnés/pt" or " /pt"))
      or (g(e.gold or 0) .. (e.perDay and "/j" or ""))
    add("%s | %s | %s | %s | %s | %s | %s", e.verbText or VERB[e.kind] or e.kind, plain(e.label or nameOf(e.id, e.s)),
      e.kind == "level" and "-" or tostring(e.qty or "-"), e.price and g(e.price) or "-", gain, e.conf or "?", plain(e.why))
  end
  local stop = {}
  for _, e in ipairs(Adv.Review()) do
    if e.verdict == "stop" or e.verdict == "loss" then stop[#stop + 1] = e end
  end
  table.sort(stop, function(a, b) return a.impact > b.impact end)
  if #stop > 0 then
    add("À arrêter (30 j de courriers) : %s", table.concat((function()
      local t = {}
      for i = 1, math.min(8, #stop) do t[i] = ("%s (%s)"):format(nameOf(stop[i].id, nil), plain(stop[i].advice)) end
      return t
    end)(), " ; "))
  end
end

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
    local market = s and (" · marché : moins cher %s, prix réel %s, %s ventes sûres/j"):format(g(s.minNow), g(s.price), num(s.surePerDay, "%.1f")) or ""
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
