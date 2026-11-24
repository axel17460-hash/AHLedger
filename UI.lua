-- AHLedger - Fenêtre de classement (/ahl)
local _, ns = ...

local UI = { mode = "market", offset = 0, cat = 1, liquidOnly = true, sortDesc = true }
ns.UI = UI

local ROWS, ROW_H, WIDTH, MAX_COLS, GAP = 16, 20, 820, 9, 5
local MAX_ROWS = 40 -- lignes créées ; seules celles qui tiennent dans la hauteur disponible s'affichent

local CATS = {
  { "Tout", nil },
  { "Matériaux", { [7] = true } },
  { "Consommables", { [0] = true } },
  { "Recettes", { [9] = true } },
  { "Équipement", { [2] = true, [4] = true } },
  { "Mes métiers", "prof" }, -- ce que tu récoltes, fabriques, et leurs composants
}

local DIFF = { optimal = "|cffff8040orange|r", medium = "|cffffff00jaune|r", easy = "|cff40c040vert|r",
               trivial = "|cff808080gris|r" }

local ADVICE = { ["Vendre HV"] = "|cff40ff40Vendre HV|r", Garder = "|cff66ccffGarder|r", PNJ = "|cffffd100PNJ|r",
                 Attendre = "|cffff8040Attendre|r", Fabriquer = "|cffff9900Fabriquer|r" }

-- Message affiché à la place d'un tableau vide : pourquoi il est vide et quoi faire
local EMPTY = {
  market = "Aucun objet ne correspond. Essaie « Volume : tous » ou une autre catégorie.",
  flip = "Aucune occasion de flip dans le dernier scan. Rescanne un peu plus tard.",
  craft = "Aucune recette connue : ouvre une fois la fenêtre de chacun de tes métiers.",
  level = "Aucune recette connue : ouvre une fois la fenêtre de chacun de tes métiers.",
  bags = "Rien dans tes sacs pour l'instant : ouvre-les une fois (et ta banque) pour les relire.",
  ledger = "Aucun courrier d'HV relevé : passe à ta boîte aux lettres après tes ventes.",
  track = "Aucun conseil noté pour l'instant : chaque scan note les flips, achats PNJ, artisanat et conseils des sacs, et vérifie les anciens.",
  vendor = "Aucun achat PNJ rentable. Les marchands que tu visites sont retenus automatiquement.",
  snipe = "Aucune enchère sous le prix de rachat PNJ dans le dernier scan.",
  farm = "Aucune session de farm : tape /ahl farm start avant de farmer, puis /ahl farm stop.",
  recipes = "Aucune recette rentable trouvée. Ouvre tes fenêtres de métier, ou installe OneForAll pour voir aussi les recettes que tu n'as pas.",
  undercut = "Aucun marché où l'enchère la moins chère dépasse nettement le prix habituel. Rescanne plus tard.",
}
-- Onglets à deux vues : bouton « Vue : … » qui bascule vers l'autre
UI.VIEWS = {
  craft = { other = "level", label = "Vue : montée de niveau" },
  level = { other = "craft", label = "Vue : rentabilité" },
  ledger = { other = "track", label = "Vue : fiabilité des conseils" },
  track = { other = "ledger", label = "Vue : mes ventes" },
}
UI.PARENT = { level = "craft", track = "ledger" }
local NO_SCAN = "Pas encore de scan sur ce royaume : ouvre l'HV et clique « Scanner l'HV »."
local NEEDS_SCAN = { market = true, flip = true, snipe = true, vendor = true, craft = true, level = true, recipes = true,
                     undercut = true }

-- « +45 % » coloré comme les pastilles des sacs : vert mieux à l'HV, jaune pareil, rouge au PNJ
function UI.CompareCell(c)
  if not c then return "|cff808080—|r" end
  local col = ns.Bags.COLORS[c.kind]
  local hex = ("|cff%02x%02x%02x"):format(col[1] * 255, col[2] * 255, col[3] * 255)
  return hex .. (c.gain and ("%+.0f%%"):format(c.gain * 100) or "HV seul") .. "|r"
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

