-- AHLedger - Fenêtre de classement (/ahl)
local _, ns = ...

local UI = { mode = "advice", offset = 0, cat = 1, liquidOnly = true, sortDesc = true }
ns.UI = UI

-- Gestionnaires de la fenêtre sous ns.safe : une erreur est notée (/ahl diag) sans casser l'interface
local function script(frame, event, fn)
  frame:SetScript(event, function(...) ns.safe("fenêtre", fn, ...) end)
end

local ROWS, ROW_H, WIDTH, MAX_COLS, GAP = 16, 20, 820, 9, 5
local MAX_ROWS = 40 -- lignes créées ; seules celles qui tiennent dans la hauteur disponible s'affichent
-- haut du tableau (en-têtes) ; l'onglet Opérations intercale au-dessus un bandeau de résumé de BAND_H px
local TOP, BAND_H = 78, 48
-- panneau de détail sous le tableau : la ligne survolée (ou la première) en entier, plus de texte coupé
local DETAIL_H = 80

local CATS = {
  { "Tout", nil },
  { "Matériaux", { [7] = true } },
  { "Consommables", { [0] = true } },
  { "Recettes", { [9] = true } },
  { "Équipement", { [2] = true, [4] = true } },
  { "Mes métiers", "prof" }, -- ce que tu récoltes, fabriques, et leurs composants
}