local MODES = {
  market = {
    title = "Marché",
    sort = "score",
    help = "Or/jour net × tendance × signaux. Survole un objet pour le détail.",
    cols = {
      { "Objet", 160, function(e) return itemLabel(e.id, e) end, "name" },
      { "Prix/u", 78, function(e) return ns.money(e.price) end, "price", "RIGHT" },
      { "Achat min/u", 78, function(e) return ns.money(e.minNow) end, "minNow", "RIGHT" },
      { "Tend./j", 52, function(e) return ns.pct(e.trend) end, "trend", "RIGHT" },
      { "Vendus/j", 52, function(e) return num(e.perDay) end, "perDay", "RIGHT" },
      { "Stock (j)", 50, function(e) return num(e.stockDays, "%.1f") end, "stockDays", "RIGHT" },
      { "Écoulé", 44, function(e) return share(e.sellThrough) end, "sellThrough", "RIGHT" },
      { "Or/jour", 82, function(e) return ns.money(e.gpd) end, "gpd", "RIGHT" },
      { "Signaux", 140, function(e) return table.concat(e.signals, " · ") end, "score" },
    },
    rows = function()
      local out, filter = {}, CATS[UI.cat][2]
      local rel = filter == "prof" and ns.Prof.Related() or nil
      for _, s in ipairs(ns.Analysis.All().list) do
        local okCat = not filter or (rel and rel[s.id]) or (not rel and s.class and filter[s.class])
        local okLiq = not UI.liquidOnly or (s.perDay and s.perDay >= 1)
        if okCat and okLiq then out[#out + 1] = s end
      end
      return out
    end,
  },
  flip = {
    title = "Flip HV",
    sort = "profit",
    help = "Achète jusqu'au prix indiqué. « Tout de suite » : remets en vente juste sous la prochaine enchère. « Stocker » : tout le marché est bas, garde-les jusqu'à ce que le prix remonte (délai et chance appris des creux passés ; bénéfice espéré). Clic = rechercher l'objet.",
    cols = {
      { "Objet", 160, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Qté", 45, function(e) return tostring(e.qty) end, "qty", "RIGHT" },
      { "Acheter jusqu'à/u", 95, function(e) return ns.money(e.maxBuy) end, "maxBuy", "RIGHT" },
      { "Coût total", 82, function(e) return ns.money(e.cost) end, "cost", "RIGHT" },
      { "Revente/u", 78, function(e) return ns.money(e.resale) end, "resale", "RIGHT" },
      -- à stocker : bénéfice espéré (« ~ »), pondéré par la chance que le prix remonte
      { "Bénéfice", 82, function(e) return "|cff40ff40" .. (e.kind == "stock" and "~" or "") .. ns.money(e.profit) .. "|r" end, "profit", "RIGHT" },
      { "ROI", 45, function(e) return ("%.0f%%"):format(e.roi * 100) end, "roi", "RIGHT" },
      { "Délai (j)", 52, function(e) return ("%.1f"):format(e.days) end, "days", "RIGHT" },
      { "Revendre", 130, function(e)
          local w = ns.Analysis.FlipWhen(e)
          if e.kind ~= "stock" then return "|cff40ff40" .. w .. "|r" end
          return (e.known and "|cff66ccff" or "|cffff8040") .. w .. "|r"
        end, "kind" },
    },
    rows = function() return ns.Analysis.Flips() end,
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
  craft = {
    title = "Artisanat",
    sort = "daily",
    help = "Tes recettes (ouvre chaque fenêtre de métier une fois). Coût = composants au moins cher entre PNJ et HV ; valeur = HV nette ou PNJ. Or/j = bénéfice × ta part des ventes du marché (25 %), ou 20 fabrications/j au PNJ. Orange/jaune = gain de compétence.",
    cols = {
      { "Recette", 150, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Métier", 62, function(e) return ns.Prof.LABEL[e.prof] or e.prof end, "prof" },
      { "Coût", 78, function(e) return e.cost and ns.money(e.cost) or ("|cff808080%d prix ?|r"):format(e.missing) end, "cost", "RIGHT" },
      { "Valeur", 78, function(e) return ns.money(math.max(e.value or 0, e.vendorValue)) end, "value", "RIGHT" },
      { "Bénéfice", 78, function(e) return e.profit and ((e.profit >= 0 and "|cff40ff40" or "|cffff5050") .. ns.money(e.profit) .. "|r") or "-" end, "profit", "RIGHT" },
      { "Or/j", 60, function(e) return e.daily and ns.money(e.daily) or "-" end, "daily", "RIGHT" },
      { "Vendre", 42, function(e) return e.sellTo or "-" end, "sellTo" },
      { "Vendus/j", 52, function(e) return num(e.perDay) end, "perDay", "RIGHT" },
      { "Niveau", 55, function(e) return DIFF[e.diff] or "-" end, "diff" },
    },
    rows = function() return ns.Analysis.Crafts() end,
  },
  level = {
    title = "Montée",
    tab = false, -- vue de l'onglet Artisanat
    sort = "perPoint",
    asc = true,
    help = "Coût d'un point de compétence au niveau actuel : (composants − revente) ÷ chance de gain. Plan complet : /ahl monter cuir 225.",
    cols = {
      { "Recette", 165, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Métier", 62, function(e) return ns.Prof.LABEL[e.prof] or e.prof end, "prof" },
      { "Niveau", 55, function(e) return DIFF[e.diff] or "-" end, "diff" },
      { "Chance", 50, function(e) return ("%.0f%%"):format(e.chance * 100) end, "chance", "RIGHT" },
      { "Composants", 78, function(e) return e.cost and ns.money(e.cost) or "|cff808080prix ?|r" end, "cost", "RIGHT" },
      { "Revente", 78, function(e) return ns.money(e.value) end, "value", "RIGHT" },
      { "Coût / point", 85, function(e) return e.perPoint and ((e.perPoint <= 0 and "|cff40ff40" or "") .. ns.money(e.perPoint) .. (e.perPoint <= 0 and "|r" or "")) or "-" end, "perPoint", "RIGHT" },
      { "Recette à acheter", 100, function(e) return e.learnCost and ns.money(e.learnCost) or "" end, "learnCost", "RIGHT" },
    },
    rows = function()
      local out = {}
      for _, prof in ipairs(ns.Plan.CraftProfs()) do
        for _, e in ipairs(ns.Plan.NextPoints(prof)) do out[#out + 1] = e end
      end
      return out
    end,
  },
  recipes = {
    title = "Rentables",
    sort = "daily",
    help = "Toutes les recettes de la base (les tiennes + OneForAll), apprises ou non, même d'un métier que tu n'as pas : bénéfice par fabrication (composants au moins cher PNJ/HV, revente HV nette ou PNJ), or/jour que le marché absorbe (ta part de 25 % des ventes × confiance). Amorti = jours de bénéfice pour rembourser la recette. Accès : apprise, à apprendre (où, combien), niveau requis.",
    cols = {
      { "Recette", 150, function(e)
          return itemLabel(e.id, e.s) .. (e.made > 1 and (" ×" .. num(e.made)) or "")
            .. (e.trust == "test" and " |cffffd100(à tester)|r" or "")
        end, "name" },
      { "Métier", 58, function(e) return ns.Prof.LABEL[e.prof] or e.prof end, "prof" },
      { "Accès", 125, function(e) return e.access end, "accessOrder" },
      { "Coût", 70, function(e) return ns.money(e.cost) end, "cost", "RIGHT" },
      { "Bénéfice", 70, function(e) return "|cff40ff40" .. ns.money(e.profit) .. "|r" end, "profit", "RIGHT" },
      { "ROI", 42, function(e) return ("%.0f%%"):format(e.roi * 100) end, "roi", "RIGHT" },
      { "Vendus/j", 48, function(e) return e.sellTo == "PNJ" and "PNJ" or num(e.perDay) end, "perDay", "RIGHT" },
      { "Or/j", 70, function(e) return ns.money(e.daily) end, "daily", "RIGHT" },
      { "Amorti", 55, function(e)
          if e.payback == 0 then return "|cff808080—|r" end
          return e.payback and ("%.1f j"):format(e.payback) or "|cff808080?|r"
        end, "payback", "RIGHT" },
    },
    rows = function() return ns.Opp.Recipes() end,
  },
  undercut = {
    title = "Sous-coter",
    sort = "score",
    help = "Marchés où l'enchère la moins chère est nettement au-dessus du prix habituel (prix réel de vente, sinon moyenne 7 j) : poste juste dessous, tu vends plus cher que d'habitude et en premier. À poster = un jour de ventes (au-delà, on te sous-cotera). Gain en plus = (poster − habituel) × quantité, net de commission. Pour toi : ce que tu as en sacs/banque, ce que tu sais fabriquer moins cher, et les risques. Clic = afficher l'objet dans l'HV.",
    cols = {
      { "Objet", 150, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Poster à/u", 75, function(e) return ns.money(e.post) end, "post", "RIGHT" },
      { "Habituel/u", 75, function(e) return ns.money(e.fair) end, "fair", "RIGHT" },
      { "Écart", 45, function(e) return "|cff40ff40" .. ns.pct(e.premium) .. "|r" end, "premium", "RIGHT" },
      { "À poster", 48, function(e) return tostring(e.qty) end, "qty", "RIGHT" },
      { "Gain en plus", 75, function(e) return "|cff40ff40" .. ns.money(e.extra) .. "|r" end, "extra", "RIGHT" },
      { "Vendus/j", 48, function(e) return num(e.perDay) end, "perDay", "RIGHT" },
      { "Vendeurs", 48, function(e) return e.sellers and tostring(e.sellers) or "?" end, "sellers", "RIGHT" },
      { "Pour toi", 150, function(e) return e.notes end, "forYouOrder" },
    },
    rows = function() return ns.Opp.Undercuts() end,
  },
  bags = {
    title = "Mes objets",
    sort = "value",
    help = "Tes sacs (et ta banque, relue à chaque visite) : vendre à l'HV au prix indiqué, garder, vendre au PNJ ou attendre que le marché remonte. HV/PNJ : ce que l'HV rapporte de plus (net) que le marchand ; vert au-delà de +10 %, jaune entre −10 et +10 %, rouge en dessous.",
    cols = {
      { "Objet", 160, function(e) return itemLabel(e.id, e.s) end, "name" },
      { "Qté", 40, function(e) return tostring(e.count) end, "count", "RIGHT" },
      { "Où", 70, function(e) return e.where end, "where" },
      { "Conseil", 70, function(e) return ADVICE[e.action] or e.action end, "action" },
      { "Prix conseillé/u", 90, function(e) return e.post and ns.money(e.post) or "-" end, "post", "RIGHT" },
      { "À poster", 50, function(e) return e.postQty and tostring(e.postQty) or "-" end, "postQty", "RIGHT" },
      { "Valeur nette", 82, function(e) return ns.money(e.value) end, "value", "RIGHT" },
      { "HV/PNJ", 55, function(e) return UI.CompareCell(e.cmp) end, "cmpGain", "RIGHT" },
      { "Pourquoi", 130, function(e) return e.why or "" end, "why" },
    },
    rows = function()
      local out = ns.Bags.Advice()
      for _, e in ipairs(out) do
        e.cmp = ns.Bags.Compare(e.id)
        e.cmpGain = e.cmp and (e.cmp.gain or math.huge) or nil
      end
      return out
    end,
  },
  ledger = {
    title = "Bilan",
    sort = "balance",
    help = function()
      local _, t = ns.Ledger.Summary()
      local c = ns.Ledger.DB().calib or {}
      local calib = c.cut and ("commission mesurée %.1f %%"):format(c.cut * 100)
        or ("commission supposée %.0f %% (%d/%d ventes)"):format(ns.Analysis.AH_CUT * 100, c.n or 0, ns.Ledger.MIN_CALIB)
      return ("%d derniers jours, d'après tes courriers d'HV : recettes %s − achats %s = |cffffffff%s|r · %d vendus, %d expirés · %s."):format(
        ns.Ledger.DAYS, ns.money(t.revenue), ns.money(t.spent), ns.money(t.revenue - t.spent), t.sold, t.expired, calib)
    end,
    cols = {
      { "Objet", 160, function(e) return e.id and itemLabel(e.id) or (e.name or "?") end, "name" },
      { "Achetés", 50, function(e) return tostring(e.bought) end, "bought", "RIGHT" },
      { "Dépensé", 80, function(e) return ns.money(e.spent) end, "spent", "RIGHT" },
      { "Vendus", 50, function(e) return tostring(e.sold) end, "sold", "RIGHT" },
      { "Expirés", 50, function(e) return tostring(e.expired) end, "expired", "RIGHT" },
      { "Recettes", 80, function(e) return ns.money(e.revenue) end, "revenue", "RIGHT" },
      { "Vendu moy./u", 80, function(e) return ns.money(e.avgSale) end, "avgSale", "RIGHT" },
      { "vs prévu", 55, function(e) return ns.pct(e.gap) end, "gap", "RIGHT" },
      { "Solde", 85, function(e) return (e.balance >= 0 and "|cff40ff40" or "|cffff5050") .. ns.money(e.balance) .. "|r" end, "balance", "RIGHT" },
    },
    rows = function() return (ns.Ledger.Summary()) end,
  },
  track = {
    title = "Fiabilité",
    tab = false, -- vue de l'onglet Bilan
    sort = "order",
    asc = true,
    help = "Chaque conseil (flips, achat PNJ, artisanat à revendre, sacs « Vendre HV » et « PNJ ») est noté au scan où il apparaît, puis vérifié sur les scans suivants (3 j ; à stocker : jusqu'au rebond, 14 j au plus). Prix tenu = la revente annoncée était atteignable. Écoulé = le marché a acheté au moins ta quantité à ce prix (estimé ; les relistes repérés sont écartés). Réussi = les deux. Sacs « PNJ » : réussi si l'HV n'a pas clairement mieux payé ; sinon « Constaté » montre l'or manqué. Suivis = tu as acheté l'objet dans les 24 h (courriers d'HV) ; gain réel = tes reventes. /ahl fiabilite pour le détail.",
    cols = {
      { "Conseil", 175, function(e) return e.label end, "order" },
      { "Vérifiés", 50, function(e) return tostring(e.checked) end, "checked", "RIGHT" },
      { "Réussis", 50, function(e) return e.rate and ((e.rate >= 0.6 and "|cff40ff40" or e.rate >= 0.4 and "|cffffff00" or "|cffff5050") .. ("%.0f%%"):format(e.rate * 100) .. "|r") or "|cff808080—|r" end, "rate", "RIGHT" },
      { "Prix tenu", 55, function(e) return e.checked > 0 and ("%.0f%%"):format(e.priceOk / e.checked * 100) or "|cff808080—|r" end, "priceOk", "RIGHT" },
      { "En cours", 50, function(e) return tostring(e.open) end, "open", "RIGHT" },
      { "Prévu", 80, function(e) return ns.money(e.expect) end, "expect", "RIGHT" },
      { "Constaté", 80, function(e) return (e.gain >= 0 and "|cff40ff40" or "|cffff5050") .. ns.money(e.gain) .. "|r" end, "gain", "RIGHT" },
      { "Suivis", 45, function(e) return tostring(e.followed) end, "followed", "RIGHT" },
      { "Gain réel", 85, function(e) return e.followed > 0 and ((e.realGain >= 0 and "|cff40ff40" or "|cffff5050") .. ns.money(e.realGain) .. "|r") or "|cff808080—|r" end, "realGain", "RIGHT" },
    },
    rows = function()
      local out = {}
      for _, s in ipairs(ns.Track.Summary()) do
        if s.checked + s.open + s.nodata + s.followed > 0 then out[#out + 1] = s end
      end
      return out
    end,
  },
  vendor = {
    title = "Achat PNJ",
    sort = "gpd",
    help = "Objets achetables chez un marchand déjà visité et revendables à profit à l'HV (commission et dépôts déduits). « à tester » : peu de ventes vues, essaie une petite quantité. Survole une ligne pour le détail.",
    cols = {
      { "Objet", 170, function(e) return itemLabel(e.id, e.s) .. (e.reliable and "" or " |cffff9900(à tester)|r") end, "name" },
      { "Achat PNJ/u", 85, function(e) return ns.money(e.buy) end, "buy", "RIGHT" },
      { "Revente/u", 85, function(e) return ns.money(e.s.price) end, "price", "RIGHT" },
      { "Marge/u", 85, function(e) return ns.money(e.margin) end, "margin", "RIGHT" },
      { "ROI", 50, function(e) return ("%.0f%%"):format(e.roi * 100) end, "roi", "RIGHT" },
      { "Vendus/j", 60, function(e) return num(e.perDay) end, "perDay", "RIGHT" },
      { "Or/jour", 90, function(e) return ns.money(e.gpd) end, "gpd", "RIGHT" },
      { "Vendeur", 100, function(e) return (e.npc or "?") .. " (" .. (e.zone or "?") .. ")" end, "zone" },
    },
    rows = function() return ns.Analysis.VendorFlips() end,
  },
  snipe = {
    title = "Revente PNJ",
    sort = "profit",
    help = "Enchères moins chères que le prix de rachat du PNJ (dernier scan). Clic = rechercher l'objet dans « Parcourir » pour l'acheter.",
    cols = {
      { "Objet", 165, function(e) return itemLabel(e.id) end, "name" },
      { "Qté", 35, function(e) return tostring(e.count) end, "count", "RIGHT" },
      { "Achat/u", 80, function(e) return ns.money(e.cost / e.count) end, "unitCost", "RIGHT" },
      { "PNJ/u", 75, function(e) return ns.money(e.value / e.count) end, "unitValue", "RIGHT" },
      { "Achat total", 85, function(e) return ns.money(e.cost) end, "cost", "RIGHT" },
      { "Bénéfice", 85, function(e) return "|cff40ff40" .. ns.money(e.profit) .. "|r" end, "profit", "RIGHT" },
      { "Type", 60, function(e) return e.kind end, "kind" },
      { "Vendeur", 90, function(e) return e.owner or "?" end, "owner" },
    },
    rows = function()
      local out = {}
      for _, o in ipairs(ns.realmDB().snipes or {}) do out[#out + 1] = o end
      return out
    end,
    onClick = function(e) ns.Snipe.Search(e) end,
  },
  farm = {
    title = "Farm",
    sort = "total",
    help = "Tes sessions /ahl farm, valorisées aux prix actuels. Au-delà du volume que le marché absorbe, le loot est compté au prix PNJ.",
    cols = {
      { "Zone", 170, function(e) return e.zone end, "zone" },
      { "Heures", 55, function(e) return ("%.1f"):format(e.hours) end, "hours", "RIGHT" },
      { "Objets /h", 100, function(e) return ns.money(e.itemsPerHour) end, "itemsPerHour", "RIGHT" },
      { "Or brut /h", 100, function(e) return ns.money(e.moneyPerHour) end, "moneyPerHour", "RIGHT" },
      { "Total /h", 100, function(e) return ns.money(e.total) end, "total", "RIGHT" },
      { "Meilleur objet", 200, function(e) return e.best and itemLabel(e.best) or "-" end, "best" },
    },
    rows = function() return ns.Analysis.FarmZones() end,
  },
}

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

local function frameHeight() return 90 + ROWS * ROW_H + 40 end

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
  local TABS = { "market", "flip", "craft", "recipes", "undercut", "bags", "ledger", "vendor", "snipe", "farm" }
  local step = math.floor((WIDTH - 24) / #TABS) -- les onglets se partagent la largeur de la fenêtre
  for _, key in ipairs(TABS) do
    local b = Look.Button(f, MODES[key].title, step - 4, 22)
    b:SetPoint("TOPLEFT", x, -30)
    b:SetScript("OnClick", function() UI.SetMode(key) end)
    UI.modeButtons[key] = b
    x = x + step
  end

  -- Filtres (onglet Marché)
  UI.catButton = Look.Button(f, "", 140, 22)
  UI.catButton:SetPoint("TOPRIGHT", -134, -54)
  -- clic gauche : catégorie suivante ; clic droit : précédente
  if UI.catButton.RegisterForClicks then UI.catButton:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
  UI.catButton:SetScript("OnClick", function(_, button)
    local step = button == "RightButton" and -2 or 0
    UI.cat = (UI.cat + step) % #CATS + 1
    UI.offset = 0
    UI.Refresh()
  end)
  UI.catButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Catégorie")
    for i, c in ipairs(CATS) do
      local on = i == UI.cat
      GameTooltip:AddLine((on and "> " or "   ") .. c[1], on and 1 or 0.7, on and 0.82 or 0.7, on and 0 or 0.7)
    end
    GameTooltip:AddLine("Clic : suivante · clic droit : précédente", 0.5, 0.8, 1)
    GameTooltip:Show()
  end)
  UI.catButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  UI.liqButton = Look.Button(f, "", 118, 22)
  UI.liqButton:SetPoint("TOPRIGHT", -14, -54)
  UI.liqButton:SetScript("OnClick", function()
    UI.liquidOnly = not UI.liquidOnly
    UI.offset = 0
    UI.Refresh()
  end)
  UI.liqButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Volume")
    GameTooltip:AddLine("« 1+/jour » cache les objets qui se vendent moins d'une fois par jour : leur prix est peu fiable et ils immobilisent ton or.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  UI.liqButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  UI.viewButton = Look.Button(f, "", 160, 22)
  UI.viewButton:SetPoint("TOPRIGHT", -14, -54)
  UI.viewButton:SetScript("OnClick", function()
    UI.SetMode(UI.VIEWS[UI.mode].other)
  end)

  -- Aide : une seule ligne (les longues aides débordaient sur les en-têtes) ; le texte entier
  -- s'affiche en survolant la ligne
  UI.helpZone = CreateFrame("Frame", nil, f)
  UI.helpZone:SetHeight(18)
  UI.helpZone:EnableMouse(true)
  UI.help = Look.Text(UI.helpZone, "small", "TEXT", "GameFontDisableSmall")
  UI.help:SetAllPoints()
  UI.help:SetJustifyH("LEFT")
  UI.help:SetWordWrap(false)
  UI.helpZone:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
    GameTooltip:AddLine(MODES[UI.mode].title)
    GameTooltip:AddLine(UI.helpText or "", 1, 1, 1, true)
    GameTooltip:AddLine("Clic sur un en-tête : trier · molette : défiler", 0.5, 0.8, 1)
    GameTooltip:Show()
  end)
  UI.helpZone:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    h:SetScript("OnClick", function()
      local key = MODES[UI.mode].cols[i][4]
      if UI.sortKey == key then UI.sortDesc = not UI.sortDesc else UI.sortKey, UI.sortDesc = key, true end
      UI.offset = 0
      UI.Refresh()
    end)
    h:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Clic : trier par « " .. MODES[UI.mode].cols[i][1] .. " » · reclic : inverser", 0.5, 0.8, 1)
      GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI.headers[i] = h
  end

  -- Lignes (une sur deux légèrement plus claire pour suivre la ligne d'un bout à l'autre)
  UI.rows = {}
  for r = 1, MAX_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 14, -78 - r * ROW_H)
    row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -78 - r * ROW_H)
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
    row:SetScript("OnEnter", function(self)
      local id = self.entry and entryItem(self.entry)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if id then GameTooltip:SetHyperlink("item:" .. id) end
      -- texte des cellules coupées (« Signaux », « Pourquoi »…) en entier
      local cols = MODES[UI.mode].cols
      for i, col in ipairs(cols) do
        local fs = self.cells[i]
        if i > 1 and fs.IsTruncated and fs:IsTruncated() == true then
          GameTooltip:AddLine(col[1] .. " : |cffffffff" .. (fs:GetText() or "") .. "|r", 1, 0.82, 0, true)
        end
      end
      if id and ns.isAHOpen() then GameTooltip:AddLine("Clic : afficher à l'achat dans l'HV · Maj-clic : lien", 0.5, 0.8, 1) end
      local n = GameTooltip:NumLines()
      if id or (type(n) == "number" and n > 0) then GameTooltip:Show() else GameTooltip:Hide() end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
      local id = self.entry and entryItem(self.entry)
      if id and IsModifiedClick and IsModifiedClick("CHATLINK") then
        local _, link = ns.GetItemInfo(id)
        if link then ChatEdit_InsertLink(link) end
      elseif self.entry and MODES[UI.mode].onClick then
        MODES[UI.mode].onClick(self.entry)
      elseif id then
        UI.ShowItem(id)
      end
    end)
    UI.rows[r] = row
  end

  -- la hauteur n'est connue qu'au rendu suivant quand le contenu change de cadre : on réaffiche alors
  f:SetScript("OnSizeChanged", function() if f:IsVisible() then UI.Refresh() end end)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    UI.offset = math.max(0, UI.offset - delta * 3)
    UI.Refresh()
  end)

  -- Tableau vide : explication à la place des lignes
  UI.empty = Look.Text(f, "body", "LABEL", "GameFontDisable")
  UI.empty:SetPoint("TOPLEFT", 40, -78 - 3 * ROW_H)
  UI.empty:SetPoint("TOPRIGHT", f, "TOPRIGHT", -40, -78 - 3 * ROW_H)
  UI.empty:SetJustifyH("CENTER")
  UI.empty:Hide()

  local scanBtn = Look.Button(f, "Scanner l'HV", 110, 22)
  scanBtn:SetPoint("BOTTOMRIGHT", -12, 8)
  scanBtn:SetScript("OnClick", function() ns.safe("scan", ns.Scan.Start); UI.Refresh() end)
  UI.scanButton = scanBtn

  local claudeBtn = Look.Button(f, "Rapport Claude", 120, 22)
  claudeBtn:SetPoint("RIGHT", scanBtn, "LEFT", -6, 0)
  claudeBtn:SetScript("OnClick", function() ns.safe("rapport", ns.Export.Show) end)

  local optBtn = Look.Button(f, "Options", 70, 22)
  optBtn:SetPoint("RIGHT", claudeBtn, "LEFT", -6, 0)
  optBtn:SetScript("OnClick", function() ns.safe("options", ns.Options.Toggle) end)

  -- le pied de page s'arrête avant les boutons (il passait dessous quand le texte était long)
  UI.footer = Look.Text(f, "small", "LABEL", "GameFontDisableSmall")
  UI.footer:SetPoint("BOTTOMLEFT", 14, 12)
  UI.footer:SetPoint("BOTTOMRIGHT", optBtn, "BOTTOMLEFT", -10, 4)
  UI.footer:SetJustifyH("LEFT")
  UI.footer:SetWordWrap(false)

  UI.SetMode("market")
end

function UI.SetMode(mode)
  UI.mode = mode
  UI.offset = 0
  UI.sortKey = MODES[mode].sort
  UI.sortDesc = not MODES[mode].asc
  for key, b in pairs(UI.modeButtons) do
    ns.Look.Selected(b, key == mode or UI.PARENT[mode] == key)
  end
  local cols = MODES[mode].cols
  local x = 14
  for i = 1, MAX_COLS do
    local col, h = cols[i], UI.headers[i]
    if col then
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", UI.content, "TOPLEFT", x, -78)
      h:SetWidth(col[2])
      h.text:SetText(col[1])
      h.text:SetJustifyH(col[5] or "LEFT")
      h:Show()
      for _, row in ipairs(UI.rows) do
        local fs = row.cells[i]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", row, "LEFT", x - 14, 0)
        fs:SetWidth(col[2] - 4)
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
  local isCraft = UI.VIEWS[mode] ~= nil -- onglet à deux vues : bouton de bascule
  if isCraft then
    UI.viewButton:Show()
    UI.viewButton:SetText(UI.VIEWS[mode].label)
  else
    UI.viewButton:Hide()
  end
  -- l'aide s'arrête avant les boutons de filtre, quelle que soit la largeur de l'onglet qui l'accueille
  local z = UI.helpZone
  z:ClearAllPoints()
  z:SetPoint("TOPLEFT", UI.content, "TOPLEFT", 14, -56)
  if isMarket then
    z:SetPoint("TOPRIGHT", UI.catButton, "TOPLEFT", -10, -2)
  elseif isCraft then
    z:SetPoint("TOPRIGHT", UI.viewButton, "TOPLEFT", -10, -2)
  else
    z:SetPoint("TOPRIGHT", UI.content, "TOPRIGHT", -14, -56)
  end
  UI.Refresh()
end

-- Nombre de lignes qui tiennent dans la hauteur du contenu (plus grande dans l'onglet de l'HV de
-- Daylight UI que dans la fenêtre d'AHLedger). La ligne r occupe de 78 + r × 20 à 78 + (r + 1) × 20 px
-- depuis le haut ; le pied de page (texte et boutons) prend les 36 derniers pixels.
function UI.VisibleRows()
  local h = UI.content and UI.content:GetHeight()
  if type(h) ~= "number" or h <= 0 then return ROWS end
  return math.max(1, math.min(MAX_ROWS, math.floor((h - 78 - 36) / ROW_H) - 1))
end

function UI.Refresh()
  if not UI.frame then return end
  local m = MODES[UI.mode]
  UI.catButton:SetText("Catégorie : " .. CATS[UI.cat][1])
  UI.liqButton:SetText(UI.liquidOnly and "Volume : 1+/jour" or "Volume : tous")
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

  local db = ns.realmDB()
  if #data == 0 then
    UI.empty:SetText((NEEDS_SCAN[UI.mode] and not db.lastScanTime) and NO_SCAN or EMPTY[UI.mode] or "")
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
  container:SetScript("OnShow", function() embed(container) end)
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
  me.Wrap(Main, "Build", function(original, ...)
    local has = false
    for _, t in ipairs(Main.TABS) do if t.id == "ahledger" then has = true end end
    if not has then Main.TABS[#Main.TABS + 1] = { id = "ahledger", text = "AHLedger" } end
    return original(...)
  end)
  me.Hook(Main, "ShowTab", function(id)
    if id ~= "ahledger" then return end
    local f = Main.frame
    local page = f and f.pages and f.pages.ahledger
    if page then ns.safe("onglet Daylight UI", embed, page) end
  end)
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
  b:SetScript("OnClick", function()
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