-- Conseils de « Mes flips » : libellé et ordre de tri (ce qui demande d'agir en premier)
local POS_VERDICT = { high = "|cff40ff40Vends ! prix haut|r", sell = "|cff40ff40Vends maintenant|r",
                      drop = "|cffffff00Vends (baisse)|r", late = "|cffffff00Vends (délai)|r",
                      undercut = "|cffff8040Remets en vente|r", loss = "|cffff5050Revoir (perte)|r",
                      wait = "|cff66ccffAttends|r", listed = "|cffccccccEn vente|r",
                      gone = "|cff808080Sorti|r", done = "|cff808080Refermé|r" }
local POS_RANK = { high = 9, sell = 8, drop = 7, late = 6, undercut = 5, loss = 4, wait = 3, listed = 2, gone = 1, done = 0 }

local JOURNAL_KIND = { buy = "|cff66ccffAchat|r", sell = "|cff40ff40Vente|r", exp = "|cffff8040Expiré|r",
                       craft = "|cffff9900Fabriqué|r" }
local JOURNAL_UNIT = { buy = "achats", sell = "ventes", exp = "enchères", craft = "fabrications" }

-- Conseils : le verbe de chaque action, et d'où vient la preuve
local ADV_VERB = { sell = "|cff40ff40Vendre à l'HV|r", test = "|cffffd100Tester à l'HV|r", npc = "|cffff5050Vendre au PNJ|r",
                   craftup = "|cffff9900Fabriquer|r", mail = "|cff40ff40Courrier|r", relist = "|cffff8040Reprendre|r",
                   flipsell = "|cff40ff40Vendre (flip)|r", flip = "|cff66ccffFlip HV|r", vendor = "|cff66ccffAcheter PNJ|r",
                   craft = "|cffff9900Fabriquer|r", farm = "|cffd0b070Farmer|r", level = "|cffb080ffMonter|r" }
local CONF = { ["prouvé"] = "|cff40ff40prouvé|r", certain = "|cff40ff40certain|r", ["à confirmer"] = "|cffffd100à confirmer|r",
               ["à tester"] = "|cffff9900à tester|r", calcul = "|cffccccccestimé|r" }
-- un clic sur ces conseils montre l'objet à l'HV (si elle est ouverte) ; les autres ouvrent l'onglet du détail
local ADV_AT_AH = { sell = true, test = true, relist = true, flip = true, flipsell = true }
-- Mes enchères : que faire de chacune
local AUC_VERDICT = { sold = "|cff40ff40Récupère l'or|r", keep = "|cffccccccLaisse|r", relist = "|cffff8040Annule, remets|r",
                      relistlater = "|cffffd100Remets au retour|r", wait = "|cff66ccffLaisse (bradé)|r", npc = "|cffff5050Laisse, puis PNJ|r" }
local AUC_RANK = { relist = 6, relistlater = 5, sold = 4, npc = 3, wait = 2, keep = 1 }
-- Bilan : ce qui marche et ce qui ne marche pas
local REVIEW = { works = "|cff40ff40Ça marche|r", gain = "|cff40ff40Flip gagnant|r", price = "|cffffd100Prix trop haut|r",
                 stop = "|cffff5050Ne marche pas|r", loss = "|cffff5050Flip perdant|r", early = "|cff808080Trop tôt|r",
                 hold = "|cff66ccffEn stock|r" }
local REVIEW_RANK = { loss = 7, stop = 6, price = 5, hold = 4, gain = 3, works = 2, early = 1 }

-- +12 po en vert, −3 pa en rouge (gras = résultat)
local function signed(v, strong)
  if not v then return "-" end
  local txt = (v >= 0 and "+" or "-") .. ns.money(math.abs(v))
  if math.abs(v) < 0.5 then return "|cffcccccc" .. txt .. "|r" end
  local col = v >= 0 and (strong and "|cff40ff40" or "|cff80e080") or (strong and "|cffff5050" or "|cffe08080")
  return col .. txt .. "|r"
end

-- « Mes objets » : quoi faire, dans l'ordre où le faire
local BAG_ACTION = { HV = "|cff40ff40Vendre à l'HV|r", Tester = "|cffffd100Tester à l'HV|r", PNJ = "|cffff5050Vendre au PNJ|r",
                     Fabriquer = "|cffff9900Fabriquer|r", Attendre = "|cff66ccffAttendre|r", Garder = "|cff66ccffGarder|r" }
local HOLD_ACTION = "|cff66ccffGarder (banque)|r" -- objet fabriqué qui se vendrait à perte aujourd'hui
local BAG_RANK = { HV = 6, PNJ = 5, Fabriquer = 4, Tester = 3, Attendre = 2, Garder = 1 }
local SELLS = { yes = "|cff40ff40oui|r", slow = "|cffffd100lent|r", no = "|cffff5050non|r", unknown = "|cff808080?|r" }

-- Une ligne de « Mes objets » : combien vendre maintenant, à quel prix, ce que tu touches. Pour ce que
-- tu as acheté ou fabriqué (relevés), le prix de revient et le gain ou la perte s'ajoutent à la raison.
function UI.BagRow(e)
  local d = e.d
  if e.action == "HV" or e.action == "Tester" then
    e.qtyNow, e.priceNow = d.qty, d.post
    -- ce que tu touches : le net de Decide (commission et dépôts perdus déduits), pas le prix brut
    e.cashNow = (d.ahNet or d.unit or 0) * d.qty
  elseif e.action == "PNJ" then
    e.qtyNow, e.priceNow, e.cashNow = e.count, e.vendor, e.vendor * e.count
  elseif e.action == "Fabriquer" then
    e.qtyNow, e.priceNow = d.qty, d.craft.post
  else
    e.qtyNow = 0
    if d.hold then e.priceNow = d.holdAt end -- garder en banque : le prix à partir duquel vendre
  end
  e.sells = d.sells.v
  e.plain = ns.Decide.Why(d)
  if e.action == "Fabriquer" then e.plain = ns.Decide.Line(d) .. " · " .. e.plain end
  -- ce qui manque dans tes sacs pour agir maintenant est à aller chercher en banque
  local fetch = math.min(e.bank or 0, (e.qtyNow or 0) - (e.bags or 0))
  if e.where == "banque" and e.qtyNow > 0 then
    e.plain = "prends-le en banque · " .. e.plain
  elseif fetch > 0 then
    e.plain = ("prends-en %d en banque · "):format(fetch) .. e.plain
  end
  local c = d.basis
  if c and c.known > 0 and d.unit then
    e.paid = c.knownUnit
    local n = math.min(c.known, e.count)
    -- même valeur que le stock du Bilan (Tracker) : Decide.RawValue, au prix habituel si celui du jour est douteux
    e.gain = ((e.id and ns.Decide.RawValue(e.id)) or d.unit) * n - c.knownUnit * n
    e.plain = ("prix de revient %s : %s%s · "):format(ns.Decide.UnitCostText(c), signed(e.gain),
      d.suspect and " au prix habituel" or "") .. e.plain
  end
  e.rank = (BAG_RANK[e.action] or 0) * 1e10 + (e.cashNow or e.value or 0)
  return e
end

function UI.BagRows()
  local out = ns.Bags.Advice()
  for _, e in ipairs(out) do UI.BagRow(e) end
  return out
end

function UI.BagTotals(rows)
  local t = { ah = 0, ahGold = 0, npc = 0, npcGold = 0, craft = 0, test = 0, hold = 0 }
  for _, e in ipairs(rows) do
    if e.action == "HV" then t.ah, t.ahGold = t.ah + 1, t.ahGold + (e.cashNow or 0)
    elseif e.action == "PNJ" then t.npc, t.npcGold = t.npc + 1, t.npcGold + (e.cashNow or 0)
    elseif e.action == "Fabriquer" then t.craft = t.craft + 1
    elseif e.action == "Tester" then t.test = t.test + 1
    else t.hold = t.hold + 1 end
  end
  return t
end

local DIFF = { optimal = "|cffff8040orange|r", medium = "|cffffff00jaune|r", easy = "|cff40c040vert|r",
               trivial = "|cff808080gris|r" }


-- Message affiché à la place d'un tableau vide : pourquoi il est vide et quoi faire
local EMPTY = {
  advice = "Rien à conseiller pour l'instant : ouvre tes sacs et ta banque, scanne l'HV, et ouvre une fois chaque fenêtre de métier.",
  auctions = "Aucune enchère en cours vue : ta liste d'enchères est relue à chaque visite à l'HV.",
  review = "Aucune vente ni expiration dans tes courriers des 30 derniers jours : passe à la boîte aux lettres après tes ventes.",
  farmwhat = "Aucune ressource rentable prouvée : il faut des scans de l'HV (12 h de scans 0.9 pour « prouvé »).",
  market ="Aucun objet ne correspond. Essaie « Volume : tous » ou une autre catégorie.",
  flip = "Aucune occasion de flip dans le dernier scan. Rescanne un peu plus tard.",
  craft = "Aucune recette connue : ouvre une fois la fenêtre de chacun de tes métiers.",
  level = "Aucune recette connue : ouvre une fois la fenêtre de chacun de tes métiers.",
  bags = "Rien dans tes sacs pour l'instant : ouvre-les une fois (et ta banque) pour les relire.",
  ledger = "Aucun achat ni vente suivi : tes achats à l'HV sont relevés dès maintenant, tes ventes à ta boîte aux lettres.",
  journal = "Aucun achat ni vente depuis 30 jours. Tes achats sont relevés à l'HV, tes ventes à ta boîte aux lettres.",
  vendor = "Aucun achat PNJ rentable. Les marchands que tu visites sont retenus automatiquement.",
  snipe = "Aucune enchère sous le prix de rachat PNJ dans le dernier scan.",
  positions = "Aucun flip suivi. Achète depuis la vue « Flip HV » de l'onglet Marché : chaque achat d'un objet conseillé est noté ici.",
  farm = "Aucune session de farm : tape /ahl farm start avant de farmer, puis /ahl farm stop.",
}
local NO_SCAN = "Pas encore de scan sur ce royaume : ouvre l'HV et clique « Scanner l'HV »."
local NEEDS_SCAN = { market = true, flip = true, snipe = true, vendor = true, craft = true, level = true, farmwhat = true }
-- Onglets qui conseillent un achat : vides sur un scan périmé (Analysis.Stale), avec ce message
local BUYS = { flip = true, snipe = true, vendor = true }
local function staleText()
  local _, age = ns.Analysis.Stale()
  return ("Dernier scan vieux de %.0f h : les enchères bradées qu'il montrait sont sûrement parties, aucun achat n'est conseillé. Rescanne l'HV."):format(age or 0)
end

local function share(v) return v and ("%.0f%%"):format(v * 100) or "|cff808080—|r" end

local function itemLabel(id, s)
  local meta = AHLedgerDB.items[id]
  local name = (s and s.name) or (meta and meta.n) or ("#" .. tostring(id))
  local q = (s and s.quality) or (meta and meta.q)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c and c.hex then return c.hex .. name .. "|r" end
  return name
end

local function num(v, fmt) return v and (fmt or "%.0f"):format(v) or "?" end

-------------------------------------------------------------------------------
-- Bilan : une seule définition de l'or gagné, partout (bandeau, vues, journal)
-------------------------------------------------------------------------------
UI.period = 30
local PERIODS = { 30, 7, 0 } -- 0 = aujourd'hui (depuis minuit)

-- Période d'une vue du Bilan : jours, début (heure du jeu) et libellé. « Ce qui marche » lit 30 j de
-- courriers (Ledger) : sa période est fixe.
function UI.PeriodArgs(mode)
  local p = mode == "review" and 30 or UI.period
  if p == 0 then
    local d = date("*t")
    if type(d) == "table" then
      d.hour, d.min, d.sec = 0, 0, 0
      return 1, time(d), "aujourd'hui"
    end
    return 1, nil, "24 h"
  end
  return p, nil, p .. " j"
end

local function bilanData(mode)
  local days, from, label = UI.PeriodArgs(mode)
  local journal, list, tot, items = ns.Tracker.Compute(days, from)
  return journal, list, tot, items or {}, label
end

-- La ligne d'aide du Bilan : où part l'or et d'où il vient (l'objet le plus perdant, le plus gagnant)
local function bilanHelp(mode)
  local _, _, _, items, label = bilanData(mode)
  local worst, best
  for _, it in pairs(items) do
    if it.real < -0.5 and (not worst or it.real < worst.real) then worst = it end
    if it.real > 0.5 and (not best or it.real > best.real) then best = it end
  end
  local function nameOf(it) return it.id and itemLabel(it.id) or (it.name or "?") end
  local parts = {}
  if worst then
    local why = worst.lostDep >= -worst.real / 2 and "surtout des dépôts perdus" or "revendu moins cher que payé"
    parts[#parts + 1] = ("Plus grosse perte : %s %s (%s)"):format(nameOf(worst), signed(worst.real, true), why)
  end
  if best then parts[#parts + 1] = ("Meilleur gain : %s %s"):format(nameOf(best), signed(best.real, true)) end
  if #parts == 0 then return ("Aucune vente ni expiration sur %s."):format(label) end
  return table.concat(parts, " · ")
end

local BILAN_LONG = "Bilan réel = l'or vraiment gagné : ventes de farm (objets que tu n'as pas achetés : tout est gain) + revente et artisanat (vente nette − prix de revient, le plus ancien achat d'abord ; achats à l'HV et chez le marchand, fabrications relevées à ton clic) − dépôts perdus (enchères expirées). Un achat ne compte pas tout de suite : son coût est déduit quand tu revends, ou passe à l'objet que tu fabriques avec. Stock latent = ce que vaut au marché ce que tu as acheté ou fabriqué et pas encore vendu, moins son prix de revient : pas encore encaissé. Survole un en-tête de colonne ou une case du bandeau pour sa définition."

-- Bandeau du Bilan : farm + achat-revente − dépôts (+ stock latent) = bilan réel
local BAND = {
  { "Ventes de farm", "Ce que t'ont rapporté (commission déduite) les objets vendus que tu n'avais pas achetés à l'HV : loot, dépeçage, artisanat. Tout est gain." },
  { "Revente et artisanat", "Pour ce que tu as acheté (HV ou marchand) puis revendu : vente nette − prix payé (le plus ancien achat d'abord). Pour ce que tu as fabriqué : vente nette − prix de revient (tes composants achetés au prix payé, les autres à leur valeur brute, qui compte en farm). Un coût n'est compté qu'à la vente." },
  { "Dépôts perdus", "Le dépôt de chaque enchère expirée (estimé d'après le prix PNJ de l'objet). C'est de l'or perdu : moins de mises en vente, ou moins chères, le réduisent." },
  { "Stock (latent)", "Ce que tu as acheté à l'HV ou fabriqué, pas encore vendu : sa valeur si tu le vendais maintenant (net), moins son prix de revient. Pas encore encaissé : il ne compte pas dans le bilan réel. Les achats au marchand (fournitures) n'y sont pas." },
  { "Bilan réel", "Ventes de farm + revente et artisanat − dépôts perdus : l'or vraiment gagné sur la période. « Avec le stock » ajoute le stock latent, si tu vendais tout maintenant au prix du marché." },
}

function UI.FillBand(mode)
  local _, _, t, _, label = bilanData(mode)
  local b = UI.bandBoxes
  b[1].value:SetText(signed(t.farm, true)); b[1].sub:SetText("sans coût d'achat")
  b[2].value:SetText(signed(t.gain + t.craft, true)); b[2].sub:SetText(("%d gagnante%s · %d perdante%s%s"):format(
    t.wins, t.wins > 1 and "s" or "", t.losses, t.losses > 1 and "s" or "",
    math.abs(t.craft) >= 0.5 and (" · artisanat " .. signed(t.craft)) or ""))
  b[3].value:SetText(signed(-t.lostDep, true)); b[3].sub:SetText(("%d expiration%s"):format(t.expired, t.expired > 1 and "s" or ""))
  b[4].value:SetText(signed(t.unrealized)); b[4].sub:SetText(("revient %s · vaut %s"):format(ns.money(t.stockCost), ns.money(t.stockValue)))
  b[5].label:SetText("Bilan réel · " .. label)
  b[5].value:SetText(signed(t.real, true)); b[5].sub:SetText("avec le stock : " .. signed(t.withStock))
end

-- Définition de chaque colonne, au survol de son en-tête (« mode.Titre » d'abord, puis « Titre »)
local COL_HELP = {
  ["Qté"] = "Quantité concernée.",
  ["Prix/u"] = "Prix à l'unité.",
  ["advice.Gain"] = "L'or que te rapporte ce conseil, commission et dépôt déduits ; /j = par jour ; /pt = par point de compétence.",
  ["Sûr ?"] = "Niveau de preuve : prouvé ou certain = vu dans tes ventes ou sur plusieurs jours de scans ; à confirmer = anciens scans ; à tester = pas encore de preuve ; estimé = calcul.",
  ["Pourquoi"] = "La raison du conseil, puis ses preuves et leur source.",
  ["À faire"] = "Le geste à faire.",
  ["Que faire"] = "Le geste à faire avec cet objet.",
  ["Tu touches"] = "L'or reçu si tu fais ce geste maintenant : commission déduite, et dépôts perdus sur les mises en vente qui expirent (en moyenne).",
  ["Se vend"] = "Le marché achète-t-il cet objet ? oui, lent, non, ? = pas encore de preuve.",
  ["auctions.Conseil"] = "Que faire de cette enchère.",
  ["Ton prix/u"] = "Ton prix de mise en vente, à l'unité.",
  ["Moins chère/u"] = "L'enchère la moins chère d'un autre vendeur au dernier scan.",
  ["Remettre à/u"] = "Le prix conseillé si tu la remets en vente.",
  ["Expire"] = "Temps restant avant l'expiration.",
  ["Verdict"] = "Ça marche : la plupart de tes mises en vente partent. Prix trop haut : ça se vend, mais tes enchères expirent. Ne marche pas : 0 vendu et le marché n'en achète pas. Trop tôt : pas assez de données. Flip gagnant ou perdant : achat-revente. En stock : acheté, pas encore revendu.",
  ["Vendus"] = "Unités vendues (tes courriers d'HV des 30 derniers jours).",
  ["Expirés"] = "Unités revenues par courrier sans avoir été vendues.",
  ["Partent"] = "Part de tes mises en vente vendues avant d'expirer.",
  ["Prix moy./u"] = "Prix de vente moyen à l'unité.",
  ["Bilan réel"] = "L'or vraiment gagné sur cet objet : ventes de farm + gain des reventes − dépôts perdus.",
  ["Stock latent"] = "Ce que vaut au marché ce que tu as acheté et pas encore vendu, moins ce que tu l'as payé. Pas encore encaissé.",
  ["review.Conseil"] = "Ce qu'il faut continuer ou changer.",
  ["Achetés"] = "Unités achetées à l'HV sur la période (≈ : quantité d'un ancien courrier, estimée).",
  ["Payé moy./u"] = "Prix moyen payé à l'unité.",
  ["Revendus"] = "Unités achetées puis revendues. En gris : unités vendues sans les avoir achetées (farm).",
  ["Vendu net/u"] = "Prix de vente moyen à l'unité, commission déduite.",
  ["Stock"] = "Unités achetées que tu as encore (sacs, banque, enchères en cours).",
  ["Stock vaut"] = "Ce qu'elles te rapporteraient vendues maintenant, juste sous l'enchère la moins chère (net). ? = pas de prix : comptées au prix payé.",
  ["Avec stock"] = "Bilan réel + stock latent : ce que tu aurais gagné en vendant tout ton stock maintenant.",
  ["Date"] = "Trie dans l'ordre où c'est arrivé. En jaune : le bilan de chaque journée.",
  ["journal.Total"] = "Montant de la ligne : payé (achat) ou reçu commission déduite (vente).",
  ["Effet"] = "Ce que la ligne change à ton bilan réel. Un achat ne change rien tout de suite : son coût est déduit quand tu revends.",
  ["Bilan cumulé"] = "Ton bilan réel ligne après ligne, depuis le début de la période (farm compris). La ligne la plus récente = où tu en es maintenant. Une ligne regroupée porte le cumul de sa dernière opération.",
  ["journal.Note"] = "D'où vient la ligne.",
  ["Source"] = "D'où vient la ressource ; en vert : ce que tu récoltes toi-même.",
  ["Net/u"] = "Ce que tu touches par unité vendue à l'HV, commission et dépôt déduits.",
  ["Ventes/j"] = "Ventes sûres par jour sur le marché (~ : anciens scans, surestimé).",
  ["Ta part/j"] = "Unités que tu peux vendre par jour sans faire baisser le prix (25 % des ventes sûres).",
  ["Or/j max"] = "Net/u × ta part par jour.",
  ["Achat min/u"] = "L'enchère la moins chère au dernier scan.",
  ["Tend./j"] = "Évolution du prix par jour.",
  ["Stock (j)"] = "Jours qu'il faudrait au marché pour écouler les enchères en cours.",
  ["Écoulé"] = "Part des enchères vendues avant la fin de leur durée.",
  ["Or/jour"] = "Net × ventes sûres par jour : l'or que cet objet peut te rapporter par jour.",
  ["Signaux"] = "Indices repérés sur cet objet.",
  ["Acheter jusqu'à/u"] = "Prix d'achat maximum pour que le flip reste rentable.",
  ["Coût total"] = "L'or à engager pour ce flip.",
  ["Revente/u"] = "Prix de revente visé, à l'unité.",
  ["Bénéfice"] = "Gain net, commission et dépôt déduits (~ : espéré, pas sûr).",
  ["ROI"] = "Bénéfice ÷ coût.",
  ["Délai (j)"] = "Jours estimés pour revendre.",
  ["Revendre"] = "Quand revendre.",
  ["positions.Reste"] = "Unités restantes / achetées.",
  ["Payé/u"] = "Prix payé à l'unité.",
  ["Objectif/u"] = "Prix de revente visé au moment de l'achat.",
  ["Vendre à/u"] = "Juste sous l'enchère la moins chère qui n'est pas à toi.",
  ["positions.Gain"] = "Gain réalisé, ou ~ estimé si tu vendais maintenant.",
  ["Âge (j)"] = "Jours depuis l'achat / délai prévu pour revendre.",
  ["positions.Conseil"] = "Que faire de ce flip maintenant.",
  ["craft.Coût"] = "Ce que te coûtent les composants : les tiens (ou ceux que tu récoltes) à leur valeur brute, les autres au moins cher entre PNJ et HV.",
  ["craft.Brut"] = "Ce que rapporteraient les composants vendus bruts (le meilleur entre PNJ et HV nette, s'ils se vendent).",
  ["craft.Fabriqué"] = "Ce que rapporte l'objet fabriqué : HV nette s'il s'y vend vraiment, sinon PNJ.",
  ["craft.Bénéfice"] = "Fabriqué − le plus haut entre Brut et Coût : ce que la fabrication rapporte de plus que vendre les composants tels quels (ou ne pas les acheter).",
  ["craft.Conseil"] = "Fabriquer : l'objet fabriqué bat le plus haut entre Brut et Coût d'au moins 15 % et se vend. Marge faible : gagnant, mais moins de 15 %. Vendre brut : tes composants rapportent plus vendus tels quels.",
  ["Or/j"] = "Bénéfice × ta part des ventes sûres par jour.",
  ["Vendre dès"] = "Prix de mise en vente à partir duquel c'est rentable à l'HV (commission et dépôts perdus compris), ou PNJ.",
  ["journal.Quoi"] = "Achat, Vente (d'un objet que tu avais acheté), Vente farm (objet que tu n'avais pas acheté : tout est gain) ou Expiré (dépôt perdu).",
  ["Métier"] = "Le métier de la recette.",
  ["Revente"] = "Ce que rapporte l'objet fabriqué.",
  ["Composants"] = "Coût des composants, au moins cher entre PNJ et HV.",
  ["Achat PNJ/u"] = "Prix chez le marchand, à l'unité.",
  ["Achat/u"] = "Prix de l'enchère, à l'unité.",
  ["Achat total"] = "Prix de toute l'enchère.",
  ["Vendeur"] = "Où acheter.",
  ["snipe.Vendeur"] = "Le joueur qui a mis l'enchère en vente.",
  ["Heures"] = "Durée totale de tes sessions dans cette zone.",
  ["Objets /h"] = "Valeur du loot ramassé par heure, aux prix actuels.",
  ["Or brut /h"] = "Or ramassé sur les monstres par heure.",
  ["Total /h"] = "Loot + or brut, par heure.",
  ["Niveau"] = "Couleur de la recette : orange ou jaune = gain de compétence.",
  ["Chance"] = "Chance de gagner un point en fabriquant.",
  ["Coût / point"] = "(Composants − revente) ÷ chance : ce que coûte un point de compétence.",
  ["Recette à acheter"] = "Prix de la recette, si tu ne l'as pas encore.",
  ["PNJ/u"] = "Prix de rachat du marchand, à l'unité.",
  ["Marge/u"] = "Revente nette − achat, à l'unité.",
  ["Vendus/j"] = "Ventes par jour sur le marché.",
}
UI.COL_HELP = COL_HELP

local MODES = {
  advice = {
    title = "Aujourd'hui",
    view = "Conseils",
    sort = "rank",
    help = function() return ns.Advisor.Headline() end,
    hint = "Clic : l'objet à l'HV (si elle est ouverte) ou l'onglet du détail · clic droit : l'onglet du détail",
    cols = {
      { "À faire", 92, function(e)
          if e.kind == "relist" and e.verbText then return "|cffff8040" .. e.verbText .. "|r" end
          return ADV_VERB[e.kind] or e.kind
        end, "rank" },
      { "Quoi", 190, function(e) return e.label or itemLabel(e.id, e.s) end, "name" },
      { "Qté", 36, function(e) return e.qty and e.kind ~= "level" and tostring(e.qty) or "-" end, "qty", "RIGHT" },
      { "Prix/u", 70, function(e) return e.price and ns.money(e.price) or "-" end, "price", "RIGHT" },
      { "Gain", 84, function(e)
          if e.kind == "level" then
            return e.gold >= 0 and ("|cff40ff40+%s/pt|r"):format(ns.money(e.gold)) or ("|cffff9040-%s/pt|r"):format(ns.money(-e.gold))
          end
          return "|cffffffff+" .. ns.money(e.gold or 0) .. (e.perDay and "/j" or "") .. "|r"
        end, "gold", "RIGHT" },
      { "Sûr ?", 72, function(e) return CONF[e.conf] or e.conf or "-" end, "conf" },
      { "Pourquoi", 240, function(e) return e.why or "" end, "why" },
    },
    rows = function() return ns.Advisor.Actions() end,
    onClick = function(e, button)
      if button ~= "RightButton" and e.id and ADV_AT_AH[e.kind] and ns.isAHOpen() then
        UI.ShowItem(e.id)
      elseif e.mode then
        UI.SetMode(e.mode)
      end
    end,
  },
  auctions = {
    title = "Mes enchères",
    view = "Mes enchères",
    sort = "rank",
    help = function()
      local rows, n = ns.Advisor.Auctions(), { relist = 0, relistlater = 0, keep = 0, wait = 0, npc = 0, sold = 0 }
      local gold = 0
      for _, e in ipairs(rows) do
        n[e.verdict] = (n[e.verdict] or 0) + 1
        if e.verdict == "sold" then gold = gold + (e.gold or 0) end
      end
      local _, t = ns.Auctions.Summary()
      return ("%d à reprendre maintenant, %d à remettre à leur retour, %d à laisser, %d à laisser expirer pour le PNJ · courrier : %s. Comparé au dernier scan, tes propres enchères mises à part (liste relue %s). Annuler fait perdre le dépôt."):format(
        n.relist, n.relistlater, n.keep + n.wait, n.npc, ns.money(gold), t and date("%d/%m %H:%M", t) or "jamais")
    end,
    hint = "Clic : l'objet à l'HV · Maj-clic : lien",
    cols = {
      { "Objet", 180, function(e) return itemLabel(e.id, e.s) .. (" |cffccccccx%d|r"):format(e.qty) end, "name" },
      { "Conseil", 108, function(e) return AUC_VERDICT[e.verdict] or e.verdict end, "rank" },
      { "Ton prix/u", 70, function(e) return e.unit and ns.money(e.unit) or "-" end, "unit", "RIGHT" },
      { "Moins chère/u", 78, function(e) return e.floor and ns.money(e.floor) or "-" end, "floor", "RIGHT" },
      { "Remettre à/u", 76, function(e)
          return (e.verdict == "relist" or e.verdict == "relistlater") and ("|cffffffff" .. ns.money(e.post) .. "|r") or "-"
        end, "post", "RIGHT" },
      { "Expire", 46, function(e) return ns.Auctions.LeftText(e.left) end, "left", "RIGHT" },
      { "Pourquoi", 228, function(e) return e.why or "" end, "why" },
    },
    rows = function()
      local out = ns.Advisor.Auctions()
      for _, e in ipairs(out) do e.rank = (AUC_RANK[e.verdict] or 0) * 1e10 + (e.gold or 0) end
      return out
    end,
    onClick = function(e) UI.ShowItem(e.id) end,
  },
  review = {
    title = "Bilan",
    view = "Ce qui marche",
    sort = "rank",
    band = true,
    help = function()
      local t = ns.Advisor.ReviewTotals()
      return ("%d qui marchent · %d à revoir · %d à arrêter · %d trop tôt · "):format(
        t.works + t.gain, t.price + t.loss, t.stop, t.early) .. bilanHelp("review")
    end,
    helpLong = BILAN_LONG .. " Ce qui marche : chaque objet que tu as mis en vente sur 30 j, et ce qu'il faut continuer ou changer.",
    cols = {
      { "Objet", 190, function(e) return e.id and itemLabel(e.id) or (e.name or "?") end, "name" },
      { "Verdict", 92, function(e) return REVIEW[e.verdict] or e.verdict end, "rank" },
      { "Vendus", 44, function(e) return tostring(e.sold) end, "sold", "RIGHT" },
      { "Partent", 46, function(e) return share(e.st) end, "st", "RIGHT" },
      -- mêmes définitions que le bandeau : l'or gagné, puis à part ce que vaut le stock pas encore vendu
      { "Bilan réel", 76, function(e) return signed(e.real, true) end, "real", "RIGHT" },
      { "Stock latent", 70, function(e) return e.latent and signed(e.latent) or "-" end, "latent", "RIGHT" },
      { "Conseil", 218, function(e) return e.advice or "" end, "advice" },
    },
    more = {
      { "Expirés", function(e) return tostring(e.expired) end },
      { "Prix moy./u", function(e) return e.avgSale and ns.money(e.avgSale) end },
    },
    rows = function()
      local out = ns.Advisor.Review()
      local _, _, _, items = bilanData("review")
      for _, e in ipairs(out) do
        local it = items[e.id or e.name or "?"]
        e.real = it and it.real or e.net
        e.latent = it and it.left > 0 and it.unrealized or nil
        e.rank = (REVIEW_RANK[e.verdict] or 0) * 1e10 + (e.impact or 0)
      end
      return out
    end,
  },
  farmwhat = {
    title = "Farm",
    view = "Que farmer",
    sort = "rank",
    help = "Les ressources qui se vendent, et l'or que le marché t'en prend par jour : ta part = 25 % des ventes sûres, au-delà ta pile attend. Prouvé d'abord, puis ce que tu récoltes ou utilises. « à confirmer » : débit d'anciens scans, surestimé. Tes sessions réelles (/ahl farm start) : onglet Opérations, vue Mes sessions.",
    cols = {
      { "Ressource", 180, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Source", 104, function(e) return (e.mine and "|cff40ff40" or "") .. e.source .. (e.mine and "|r" or "") end, "source" },
      { "Net/u", 66, function(e) return ns.money(e.net) end, "net", "RIGHT" },
      { "Ventes/j", 54, function(e) return (e.s and e.s.measured and "" or "~") .. num(e.rate, "%.0f") end, "rate", "RIGHT" },
      { "Or/j max", 76, function(e) return "|cffffffff" .. ns.money(e.daily) .. "|r" end, "daily", "RIGHT" },
      { "Sûr ?", 72, function(e) return CONF[e.conf] or e.conf end, "conf" },
      { "Pourquoi", 180, function(e) return e.why or "" end, "why" },
    },
    more = { { "Ta part/j", function(e) return num(e.share, "%.0f") end } },
    rows = function() return ns.Advisor.FarmTargets() end,
  },
  market = {
    title = "Marché",
    view = "Signaux",
    sort = "score",
    help = "Or/jour = net × ventes sûres par jour (enchères parties bien avant la fin de leur durée). « ~ » devant les ventes et « — » en écoulé : pas encore 12 h de scans 0.9, chiffre d'anciens scans qui compte aussi les retraits (surestimé). Survole un objet pour la décision.",
    cols = {
      { "Objet", 200, function(e) return itemLabel(e.id, e) end, "name" },
      { "Prix/u", 78, function(e) return ns.money(e.price) end, "price", "RIGHT" },
      { "Tend./j", 52, function(e) return ns.pct(e.trend) end, "trend", "RIGHT" },
      { "Ventes/j", 52, function(e) return (e.measured and "" or "~") .. num(e.surePerDay, "%.1f") end, "surePerDay", "RIGHT" },
      { "Écoulé", 44, function(e) return share(e.stReliable and e.sellThrough or nil) end, "sellThrough", "RIGHT" },
      { "Or/jour", 82, function(e) return ns.money(e.gpd) end, "gpd", "RIGHT" },
      { "Signaux", 140, function(e) return table.concat(e.signals, " · ") end, "score" },
    },
    more = {
      { "Achat min/u", function(e) return ns.money(e.minNow) end },
      { "Stock (j)", function(e) return num(e.stockDays, "%.1f") end },
    },
    rows = function()
      local out, filter = {}, CATS[UI.cat][2]
      local rel = filter == "prof" and ns.Prof.Related() or nil
      for _, s in ipairs(ns.Analysis.All().list) do
        local okCat = not filter or (rel and rel[s.id]) or (not rel and s.class and filter[s.class])
        local okLiq = not UI.liquidOnly or (s.surePerDay and s.surePerDay >= 1)
        if okCat and okLiq then out[#out + 1] = s end
      end
      return out
    end,
  },
  flip = {
    title = "Flip HV",
    view = "Flip HV",
    sort = "profit",
    help = "Achète jusqu'au prix indiqué. « Tout de suite » : remets en vente juste sous la prochaine enchère. « Stocker » : tout le marché est bas, garde-les jusqu'à ce que le prix remonte (délai et chance appris des creux passés ; bénéfice espéré). Clic = rechercher l'objet.",
    cols = {
      { "Objet", 190, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Qté", 45, function(e) return tostring(e.qty) end, "qty", "RIGHT" },
      { "Acheter jusqu'à/u", 95, function(e) return ns.money(e.maxBuy) end, "maxBuy", "RIGHT" },
      { "Revente/u", 78, function(e) return ns.money(e.resale) end, "resale", "RIGHT" },
      -- à stocker : bénéfice espéré (« ~ »), pondéré par la chance que le prix remonte
      { "Bénéfice", 82, function(e) return "|cff40ff40" .. (e.kind == "stock" and "~" or "") .. ns.money(e.profit) .. "|r" end, "profit", "RIGHT" },
      { "Délai (j)", 52, function(e) return ("%.1f"):format(e.days) end, "days", "RIGHT" },
      { "Revendre", 130, function(e)
          local w = ns.Analysis.FlipWhen(e)
          if e.kind ~= "stock" then return "|cff40ff40" .. w .. "|r" end
          return (e.known and "|cff66ccff" or "|cffff8040") .. w .. "|r"
        end, "kind" },
    },
    more = {
      { "Coût total", function(e) return ns.money(e.cost) end },
      { "ROI", function(e) return ("%.0f%%"):format(e.roi * 100) end },
    },
    rows = function()
      local out = ns.Analysis.Flips()
      if ns.Positions then ns.Positions.Remember(out) end -- ce que tu as vu, pour « Mes flips »
      return out
    end,
    onClick = function(e)
      if e.kind == "stock" then
        ns.Snipe.Search(e, ("Flip à stocker : %s — achète jusqu'à %s/u (%d u.), garde-les et revends à %s/u quand le prix remonte (%s)."):format(
          e.name or "?", ns.money(e.maxBuy), e.qty, ns.money(e.resale), ns.Analysis.FlipWhen(e)))
      else
        ns.Snipe.Search(e, ("Flip : %s — achète jusqu'à %s/u (%d u.), revends tout de suite à %s/u."):format(
          e.name or "?", ns.money(e.maxBuy), e.qty, ns.money(e.resale)))
      end
    end,
  },
  positions = {
    title = "Mes flips",
    view = "Mes flips",
    sort = "rank",
    help = function()
      local t = ns.Positions.Totals()
      return ("Tes achats faits sur un conseil de « Flip HV » (relevés quand le jeu confirme l'achat). %d ouvert(s), %s engagés · gain réalisé %s · %d à vendre maintenant. Vendre à/u = juste sous l'enchère la moins chère qui n'est pas à toi. Clic : chercher l'objet · clic droit : ne plus suivre."):format(
        t.open, ns.money(t.invested), ns.money(t.realized), t.toSell)
    end,
    cols = {
      { "Objet", 180, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Reste", 50, function(e) return e.verdict == "done" and ("%d/%d"):format(e.sold, e.bought) or ("%d/%d"):format(math.max(e.left, 0), e.bought) end, "left", "RIGHT" },
      { "Payé/u", 72, function(e) return ns.money(e.unit) end, "unit", "RIGHT" },
      { "Vendre à/u", 72, function(e) return e.verdict == "done" and "-" or ns.money(e.sellAt) end, "sellAt", "RIGHT" },
      { "Gain", 78, function(e)
          if not e.gain then return "-" end
          return (e.gain >= 0 and "|cff40ff40" or "|cffff5050") .. (e.verdict == "done" and "" or "~") .. ns.money(e.gain) .. "|r"
        end, "gain", "RIGHT" },
      { "Conseil", 100, function(e) return POS_VERDICT[e.verdict] or e.verdict end, "rank" },
      { "Pourquoi", 92, function(e) return e.why or "" end, "why" },
    },
    more = {
      { "Objectif/u", function(e) return ns.money(e.p.reco.resale) end },
      { "Âge (j)", function(e) return ("%.1f / %.1f prévus"):format(e.age, e.expect) end },
    },
    rows = function()
      local out = ns.Positions.Rows()
      for _, e in ipairs(out) do e.rank = POS_RANK[e.verdict] or 0 end
      return out
    end,
    onClick = function(e, button)
      if button == "RightButton" then
        if e.verdict ~= "done" then
          ns.Positions.Close(e.p)
          ns.print((e.name or "?") .. " : flip refermé, il n'est plus suivi.")
        end
        return
      end
      if e.action and e.action > 0 then
        ns.Snipe.Search(e, ("Vends %d × %s à %s/u (gain ~%s)."):format(e.action, e.name or "?", ns.money(e.sellAt), ns.money(e.gainU * e.action)))
      else
        UI.ShowItem(e.id)
      end
    end,
  },
  craft = {
    title = "Artisanat",
    view = "Rentabilité",
    sort = "daily",
    help = "Matière brute ou fabriqué : pour chaque recette (ouvre chaque fenêtre de métier une fois), Brut = ce que rapportent ses composants vendus bruts ; Fabriqué = ce que rapporte l'objet fabriqué (HV nette s'il s'y vend vraiment, sinon PNJ). Coût = tes composants à leur valeur brute, les autres à leur prix d'achat. Bénéfice = Fabriqué − le plus haut entre Brut et Coût. Fabriquer seulement si le bénéfice dépasse 15 % de ce plus haut et que l'objet se vend. Or/j = bénéfice × ta part des ventes sûres (25 %), ou 20 fabrications/j au PNJ ; Vendre dès = prix de mise en vente rentable à l'HV (commission et dépôts perdus compris), ou PNJ. Niveau et gain de compétence : vue Montée.",
    cols = {
      { "Recette", 200, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Brut", 70, function(e) return ns.money(e.raw) end, "raw", "RIGHT" },
      { "Coût", 72, function(e) return e.cost and ns.money(e.cost) or ("|cff808080%d prix ?|r"):format(e.missing) end, "cost", "RIGHT" },
      { "Fabriqué", 72, function(e) return ns.money(e.value) end, "value", "RIGHT" },
      { "Bénéfice", 72, function(e) return e.profit and ((e.profit >= 0 and "|cff40ff40" or "|cffff5050") .. ns.money(e.profit) .. "|r") or "-" end, "profit", "RIGHT" },
      { "Conseil", 80, function(e)
          if not e.cost then return "|cff808080prix ?|r" end
          if e.ok then return "|cff40ff40Fabriquer|r" end
          if e.profit > 0 then return "|cffffd100marge faible|r" end
          return e.own and "|cffff5050Vendre brut|r" or "|cffff5050Pas rentable|r"
        end, "okRank" },
      { "Or/j", 56, function(e) return e.daily and ns.money(e.daily) or "-" end, "daily", "RIGHT" },
    },
    more = {
      { "Métier", function(e) return ns.Prof.LABEL[e.prof] or e.prof end },
      { "Vendre dès", function(e)
          if e.sellTo == "HV" and e.minPrice then return ns.money(e.minPrice) end
          return e.sellTo
        end },
    },
    rows = function() return ns.Analysis.Crafts() end,
  },
  level = {
    title = "Montée",
    view = "Montée de métier",
    tab = false, -- vue de l'onglet Artisanat
    sort = "perPoint",
    asc = true,
    help = "Coût d'un point de compétence au niveau actuel : (composants − revente) ÷ chance de gain. Plan complet : /ahl monter cuir 225.",
    cols = {
      { "Recette", 200, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Métier", 62, function(e) return ns.Prof.LABEL[e.prof] or e.prof end, "prof" },
      { "Niveau", 55, function(e) return DIFF[e.diff] or "-" end, "diff" },
      { "Chance", 50, function(e) return ("%.0f%%"):format(e.chance * 100) end, "chance", "RIGHT" },
      { "Composants", 78, function(e) return e.cost and ns.money(e.cost) or "|cff808080prix ?|r" end, "cost", "RIGHT" },
      { "Revente", 78, function(e) return ns.money(e.value) end, "value", "RIGHT" },
      { "Coût / point", 85, function(e) return e.perPoint and ((e.perPoint <= 0 and "|cff40ff40" or "") .. ns.money(e.perPoint) .. (e.perPoint <= 0 and "|r" or "")) or "-" end, "perPoint", "RIGHT" },
    },
    more = { { "Recette à acheter", function(e) return e.learnCost and ns.money(e.learnCost) end } },
    rows = function()
      local out = {}
      for _, prof in ipairs(ns.Plan.CraftProfs()) do
        for _, e in ipairs(ns.Plan.NextPoints(prof)) do out[#out + 1] = e end
      end
      return out
    end,
  },
  bags = {
    title = "Sacs et banque",
    view = "Sacs et banque",
    sort = "rank",
    help = function()
      local t = UI.BagTotals(UI.BagRows())
      return ("À faire : %d à vendre à l'HV (~%s) · %d au PNJ (%s) · %d à fabriquer · %d à tester · %d à garder ou attendre. Pourquoi : la raison, puis ses preuves et leur source (courrier = tes ventes, scans, Auctionator, jeu). Se vend : oui, lent, non, ? = pas encore de preuve."):format(
        t.ah, ns.money(t.ahGold), t.npc, ns.money(t.npcGold), t.craft, t.test, t.hold)
    end,
    cols = {
      { "Objet", 210, function(e)
          local bank = e.where == "banque" and " |cff808080(banque)|r"
            or (e.bank or 0) > 0 and (" |cff808080(%d en banque)|r"):format(e.bank) or ""
          return itemLabel(e.id, e.s) .. (" |cffccccccx%d|r"):format(e.count) .. bank
        end, "name" },
      { "Que faire", 92, function(e) return e.d and e.d.hold and HOLD_ACTION or BAG_ACTION[e.action] or e.action end, "rank" },
      { "Qté", 40, function(e) return e.qtyNow > 0 and tostring(e.qtyNow) or "-" end, "qtyNow", "RIGHT" },
      { "Prix/u", 72, function(e) return e.priceNow and ns.money(e.priceNow) or "-" end, "priceNow", "RIGHT" },
      { "Tu touches", 80, function(e) return e.cashNow and ("|cffffffff" .. ns.money(e.cashNow) .. "|r") or "-" end, "cashNow", "RIGHT" },
      { "Se vend", 52, function(e) return SELLS[e.sells] or "?" end, "sells" },
      { "Pourquoi", 290, function(e) return e.plain or "" end, "why" },
    },
    rows = function() return UI.BagRows() end,
  },
  ledger = {
    title = "Achat-revente",
    view = "Achat-revente",
    sort = "real",
    band = true,
    help = function() return bilanHelp("ledger") end,
    helpLong = BILAN_LONG .. " Achat-revente : chaque objet que tu as acheté (HV, ou marchand puis revendu) ou fabriqué, ce que tu en as revendu, et ce que vaut ce qu'il te reste. Les objets seulement farmés, et les fournitures du marchand, n'y sont pas : la somme des lignes n'est donc pas le bilan réel du bandeau (voir le Journal).",
    cols = {
      { "Objet", 200, function(e)
          return (e.id and itemLabel(e.id) or (e.name or "?")) .. (e.est and " |cffff9900≈|r" or "")
        end, "name" },
      { "Achetés", 50, function(e)
          local n = e.bought + e.boughtPNJ
          return tostring(n) .. (e.crafted > 0 and (" |cffff9900+%d|r"):format(e.crafted) or "")
        end, "bought", "RIGHT" },
      { "Revendus", 60, function(e)
          return tostring(e.soldFromBuys + e.craftSold) .. (e.farmSold > 0 and (" |cff808080+%d|r"):format(e.farmSold) or "")
        end, "soldFromBuys", "RIGHT" },
      { "Bilan réel", 78, function(e) return signed(e.real, true) end, "real", "RIGHT" },
      { "Stock", 42, function(e) return e.left > 0 and tostring(e.left) or "-" end, "left", "RIGHT" },
      { "Stock vaut", 80, function(e)
          if e.left <= 0 then return "-" end
          return ns.money(e.leftValue) .. (e.priced and "" or " |cff808080?|r")
        end, "leftValue", "RIGHT" },
      { "Avec stock", 80, function(e) return signed(e.withStock) end, "withStock", "RIGHT" },
    },
    more = {
      { "Payé moy./u", function(e) return ns.money(e.avgBuy) end },
      { "Vendu net/u", function(e) return ns.money(e.avgSell) end },
    },
    rows = function() local _, list = bilanData("ledger"); return list end,
  },
  journal = {
    title = "Journal",
    view = "Journal",
    tab = false, -- vue de l'onglet Opérations
    sort = "seq",
    band = true,
    help = function() return bilanHelp("journal") end,
    helpLong = BILAN_LONG .. " Journal : chaque achat, vente et expiration, le plus récent en haut ; les lignes du même objet dans la même minute sont regroupées. En jaune, le bilan de chaque journée (seulement en tri par date).",
    cols = {
      { "Date", 70, function(e)
          return e.kind == "day" and date("|cffffd100%d/%m|r", e.t) or date("%d/%m %H:%M", e.t)
        end, "seq" },
      { "Objet", 200, function(e)
          if e.kind == "day" then
            return ("|cffffd100Bilan du jour|r |cff808080(%d opération%s)|r"):format(e.lines, e.lines > 1 and "s" or "")
          end
          local name = e.id and itemLabel(e.id) or (e.n or "?")
          if e.lines > 1 then name = name .. (" |cff808080× %d %s|r"):format(e.lines, JOURNAL_UNIT[e.kind]) end
          return name
        end, "name" },
      { "Quoi", 62, function(e)
          if e.kind == "day" then return "" end
          if e.kind == "sell" and not e.gain and not e.craftGain then return "|cff40ff40Vente farm|r" end
          if e.kind == "buy" and e.src == "PNJ" then return "|cff66ccffAchat PNJ|r" end
          return JOURNAL_KIND[e.kind]
        end, "kind" },
      { "Qté", 36, function(e) return e.kind == "day" and "" or ((e.est and "≈" or "") .. tostring(e.c)) end, "c", "RIGHT" },
      { "Effet", 74, function(e)
          if e.kind == "buy" or e.kind == "craft" then return "|cff808080en stock|r" end
          return signed(e.effect, e.kind == "day")
        end, "effect", "RIGHT" },
      { "Bilan cumulé", 84, function(e) return e.running and signed(e.running, true) or "" end, "running", "RIGHT" },
      { "Note", 90, function(e)
          if e.kind == "day" then return "" end
          if e.kind == "buy" then
            if e.src == "PNJ" then return "chez le marchand" end
            return e.src == "mail" and (e.est and "courrier, qté estimée" or "courrier") or (e.reco and "|cff40ff40conseillé|r" or "hors conseil")
          elseif e.kind == "craft" then
            return ("composants : %s payés, %s à toi"):format(ns.money(e.paid or 0), ns.money(e.own or 0))
          elseif e.kind == "sell" then
            local farmN = e.farmN or 0
            if e.craftGain then return "vente de ta fabrication" .. (farmN > 0 and (" + %d farm"):format(farmN) or "") end
            if e.gain and farmN > 0 then return ("revente + %d farm"):format(farmN) end
            if e.gain then return "revente de ton achat" end
            return "pas acheté : tout est gain"
          end
          return "dépôt perdu (estimé)"
        end, "src" },
    },
    more = {
      { "Prix/u", function(e) return e.kind ~= "exp" and e.kind ~= "day" and ns.money(e.unit) or nil end },
      { "Total", function(e)
          if e.kind == "exp" or e.kind == "day" then return nil end
          return ns.money(e.kind == "sell" and e.net or e.total)
        end },
    },
    rows = function()
      local journal = bilanData("journal")
      local out = ns.Tracker.Journal(journal)
      -- bilan de chaque journée, seulement dans l'ordre des dates (ailleurs il serait mélangé aux lignes)
      if UI.sortKey == "seq" then
        for _, d in ipairs(ns.Tracker.Days(journal)) do out[#out + 1] = d end
      end
      return out
    end,
  },
  vendor = {
    title = "Achat PNJ",
    view = "Achat PNJ",
    sort = "gpd",
    help = function()
      local _, untested = ns.Analysis.VendorFlips()
      return ("Objets achetables chez un marchand déjà visité et revendus à profit à l'HV (commission et dépôts déduits), seulement si des ventes à ce prix ont été vues plusieurs jours, ou par toi. %d autre(s) pas encore prouvé(s), non affiché(s)."):format(untested)
    end,
    cols = {
      { "Objet", 190, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Achat PNJ/u", 85, function(e) return ns.money(e.buy) end, "buy", "RIGHT" },
      { "Revente/u", 85, function(e) return ns.money(e.s.price) end, "price", "RIGHT" },
      { "Marge/u", 85, function(e) return ns.money(e.margin) end, "margin", "RIGHT" },
      { "Vendus/j", 60, function(e) return num(e.perDay) end, "perDay", "RIGHT" },
      { "Or/jour", 90, function(e) return ns.money(e.gpd) end, "gpd", "RIGHT" },
      { "Vendeur", 100, function(e) return (e.npc or "?") .. " (" .. (e.zone or "?") .. ")" end, "zone" },
    },
    more = { { "ROI", function(e) return ("%.0f%%"):format(e.roi * 100) end } },
    rows = function() return (ns.Analysis.VendorFlips()) end,
  },
  snipe = {
    title = "Revente PNJ",
    view = "Revente PNJ",
    sort = "profit",
    help = "Enchères moins chères que le prix de rachat du PNJ (dernier scan). Clic = rechercher l'objet dans « Parcourir » pour l'acheter.",
    cols = {
      { "Objet", 200, function(e) return itemLabel(e.id) end, "name" },
      { "Qté", 35, function(e) return tostring(e.count) end, "count", "RIGHT" },
      { "Achat/u", 80, function(e) return ns.money(e.cost / e.count) end, "unitCost", "RIGHT" },
      { "PNJ/u", 75, function(e) return ns.money(e.value / e.count) end, "unitValue", "RIGHT" },
      { "Bénéfice", 85, function(e) return "|cff40ff40" .. ns.money(e.profit) .. "|r" end, "profit", "RIGHT" },
      { "Type", 60, function(e) return e.kind end, "kind" },
      { "Vendeur", 90, function(e) return e.owner or "?" end, "owner" },
    },
    more = { { "Achat total", function(e) return ns.money(e.cost) end } },
    rows = function()
      local out = {}
      if ns.Analysis.Stale() then return out end
      for _, o in ipairs(ns.realmDB().snipes or {}) do out[#out + 1] = o end
      return out
    end,
    onClick = function(e) ns.Snipe.Search(e) end,
  },
  farm = {
    title = "Sessions de farm",
    view = "Mes sessions",
    sort = "total",
    help = "Tes sessions /ahl farm, valorisées aux prix actuels. Au-delà du volume que le marché absorbe, le loot est compté au prix PNJ.",
    cols = {
      { "Zone", 190, function(e) return e.zone end, "zone" },
      { "Heures", 55, function(e) return ("%.1f"):format(e.hours) end, "hours", "RIGHT" },
      { "Objets /h", 100, function(e) return ns.money(e.itemsPerHour) end, "itemsPerHour", "RIGHT" },
      { "Or brut /h", 100, function(e) return ns.money(e.moneyPerHour) end, "moneyPerHour", "RIGHT" },
      { "Total /h", 100, function(e) return ns.money(e.total) end, "total", "RIGHT" },
      { "Meilleur objet", 200, function(e) return e.best and itemLabel(e.best) or "-" end, "best" },
    },
    rows = function() return ns.Analysis.FarmZones() end,
  },
}

-- Onglets (1.0 phase 5) : la décision d'abord. Aujourd'hui (ce qu'il faut faire), Mon stock (sacs,
-- banque, enchères en cours), Opérations (bilan, ce qui marche, journal, sessions de farm), Artisanat,
-- Marché (signaux, flips, achats et reventes PNJ, que farmer)
local TABS = { "advice", "bags", "review", "craft", "market" }
local TAB_TITLE = { advice = "Aujourd'hui", bags = "Mon stock", review = "Opérations", craft = "Artisanat", market = "Marché" }
-- Onglets à plusieurs vues : le bouton « Vue » passe de l'une à l'autre
local VIEWS = { bags = { "bags", "auctions" }, review = { "review", "ledger", "journal", "farm" },
                craft = { "craft", "level" },
                market = { "market", "flip", "positions", "vendor", "snipe", "farmwhat" } }
local GROUP = {}
for tab, list in pairs(VIEWS) do for _, m in ipairs(list) do GROUP[m] = tab end end
UI.TABS, UI.VIEWS, UI.GROUP, UI.lastView = TABS, VIEWS, GROUP, {}

-- vue suivante (step = 1) ou précédente (-1) de l'onglet du mode
local function stepView(mode, step)
  local list = VIEWS[GROUP[mode]]
  if not list then return mode end
  for i, m in ipairs(list) do
    if m == mode then return list[(i - 1 + step) % #list + 1] end
  end
  return list[1]
end
UI.StepView = stepView

local function sortValue(e, key)
  if key == "name" then
    local meta = AHLedgerDB.items[e.id]
    return (meta and meta.n) or ""
  end
  local v = e[key]
  if v == nil and e.s then v = e.s[key] end
  return v
end

local function sortRows(rows, key, desc)
  table.sort(rows, function(a, b)
    local va, vb = sortValue(a, key), sortValue(b, key)
    if va == vb then return false end
    if va == nil then return false end
    if vb == nil then return true end
    if type(va) ~= type(vb) then va, vb = tostring(va), tostring(vb) end
    if desc then return va > vb else return va < vb end
  end)
end

local function entryItem(e) return e.id or e.best end

local function frameHeight() return 90 + ROWS * ROW_H + 40 + DETAIL_H end

-- Détail d'une ligne : chaque colonne courte puis les chiffres sans colonne (« more ») sur une ligne,
-- et la colonne de texte (Pourquoi, Conseil, Signaux…) en entier en dessous. Les couleurs des
-- cellules sont gardées.
local function plain(v)
  if v == nil then return nil end
  v = tostring(v)
  local bare = v:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  if bare == "" or bare == "-" then return nil end
  return v
end

function UI.DetailText(mode, e)
  local m = MODES[mode]
  if not (m and e) then return "" end
  local cols, facts, long = m.cols, {}, nil
  for i, col in ipairs(cols) do
    local ok, v = pcall(col[3], e)
    v = ok and plain(v) or nil
    if i == 1 then
      facts[#facts + 1] = v and ("|cffffffff" .. v .. "|r") or nil
    elseif i == #cols and (col[5] or "LEFT") == "LEFT" then
      long = v and ("|cffffd100" .. col[1] .. " :|r " .. v) or nil
    elseif v then
      facts[#facts + 1] = "|cff999999" .. col[1] .. "|r " .. v
    end
  end
  for _, x in ipairs(m.more or {}) do
    local ok, v = pcall(x[2], e)
    v = ok and plain(v) or nil
    if v then facts[#facts + 1] = "|cff999999" .. x[1] .. "|r " .. v end
  end
  if m.detail then
    local ok, v = pcall(m.detail, e)
    if ok and plain(v) then long = (long and (long .. "\n") or "") .. v end
  end
  local text = table.concat(facts, "  ·  ")
  if long then text = text .. "\n" .. long end
  return text
end

-- Une ligne est retrouvée d'un rafraîchissement à l'autre par son objet et son type d'action
local function entryKey(e)
  if not e then return nil end
  return tostring(e.id or e.best or e.name or e.label or e.zone or "?") .. ":" ..
    tostring(e.kind or e.verdict or e.action or e.prof or "") .. ":" .. tostring(e.seq or e.t or "")
end

-- remember : la ligne a été survolée, le panneau la garde ; sinon (1re ligne choisie d'office)
-- il suivra le défilement
function UI.ShowDetail(e, remember)
  if not UI.detail then return end
  if remember then UI.detailKey = entryKey(e) end
  UI.detail.text:SetText(e and UI.DetailText(UI.mode, e) or "")
end

function UI.Build()
  if UI.frame then return end
  local Look = ns.Look
  local w = Look.Window("AHLedgerFrame", WIDTH, frameHeight(), "HIGH")
  UI.frame = w
  UI.title = w.titleText
  UI.title:SetText("AHLedger — " .. ns.realmKey())

  -- Tout le contenu est sur un cadre à part, sans coque : il se loge dans la fenêtre d'AHLedger,
  -- dans l'onglet de l'HV du jeu ou dans l'onglet AHLedger de l'HV de Daylight UI.
  local f = CreateFrame("Frame", nil, w)
  UI.content = f
  UI.Dock(w)

  -- Onglets
  local x = 12
  UI.modeButtons = {}
  for _, key in ipairs(TABS) do
    local b = Look.Button(f, TAB_TITLE[key] or MODES[key].title, 120, 22)
    b:SetPoint("TOPLEFT", x, -30)
    script(b, "OnClick", function() UI.SetMode(UI.lastView[key] or key) end)
    UI.modeButtons[key] = b
    x = x + 124
  end

  -- Filtres (onglet Marché)
  UI.catButton = Look.Button(f, "", 140, 22)
  UI.catButton:SetPoint("TOPRIGHT", -134, -54)
  -- clic gauche : catégorie suivante ; clic droit : précédente
  if UI.catButton.RegisterForClicks then UI.catButton:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
  script(UI.catButton, "OnClick", function(_, button)
    local step = button == "RightButton" and -2 or 0
    UI.cat = (UI.cat + step) % #CATS + 1
    UI.offset = 0
    UI.Refresh()
  end)
  script(UI.catButton, "OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Catégorie")
    for i, c in ipairs(CATS) do
      local on = i == UI.cat
      GameTooltip:AddLine((on and "> " or "   ") .. c[1], on and 1 or 0.7, on and 0.82 or 0.7, on and 0 or 0.7)
    end
    GameTooltip:AddLine("Clic : suivante · clic droit : précédente", 0.5, 0.8, 1)
    GameTooltip:Show()
  end)
  script(UI.catButton, "OnLeave", function() GameTooltip:Hide() end)
  UI.liqButton = Look.Button(f, "", 118, 22)
  UI.liqButton:SetPoint("TOPRIGHT", -14, -54)
  script(UI.liqButton, "OnClick", function()
    UI.liquidOnly = not UI.liquidOnly
    UI.offset = 0
    UI.Refresh()
  end)
  script(UI.liqButton, "OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Volume")
    GameTooltip:AddLine("« 1+/jour » cache les objets qui se vendent moins d'une fois par jour : leur prix est peu fiable et ils immobilisent ton or.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  script(UI.liqButton, "OnLeave", function() GameTooltip:Hide() end)

  UI.viewButton = Look.Button(f, "", 180, 22)
  UI.viewButton:SetPoint("TOPRIGHT", -14, -54)
  if UI.viewButton.RegisterForClicks then UI.viewButton:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
  script(UI.viewButton, "OnClick", function(_, button)
    UI.SetMode(stepView(UI.mode, button == "RightButton" and -1 or 1))
  end)
  script(UI.viewButton, "OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Vues de l'onglet")
    for _, m in ipairs(VIEWS[GROUP[UI.mode]] or {}) do
      local on = m == UI.mode
      GameTooltip:AddLine((on and "> " or "   ") .. (MODES[m].view or MODES[m].title), on and 1 or 0.7, on and 0.82 or 0.7, on and 0 or 0.7)
    end
    GameTooltip:AddLine("Clic : suivante · clic droit : précédente", 0.5, 0.8, 1)
    GameTooltip:Show()
  end)
  script(UI.viewButton, "OnLeave", function() GameTooltip:Hide() end)

  -- Période du Bilan : 30 j, 7 j, aujourd'hui
  UI.periodButton = Look.Button(f, "", 116, 22)
  UI.periodButton:SetPoint("TOPRIGHT", UI.viewButton, "TOPLEFT", -6, 0)
  if UI.periodButton.RegisterForClicks then UI.periodButton:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
  script(UI.periodButton, "OnClick", function(_, button)
    local i = 1
    for k, p in ipairs(PERIODS) do if p == UI.period then i = k end end
    i = (i - 1 + (button == "RightButton" and -1 or 1)) % #PERIODS + 1
    UI.period = PERIODS[i]
    UI.offset = 0
    UI.Refresh()
  end)
  script(UI.periodButton, "OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Période du bilan")
    GameTooltip:AddLine("30 derniers jours, 7 derniers jours, ou aujourd'hui (depuis minuit). « Ce qui marche » garde toujours 30 j.", 1, 1, 1, true)
    GameTooltip:AddLine("Clic : suivante · clic droit : précédente", 0.5, 0.8, 1)
    GameTooltip:Show()
  end)
  script(UI.periodButton, "OnLeave", function() GameTooltip:Hide() end)

  -- Bandeau du Bilan : cinq cases (farm, achat-revente, dépôts, stock, = bilan réel), survol = définition
  UI.band = CreateFrame("Frame", nil, f)
  UI.band:SetHeight(BAND_H - 6)
  UI.band:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -TOP)
  UI.band:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -TOP)
  UI.bandBoxes = {}
  for i, def in ipairs(BAND) do
    local box = CreateFrame("Frame", nil, UI.band)
    box:SetHeight(BAND_H - 6)
    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, i == #BAND and 0.09 or 0.04)
    box.label = Look.Text(box, "small", "LABEL", "GameFontDisableSmall")
    box.value = Look.Text(box, "head", "VALUE", "GameFontHighlight")
    box.sub = Look.Text(box, "small", "LABEL", "GameFontDisableSmall")
    for k, fs in ipairs({ box.label, box.value, box.sub }) do
      fs:SetPoint("TOPLEFT", box, "TOPLEFT", 6, -3 - (k - 1) * 13)
      fs:SetPoint("RIGHT", box, "RIGHT", -4, 0)
      fs:SetJustifyH("LEFT")
      fs:SetWordWrap(false)
    end
    box.label:SetText(def[1])
    box.tip = def
    box:EnableMouse(true)
    script(box, "OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:AddLine(self.label:GetText() or self.tip[1])
      GameTooltip:AddLine(self.tip[2], 1, 1, 1, true)
      GameTooltip:Show()
    end)
    script(box, "OnLeave", function() GameTooltip:Hide() end)
    UI.bandBoxes[i] = box
  end
  UI.bandEq = Look.Text(UI.band, "head", "LABEL", "GameFontNormal")
  UI.bandEq:SetText("=")
  -- Aide : une seule ligne (les longues aides débordaient sur les en-têtes) ; le texte entier
  -- s'affiche en survolant la ligne
  UI.helpZone = CreateFrame("Frame", nil, f)
  UI.helpZone:SetHeight(18)
  UI.helpZone:EnableMouse(true)
  UI.help = Look.Text(UI.helpZone, "small", "TEXT", "GameFontDisableSmall")
  UI.help:SetAllPoints()
  UI.help:SetJustifyH("LEFT")
  UI.help:SetWordWrap(false)
  script(UI.helpZone, "OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
    GameTooltip:AddLine(MODES[UI.mode].title)
    GameTooltip:AddLine(UI.helpText or "", 1, 1, 1, true)
    local long = MODES[UI.mode].helpLong
    if long then GameTooltip:AddLine(long, 0.8, 0.8, 0.8, true) end
    GameTooltip:AddLine("Survol d'un en-tête : sa définition · clic : trier · molette : défiler", 0.5, 0.8, 1)
    GameTooltip:Show()
  end)
  script(UI.helpZone, "OnLeave", function() GameTooltip:Hide() end)

  -- En-têtes cliquables (tri) ; une flèche marque la colonne triée
  UI.headers = {}
  for i = 1, MAX_COLS do
    local h = CreateFrame("Button", nil, f)
    h:SetHeight(18)
    local fs = Look.Text(h, "small", "LABEL", "GameFontNormalSmall")
    fs:SetAllPoints()
    h.text = fs
    local arrow = h:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    arrow:SetSize(9, 8)
    arrow:Hide()
    h.arrow = arrow
    script(h, "OnClick", function()
      local key = MODES[UI.mode].cols[i][4]
      if UI.sortKey == key then UI.sortDesc = not UI.sortDesc else UI.sortKey, UI.sortDesc = key, true end
      UI.offset = 0
      UI.Refresh()
    end)
    script(h, "OnEnter", function(self)
      local title = MODES[UI.mode].cols[i][1]
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(title)
      local def = COL_HELP[UI.mode .. "." .. title] or COL_HELP[title]
      if def then GameTooltip:AddLine(def, 1, 1, 1, true) end
      GameTooltip:AddLine("Clic : trier par « " .. title .. " » · reclic : inverser", 0.5, 0.8, 1)
      GameTooltip:Show()
    end)
    script(h, "OnLeave", function() GameTooltip:Hide() end)
    UI.headers[i] = h
  end

  -- Lignes (une sur deux légèrement plus claire pour suivre la ligne d'un bout à l'autre)
  UI.rows = {}
  for r = 1, MAX_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(ROW_H)
    if r % 2 == 0 then
      local zebra = row:CreateTexture(nil, "BACKGROUND")
      zebra:SetAllPoints()
      zebra:SetColorTexture(1, 1, 1, 0.03)
    end
    Look.RowHighlight(row)
    row.cells = {}
    for i = 1, MAX_COLS do
      local fs = Look.Text(row, "small", "TEXT", "GameFontHighlightSmall")
      fs:SetHeight(ROW_H)
      fs:SetWordWrap(false)
      row.cells[i] = fs
    end
    script(row, "OnEnter", function(self)
      local id = self.entry and entryItem(self.entry)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if id then GameTooltip:SetHyperlink("item:" .. id) end
      -- la ligne entière s'affiche dans le panneau de détail sous le tableau ; elle y reste
      UI.ShowDetail(self.entry, true)
      -- au-delà de 5 lignes le panneau coupe : la colonne de texte entière va dans l'infobulle
      local cols = MODES[UI.mode].cols
      local last = cols[#cols]
      local dt = UI.detail and UI.detail.text
      if self.entry and (last[5] or "LEFT") == "LEFT" and dt and dt.IsTruncated and dt:IsTruncated() == true then
        local ok, v = pcall(last[3], self.entry)
        if ok and v and v ~= "" then GameTooltip:AddLine(last[1] .. " : |cffffffff" .. tostring(v) .. "|r", 1, 0.82, 0, true) end
      end
      local hint = MODES[UI.mode].hint
      if hint then
        GameTooltip:AddLine(hint, 0.5, 0.8, 1, true)
      elseif id and ns.isAHOpen() then
        GameTooltip:AddLine("Clic : afficher à l'achat dans l'HV · Maj-clic : lien", 0.5, 0.8, 1)
      end
      local n = GameTooltip:NumLines()
      if id or (type(n) == "number" and n > 0) then GameTooltip:Show() else GameTooltip:Hide() end
    end)
    script(row, "OnLeave", function() GameTooltip:Hide() end)
    if row.RegisterForClicks then row:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    script(row, "OnClick", function(self, button)
      local id = self.entry and entryItem(self.entry)
      if id and IsModifiedClick and IsModifiedClick("CHATLINK") then
        local _, link = ns.GetItemInfo(id)
        if link then ChatEdit_InsertLink(link) end
      elseif self.entry and MODES[UI.mode].onClick then
        MODES[UI.mode].onClick(self.entry, button)
      elseif id and button ~= "RightButton" then
        UI.ShowItem(id)
      end
    end)
    UI.rows[r] = row
  end

  -- la hauteur n'est connue qu'au rendu suivant quand le contenu change de cadre : on réaffiche alors
  script(f, "OnSizeChanged", function() if f:IsVisible() then UI.Refresh() end end)
  f:EnableMouseWheel(true)
  script(f, "OnMouseWheel", function(_, delta)
    UI.offset = math.max(0, UI.offset - delta * 3)
    UI.Refresh()
  end)

  -- Tableau vide : explication à la place des lignes
  UI.empty = Look.Text(f, "body", "LABEL", "GameFontDisable")
  UI.empty:SetJustifyH("CENTER")
  UI.empty:Hide()

  -- Panneau de détail : ligne survolée en entier (raison, chiffres sans colonne, preuves)
  local detail = CreateFrame("Frame", nil, f)
  detail:SetHeight(DETAIL_H - 6)
  detail:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 36)
  detail:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 36)
  local dbg = detail:CreateTexture(nil, "BACKGROUND")
  dbg:SetAllPoints()
  dbg:SetColorTexture(1, 1, 1, 0.05)
  detail.text = Look.Text(detail, "small", "TEXT", "GameFontHighlightSmall")
  detail.text:SetPoint("TOPLEFT", detail, "TOPLEFT", 6, -4)
  detail.text:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -6, 4)
  detail.text:SetJustifyH("LEFT")
  if detail.text.SetJustifyV then detail.text:SetJustifyV("TOP") end
  detail.text:SetWordWrap(true)
  if detail.text.SetMaxLines then detail.text:SetMaxLines(5) end
  UI.detail = detail

  local scanBtn = Look.Button(f, "Scanner l'HV", 110, 22)
  scanBtn:SetPoint("BOTTOMRIGHT", -12, 8)
  script(scanBtn, "OnClick", function() ns.safe("scan", ns.Scan.Start); UI.Refresh() end)
  UI.scanButton = scanBtn

  local claudeBtn = Look.Button(f, "Rapport Claude", 120, 22)
  claudeBtn:SetPoint("RIGHT", scanBtn, "LEFT", -6, 0)
  script(claudeBtn, "OnClick", function() ns.safe("rapport", ns.Export.Show) end)

  local optBtn = Look.Button(f, "Options", 70, 22)
  optBtn:SetPoint("RIGHT", claudeBtn, "LEFT", -6, 0)
  script(optBtn, "OnClick", function() ns.safe("options", ns.Options.Toggle) end)

  -- le pied de page s'arrête avant les boutons (il passait dessous quand le texte était long)
  UI.footer = Look.Text(f, "small", "LABEL", "GameFontDisableSmall")
  UI.footer:SetPoint("BOTTOMLEFT", 14, 12)
  UI.footer:SetPoint("BOTTOMRIGHT", optBtn, "BOTTOMLEFT", -10, 4)
  UI.footer:SetJustifyH("LEFT")
  UI.footer:SetWordWrap(false)

  UI.SetMode("advice")
end

function UI.SetMode(mode)
  UI.mode = mode
  UI.offset = 0
  UI.detailKey = nil
  if GROUP[mode] then UI.lastView[GROUP[mode]] = mode end
  UI.sortKey = MODES[mode].sort
  UI.sortDesc = not MODES[mode].asc
  for key, b in pairs(UI.modeButtons) do
    ns.Look.Selected(b, key == mode or GROUP[mode] == key)
  end
  local cols = MODES[mode].cols
  -- le bandeau du Bilan pousse le tableau vers le bas
  UI.top = TOP + (MODES[mode].band and BAND_H or 0)
  local top = UI.top
  if MODES[mode].band then UI.band:Show() else UI.band:Hide() end
  for r, row in ipairs(UI.rows) do
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", UI.content, "TOPLEFT", 14, -top - r * ROW_H)
    row:SetPoint("TOPRIGHT", UI.content, "TOPRIGHT", -14, -top - r * ROW_H)
  end
  UI.empty:ClearAllPoints()
  UI.empty:SetPoint("TOPLEFT", UI.content, "TOPLEFT", 40, -top - 3 * ROW_H)
  UI.empty:SetPoint("TOPRIGHT", UI.content, "TOPRIGHT", -40, -top - 3 * ROW_H)
  local x = 14
  for i = 1, MAX_COLS do
    local col, h = cols[i], UI.headers[i]
    if col then
      -- la dernière colonne (Conseil, Pourquoi…) prend toute la place qui reste jusqu'au bord droit :
      -- sa largeur n'est qu'un minimum, la fenêtre et l'onglet de l'HV sont plus larges que les colonnes
      local stretch = i == #cols and (col[5] or "LEFT") == "LEFT"
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", UI.content, "TOPLEFT", x, -top)
      if stretch then h:SetPoint("TOPRIGHT", UI.content, "TOPRIGHT", -14, -top) else h:SetWidth(col[2]) end
      h.text:SetText(col[1])
      h.text:SetJustifyH(col[5] or "LEFT")
      h:Show()
      for _, row in ipairs(UI.rows) do
        local fs = row.cells[i]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", row, "LEFT", x - 14, 0)
        if stretch then fs:SetPoint("RIGHT", row, "RIGHT", -4, 0) else fs:SetWidth(col[2] - 4) end
        fs:SetJustifyH(col[5] or "LEFT")
        fs:Show()
      end
      x = x + col[2] + GAP
    else
      h:Hide()
      for _, row in ipairs(UI.rows) do row.cells[i]:SetText(""); row.cells[i]:Hide() end
    end
  end
  local isMarket = mode == "market"
  if isMarket then UI.catButton:Show(); UI.liqButton:Show() else UI.catButton:Hide(); UI.liqButton:Hide() end
  local isCraft = GROUP[mode] ~= nil
  -- Marché : le bouton Vue se range à gauche des filtres (catégorie, volume) de la vue Signaux
  UI.viewButton:ClearAllPoints()
  if isMarket then
    UI.viewButton:SetPoint("TOPRIGHT", UI.catButton, "TOPLEFT", -6, 0)
  else
    UI.viewButton:SetPoint("TOPRIGHT", UI.content, "TOPRIGHT", -14, -54)
  end
  if isCraft then
    UI.viewButton:Show()
    local list = VIEWS[GROUP[mode]]
    local i = 1
    for k, m in ipairs(list) do if m == mode then i = k end end
    UI.viewButton:SetText(("Vue : %s (%d/%d)"):format(MODES[mode].view or MODES[mode].title, i, #list))
  else
    UI.viewButton:Hide()
  end
  local hasPeriod = mode == "ledger" or mode == "journal"
  if hasPeriod then UI.periodButton:Show() else UI.periodButton:Hide() end
  -- l'aide s'arrête avant les boutons de filtre, quelle que soit la largeur de l'onglet qui l'accueille
  local z = UI.helpZone
  z:ClearAllPoints()
  z:SetPoint("TOPLEFT", UI.content, "TOPLEFT", 14, -56)
  if isMarket then
    z:SetPoint("TOPRIGHT", UI.viewButton, "TOPLEFT", -10, -2)
  elseif hasPeriod then
    z:SetPoint("TOPRIGHT", UI.periodButton, "TOPLEFT", -10, -2)
  elseif isCraft then
    z:SetPoint("TOPRIGHT", UI.viewButton, "TOPLEFT", -10, -2)
  else
    z:SetPoint("TOPRIGHT", UI.content, "TOPRIGHT", -14, -56)
  end
  UI.Refresh()
end

-- Nombre de lignes qui tiennent dans la hauteur du contenu (plus grande dans l'onglet de l'HV de
-- Daylight UI que dans la fenêtre d'AHLedger). La ligne r occupe de top + r × 20 à top + (r + 1) × 20 px
-- depuis le haut (top = 78, plus le bandeau du Bilan) ; le pied de page prend les 36 derniers pixels,
-- le panneau de détail les DETAIL_H pixels au-dessus.
function UI.VisibleRows()
  local h = UI.content and UI.content:GetHeight()
  if type(h) ~= "number" or h <= 0 then return ROWS end
  return math.max(1, math.min(MAX_ROWS, math.floor((h - (UI.top or TOP) - 36 - DETAIL_H) / ROW_H) - 1))
end

function UI.Refresh()
  if not UI.frame then return end
  local m = MODES[UI.mode]
  UI.catButton:SetText("Catégorie : " .. CATS[UI.cat][1])
  UI.liqButton:SetText(UI.liquidOnly and "Volume : 1+/jour" or "Volume : tous")
  local _, _, plabel = UI.PeriodArgs(UI.mode)
  UI.periodButton:SetText("Période : " .. plabel)
  if m.band then
    -- cases réparties sur la largeur du contenu (fenêtre ou onglet de l'HV) ; la dernière, le résultat, plus large
    local w = UI.content:GetWidth()
    if type(w) ~= "number" or w <= 0 then w = WIDTH end
    local eq, gap = 16, 6
    local unit = (w - 28 - eq - gap * 4) / 5.3
    local x = 0
    for i, box in ipairs(UI.bandBoxes) do
      local bw = i == #UI.bandBoxes and unit * 1.3 or unit
      box:ClearAllPoints()
      box:SetPoint("TOPLEFT", UI.band, "TOPLEFT", x, 0)
      box:SetWidth(bw)
      x = x + bw + gap
      if i == #UI.bandBoxes - 1 then
        UI.bandEq:ClearAllPoints()
        UI.bandEq:SetPoint("CENTER", UI.band, "TOPLEFT", x + eq / 2 - gap / 2, -(BAND_H - 6) / 2)
        x = x + eq
      end
    end
    UI.FillBand(UI.mode)
  end

  UI.title:SetText("AHLedger — " .. ns.realmKey())
  local help = m.help
  UI.helpText = type(help) == "function" and help() or help
  UI.help:SetText(UI.helpText)
  local scanning = ns.Scan and ns.Scan.running
  if UI.scanButton then UI.scanButton:SetText(scanning and "Scan en cours…" or "Scanner l'HV") end

  -- colonne triée : en-tête en surbrillance et flèche (bas = décroissant)
  for i, h in ipairs(UI.headers) do
    local col = m.cols[i]
    local on = col and col[4] == UI.sortKey
    if on then
      h.text:SetTextColor(1, 1, 1)
      h.arrow:ClearAllPoints()
      local tw = h.text:GetStringWidth()
      if type(tw) ~= "number" then tw = 0 end
      if col[5] == "RIGHT" then h.arrow:SetPoint("RIGHT", h, "RIGHT", -tw - 3, 0) else h.arrow:SetPoint("LEFT", h, "LEFT", tw + 3, 0) end
      if UI.sortDesc then h.arrow:SetTexCoord(0, 0.5625, 0, 1) else h.arrow:SetTexCoord(0, 0.5625, 1, 0) end
      h.arrow:Show()
    else
      ns.Look.Color(h.text, "LABEL")
      if not ns.Look.Daylight() then h.text:SetTextColor(1, 0.82, 0) end
      h.arrow:Hide()
    end
  end

  local data = m.rows()
  sortRows(data, UI.sortKey, UI.sortDesc)
  local shown = UI.VisibleRows()
  UI.offset = math.min(UI.offset, math.max(0, #data - shown))
  for r, row in ipairs(UI.rows) do
    local e = r <= shown and data[UI.offset + r] or nil
    row.entry = e
    if e then
      for i, col in ipairs(m.cols) do row.cells[i]:SetText(col[3](e)) end
      row:Show()
    else
      row:Hide()
    end
  end

  -- détail : la dernière ligne survolée si elle est encore là, sinon la première affichée
  local pick
  if UI.detailKey then
    for _, e in ipairs(data) do if entryKey(e) == UI.detailKey then pick = e; break end end
  end
  UI.ShowDetail(pick or data[UI.offset + 1])

  local db = ns.realmDB()
  if #data == 0 then
    local text = EMPTY[UI.mode] or ""
    if NEEDS_SCAN[UI.mode] and not db.lastScanTime then text = NO_SCAN
    elseif BUYS[UI.mode] and ns.Analysis.Stale() then text = staleText() end
    UI.empty:SetText(text)
    UI.empty:Show()
  else
    UI.empty:Hide()
  end

  local nDays, obs = 0, 0
  for _, d in pairs(db.days) do
    nDays = nDays + 1
    obs = obs + d.obs
  end
  -- « lignes 1–16 sur 120 » (la molette fait défiler) ; court pour que la date du scan tienne
  local range = #data > shown and ("lignes %d–%d sur %d"):format(
    UI.offset + 1, math.min(#data, UI.offset + shown), #data) or (#data == 1 and "1 ligne" or ("%d lignes"):format(#data))
  UI.footer:SetText(("%s · historique %d j · %.1f h observées · scan %s"):format(
    range, nDays, obs / 3600,
    db.lastScanTime and date("%d/%m %H:%M", db.lastScanTime) or "jamais"))
end

-- Loge le contenu : dans la fenêtre d'AHLedger (sous sa barre de titre) ou dans un onglet d'HV
function UI.Dock(host)
  local c = UI.content
  c:SetParent(host)
  c:ClearAllPoints()
  if host == UI.frame then
    c:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -ns.Look.Top())
    c:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
    UI.embedded = false
  else
    c:SetAllPoints(host)
    UI.embedded = host
    UI.frame:Hide()
  end
  c:Show()
end

function UI.Toggle()
  UI.Build()
  local f = UI.frame
  if UI.embedded then -- ressort le contenu de l'HV pour l'afficher seul
    UI.Dock(f)
    f:Show(); UI.Refresh()
    return
  end
  if f:IsShown() then f:Hide() else f:Show(); UI.Refresh() end
end

-- Rafraîchit l'affichage après un scan
function UI.OnData()
  if ns.BagMarks then ns.BagMarks.Refresh() end
  -- nouveau scan : tes flips sont-ils bons à vendre ?
  local db = ns.realmDB()
  if ns.Positions and db.lastScanTime and db.lastScanTime ~= UI.posScan and not (ns.Scan and ns.Scan.running) then
    UI.posScan = db.lastScanTime
    ns.safe("mes flips", ns.Positions.Check)
  end
  if UI.content and UI.content:IsVisible() then UI.Refresh() end
end

local function embed(host)
  UI.Build()
  UI.Dock(host)
  UI.Refresh()
end

-- Onglet "AHLedger" dans la barre d'onglets de l'HV du jeu (via LibAHTab, fournie par Auctionator)
local function createAHTab()
  if UI.ahTab or not AuctionHouseFrame or not LibStub then return end
  local lib = LibStub("LibAHTab-1-0", true)
  if not lib or lib:DoesIDExist("AHLedger") then return end
  local container = CreateFrame("Frame", nil, AuctionHouseFrame)
  container:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 4, -60)
  container:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -4, 4)
  script(container, "OnShow", function() embed(container) end)
  lib:CreateTab("AHLedger", container, "AHLedger", "AHLedger — analyse du marché")
  UI.ahTab = container
end

-- Onglet « AHLedger » dans la fenêtre HV de Daylight UI. DaylightUI_AuctionHouse remplace la fenêtre
-- du jeu (gardée ouverte mais invisible : l'onglet ci-dessus ne s'y voit pas). Daylight UI n'a pas
-- d'appel public pour ajouter un onglet à son HV : on passe par me.Wrap / me.Hook sur les fonctions
-- de son module, la voie que son API.md prévoit pour ça. Elle n'est pas garantie d'une version à
-- l'autre : si elle ne tient plus, AHLedger affiche à la place un bouton qui ouvre sa fenêtre.
function UI.HookDaylightAH()
  if UI.dlTried then return UI.dlTab end
  UI.dlTried = true
  local me = ns.Look.Me()
  local D = DaylightUI
  local mod = type(D) == "table" and type(D.GetModule) == "function" and D:GetModule("AuctionHouse")
  local Main = type(mod) == "table" and type(mod.ns) == "table" and mod.ns.Window
  if not (me and me.Wrap and me.Hook and type(Main) == "table" and type(Main.TABS) == "table"
          and type(Main.Build) == "function" and type(Main.ShowTab) == "function") or Main.frame then
    return false -- pas de Daylight UI, autre version, ou fenêtre déjà construite (trop tard pour un onglet)
  end
  local wrap = me.Wrap(Main, "Build", function(original, ...)
    local has = false
    for _, t in ipairs(Main.TABS) do if t.id == "ahledger" then has = true end end
    if not has then Main.TABS[#Main.TABS + 1] = { id = "ahledger", text = "AHLedger" } end
    return original(...)
  end)
  local hook = wrap and me.Hook(Main, "ShowTab", function(id)
    if id ~= "ahledger" then return end
    local f = Main.frame
    local page = f and f.pages and f.pages.ahledger
    if page then ns.safe("onglet Daylight UI", embed, page) end
  end)
  -- Daylight UI peut refuser une accroche (elle renvoie alors false) : sans les deux, pas d'onglet
  -- à moitié branché (vide), on défait l'autre et c'est le bouton de repli qui s'affiche.
  if not (wrap and hook) then
    if wrap and me.Unhook then me.Unhook(wrap) end
    return false
  end
  UI.dlTab = true
  UI.dlMain = Main
  return true
end

-- Clic sur une ligne : l'objet s'affiche à l'achat dans l'HV (Achat de Daylight UI, Auctionator ou le jeu).
-- AHLedger n'achète rien lui-même : le joueur choisit l'enchère et confirme dans l'écran d'achat.
function UI.ShowItem(id)
  local meta = AHLedgerDB.items[id]
  local name = ns.GetItemInfo(id) or (meta and meta.n)
  if not name or name == "" then return nil end
  return ns.Snipe.Search({ id = id, name = name }, false)
end

-- Daylight UI construit sa fenêtre HV à PLAYER_LOGIN : on s'y accroche avant, au chargement d'AHLedger
ns.on("ADDON_LOADED", function(name)
  if name == "AHLedger" and ns.Look.DaylightAH() then ns.safe("onglet Daylight UI", UI.HookDaylightAH) end
end)

-- Repli, si l'onglet Daylight UI n'a pas pu être ajouté : un bouton « AHLedger » tant que l'HV est
-- ouverte, « mover » de Daylight UI que le joueur place où il veut avec /dui unlock.
local function createAHButton()
  if UI.ahButton then return UI.ahButton end
  local b = ns.Look.Button(UIParent, "AHLedger", 96, 24)
  b:SetFrameStrata("HIGH")
  b:SetPoint("TOP", UIParent, "TOP", 0, -90)
  script(b, "OnClick", function()
    if UI.frame and UI.frame:IsShown() and not UI.embedded then UI.frame:Hide() else UI.Toggle() end
  end)
  b:Hide()
  local me = ns.Look.Me()
  if me and me.RegisterMover then me.RegisterMover(b, "ahbutton", "AHLedger (HV)", { "TOP", UIParent, "TOP", 0, -90 }) end
  UI.ahButton = b
  return b
end

ns.on("AUCTION_HOUSE_SHOW", function()
  ns.safe("onglet HV", createAHTab)
  if ns.Look.DaylightAH() and not UI.dlTab then ns.safe("bouton HV", function() createAHButton():Show() end) end
end)
-- Rien d'AHLedger ne reste à l'écran quand on quitte l'HV
ns.on("AUCTION_HOUSE_CLOSED", function()
  if UI.embedded and UI.frame then UI.frame:Hide() end
  if UI.ahButton then UI.ahButton:Hide() end
end)
