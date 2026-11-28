-- AHLedger - Le conseiller : ce que tu as de mieux à faire maintenant, tous domaines confondus.
--
-- Chaque conseil est une action (vendre, remettre une enchère au bon prix, fabriquer, monter un
-- métier, farmer, flipper), un gain estimé en or, une confiance et sa raison sourcée :
--   prouvé       tes courriers, ou 12 h au moins de scans 0.9 (ventes sûres, retraits exclus)
--   certain      le prix du marchand
--   à confirmer  d'anciens scans seulement (retraits comptés comme ventes : chiffre surestimé)
--   à tester     aucune preuve : une petite mise en vente le dira
--   calcul       une estimation (coût d'un point de métier)
-- Les conseils sont rangés par moment : d'abord ce que tu fais avec ce que tu as (sacs, enchères),
-- puis les occasions (flips, achats PNJ), puis ce qui se prépare (fabriquer, farmer, monter un métier).
-- AHLedger n'achète ni ne vend rien : il te dit quoi faire, tu le fais.
local _, ns = ...

local Adv = {}
ns.Advisor = Adv

Adv.SHORT_LEFT = 2 * 3600      -- enchère qui expire dans moins de 2 h : on attend son retour plutôt que d'annuler
Adv.CRAFT_MIN_DAILY = 1000     -- recette conseillée : 10 pa par jour au moins
Adv.WORKS_ST = 0.6             -- bilan : 60 % de tes mises en vente parties = « ça marche »
Adv.TOP = { flip = 3, vendor = 2, craft = 3, farm = 2 } -- combien d'occasions de chaque sorte dans les conseils

-- Ordre des conseils : ce qui se fait tout de suite avec ce que tu as, puis le reste
Adv.TIER = { mail = 9, sell = 8, relist = 8, flipsell = 8, npc = 7, test = 6, craftup = 6, flip = 5, vendor = 5,
             craft = 4, farm = 3, level = 2 }

local function money(c) return ns.money(c) end
local function rate(v)
  if not v then return "?" end
  if v >= 10 then return ("%.0f"):format(v) end
  return (("%.1f"):format(v):gsub("%.0$", ""))
end

-- D'où vient la preuve qu'un objet se vend : la règle de Decide (un prix douteux n'est jamais « prouvé »)
function Adv.Conf(sells, d) return ns.Decide.Conf(sells, d) end

-- Prix net d'une unité vendue à post : la formule unique d'Analysis
local function netAt(post, s, vendor, p) return (ns.Analysis.NetAt(post, s, vendor, p)) end

local function scanAge()
  local t = ns.realmDB().lastScanTime
  return t and (time() - t) / 3600 or nil
end

-------------------------------------------------------------------------------
-- Mes enchères : pour chacune, la laisser, la reprendre à un meilleur prix, ou la laisser expirer
-------------------------------------------------------------------------------
-- verdict : sold (l'or t'attend) | keep (laisse) | relist (annule et remets) | relistlater (remets à son
-- retour) | wait (marché bradé, ne suis pas) | npc (laisse expirer, puis marchand)
function Adv.Auctions()
  local groups = ns.Auctions and ns.Auctions.Summary()
  if not groups then return {} end
  local A, D = ns.Analysis, ns.Decide
  local age = scanAge()
  local out = {}
  for _, gr in ipairs(groups) do
    local s = gr.s
    local e = { id = gr.id, s = s, qty = gr.qty, unit = gr.unit, left = gr.left, auctions = gr.auctions, conf = "certain" }
    if gr.isSold then
      e.verdict, e.why, e.gold = "sold", "vendue : l'or t'attend à la boîte aux lettres", gr.value
    elseif not gr.unit then
      e.verdict, e.why = "keep", "enchère sans achat immédiat : laisse courir"
    else
      -- même avis que Mes objets et l'infobulle : la décision de Decide pour ces unités
      local d = D.For(gr.id, gr.qty)
      local sells = d and d.sells or D.Sells(gr.id, s)
      local post, postWhy, floor = D.PostPrice(gr.id, s, D.TrustedRate(s))
      local vendor = D.VendorPrice(gr.id)
      local ref, refName = D.Ref(gr.id, s) -- équilibre, sinon plus bas habituel (même repère que Decide)
      e.floor, e.post, e.sells, e.conf = floor, post, sells.v, Adv.Conf(sells, d)
      local _, dep = A.NetAt(0, s, vendor)
      e.deposit = dep * gr.qty
      local keepGold = gr.unit * gr.qty * (1 - A.AH_CUT)
      if d and d.suspect then
        -- prix du marché douteux (bien au-dessus de l'habituel) : on ne fait pas annuler pour le suivre
        e.verdict, e.gold = "keep", keepGold
        e.why = ("ne la reprends pas : %s"):format(d.reason)
      elseif sells.v == "no" then
        e.verdict = "npc"
        e.why = ("ne se vend pas (%s) : laisse-la expirer, puis vends au PNJ %s/u"):format(sells.why, money(vendor))
      elseif not floor then
        e.verdict, e.gold, e.why = "keep", keepGold, "personne d'autre n'en vend : laisse"
      elseif gr.unit <= floor + 0.5 then
        e.verdict, e.gold, e.why = "keep", keepGold, "la moins chère du marché : laisse"
      elseif post and post >= gr.unit - 0.5 then
        e.verdict, e.gold = "keep", keepGold
        e.why = ("%s : ton prix tient, laisse"):format(postWhy)
      elseif ref and post < ref * D.LOW_VS_USUAL then
        e.verdict = "wait"
        e.why = ("bradé à %s (%s : %s) : ne suis pas, laisse"):format(money(floor), refName, money(ref))
      elseif vendor > 0 and netAt(post, s, vendor, (D.Odds(gr.id, post, s, sells))) <= vendor * D.VENDOR_EDGE then
        e.verdict = "npc"
        e.why = ("à %s/u l'HV ne paie pas plus que le marchand (%s) : laisse-la expirer, puis PNJ"):format(money(post), money(vendor))
      else
        -- ce que tu touches en la remettant : commission et nouveau dépôt déduits
        e.gold = post * gr.qty * (1 - A.AH_CUT) - (gr.left and gr.left <= Adv.SHORT_LEFT and 0 or e.deposit)
        if gr.left and gr.left <= Adv.SHORT_LEFT then
          e.verdict = "relistlater"
          e.why = ("sous-cotée (moins chère %s), expire dans %s : remets-la à %s/u à son retour"):format(
            money(floor), ns.Auctions.LeftText(gr.left), money(post))
        else
          e.verdict = "relist"
          e.why = ("sous-cotée (moins chère %s) : annule et remets à %s/u ; dépôt perdu ~%s"):format(
            money(floor), money(post), money(e.deposit))
        end
      end
      if age and age > D.STALE_HOURS then e.why = e.why .. (" (scan vieux de %.0f h : rescanne)"):format(age) end
    end
    out[#out + 1] = e
  end
  return out
end

-------------------------------------------------------------------------------
-- Bilan : ce qui marche, ce qui ne marche pas (tes courriers des 30 derniers jours)
-------------------------------------------------------------------------------
-- verdict : works (continue) | price (se vend, mais tes enchères expirent) | stop (0 vendu) |
-- early (trop tôt) | loss (achat-revente perdant) | gain (achat-revente gagnant)
function Adv.Review()
  local A, D = ns.Analysis, ns.Decide
  local rows = ns.Ledger.Summary()
  -- l'or (bilan réel, dépôts perdus, achat-revente) : le calcul unique de Tracker ; les courriers ne
  -- donnent ici que les nombres de ventes et d'expirations
  local flips, money30 = {}, {}
  if ns.Tracker then
    local _, list, _, items = ns.Tracker.Compute()
    for _, it in ipairs(list) do if it.id then flips[it.id] = it end end
    money30 = items or {}
  end
  local out = {}
  for _, r in ipairs(rows) do
    local f = r.id and flips[r.id]
    if r.sold + r.expired > 0 or (f and f.bought > 0) then
      local vendor = r.id and D.VendorPrice(r.id) or 0
      local e = { id = r.id, name = r.name, sold = r.sold, expired = r.expired, soldN = r.soldN, expiredN = r.expiredN,
                  st = r.sellThrough, avgSale = r.avgSale, revenue = r.revenue }
      local it = money30[r.id or r.name or "?"]
      e.lostDep = it and it.lostDep or 0
      e.net = it and it.real or (r.revenue - e.lostDep)
      -- achat-revente seul (la valeur ajoutée d'une fabrication n'en fait pas partie) ; prix payé à l'HV
      if f and f.bought > 0 then e.flip = f.result - (f.craftGain or 0) end
      local avgAH = f and f.bought > 0 and (f.spent and f.spent / f.bought or f.avgBuy) or 0
      if r.sold + r.expired == 0 then
        e.verdict = "hold"
        e.advice = ("%d achetés %s/u, pas encore revendus : suis-les dans Marché › Mes flips"):format(
          f.bought, money(avgAH))
      elseif e.flip and f.soldFromBuys > 0 and e.flip < 0 then
        e.verdict = "loss"
        e.advice = ("achat-revente perdant : %d achetés %s/u, revendus %s/u net : n'en rachète plus à ce prix"):format(
          f.bought, money(avgAH), money(f.avgSell or 0))
      elseif r.sold == 0 then
        -- même règle que Decide (Mes objets, infobulle) : on ne dit « arrête » que si Decide dit « ne se vend pas »
        local sells = r.id and D.Sells(r.id)
        if sells and sells.v == "no" then
          e.verdict = "stop"
          e.advice = ("0 vendu sur %d mises en vente (dépôts perdus ~%s) : arrête l'HV%s"):format(r.expiredN, money(e.lostDep),
            vendor > 0 and (", PNJ %s/u"):format(money(vendor)) or "")
        else
          e.verdict = "early"
          e.advice = ("%d mise%s en vente expirée%s, aucune vendue : trop tôt pour conclure%s"):format(r.expiredN,
            r.expiredN > 1 and "s" or "", r.expiredN > 1 and "s" or "", sells and (" ; " .. sells.why) or "")
        end
      elseif (r.sellThrough or 1) >= Adv.WORKS_ST then
        e.verdict = e.flip and e.flip > 0 and "gain" or "works"
        e.advice = ("%d vendus à ~%s/u, %.0f %% de tes mises en vente partent : continue%s"):format(r.sold,
          money(r.avgSale or 0), (r.sellThrough or 1) * 100, e.flip and (" (achat-revente, stock compris : %s)"):format(money(e.flip)) or "")
      else
        e.verdict = "price"
        local post = r.id and D.PostPrice(r.id, A.Get(r.id), D.TrustedRate(A.Get(r.id)))
        e.advice = ("%.0f %% seulement de tes mises en vente partent : vise %s, et moins à la fois"):format(
          (r.sellThrough or 0) * 100, post and ("%s/u (prix conseillé du dernier scan)"):format(money(post)) or "1c sous la moins chère")
      end
      e.impact = math.abs(e.verdict ~= "stop" and e.flip or e.net)
      out[#out + 1] = e
    end
  end
  return out
end

function Adv.ReviewTotals(rows)
  local t = { works = 0, price = 0, stop = 0, early = 0, loss = 0, gain = 0, net = 0, lostDep = 0 }
  for _, e in ipairs(rows or Adv.Review()) do
    t[e.verdict] = (t[e.verdict] or 0) + 1
    t.net, t.lostDep = t.net + e.net, t.lostDep + e.lostDep
  end
  return t
end

-------------------------------------------------------------------------------
-- Que farmer : les ressources qui se vendent, et ce que le marché t'en achète par jour
-------------------------------------------------------------------------------
local SUBCLASS_SRC = { [5] = "Tissu (loot)", [6] = "Dépeçage", [7] = "Minage", [8] = "Viande (loot)", [9] = "Herboristerie",
                       [10] = "Élémentaire", [11] = "Loot" }

-- Objets fabriqués (toutes les recettes de OneForAll, et les tiennes) : ils se fabriquent, ils ne se farment
-- pas (cuir traité, rouleaux de tissu, lingots : c'est l'onglet Artisanat qui en juge). Sauf les
-- transmutations, dont le résultat (essences…) se loote aussi.
local craftedSet, craftedVer
local function isTransmute(name) return type(name) == "string" and name:find("^Transmut") ~= nil end
local function crafted()
  if craftedSet and craftedVer == ns.dataVersion then return craftedSet end
  local set = {}
  local OFA = ns.RecipesOneForAll and ns.RecipesOneForAll.Data()
  for _, list in pairs(OFA and OFA.PROFESSION_RECIPES or {}) do
    if type(list) == "table" then
      for _, rec in ipairs(list) do
        if type(rec) == "table" and rec.i and not isTransmute(rec.n) then set[rec.i] = true end
      end
    end
  end
  for _, list in pairs(ns.Prof.Recipes() or {}) do
    for outId, r in pairs(list) do if not isTransmute(r.n) then set[outId] = true end end
  end
  craftedSet, craftedVer = set, ns.dataVersion
  return set
end

function Adv.FarmTargets()
  local A, D = ns.Analysis, ns.Decide
  local rel = ns.Prof.Related()
  local made = crafted()
  local looted = {}
  for _, f in ipairs(ns.realmDB().farm or {}) do
    for id in pairs(f.loot or {}) do looted[id] = f.zone end
  end
  local out = {}
  local fromVendor = ns.realmDB().vendor or {}
  for _, s in ipairs(A.All().list) do
    local id = s.id
    -- un objet qu'un marchand vend ne se farme pas : il s'achète (onglet Marché › Achat PNJ) ;
    -- un objet fabriqué non plus, sauf s'il se dépèce (le cuir lourd se fabrique ET se dépèce) ou que tu l'as looté
    local farmable = not fromVendor[id] and (not made[id] or ns.Prof.SKINNING[id] or looted[id])
    if farmable and (s.class == 7 or rel[id] == "dépeçage" or looted[id]) then
      local sells = D.Sells(id, s)
      local vendor = D.VendorPrice(id)
      local post = sells.v == "yes" and D.FairPost(id, s)
      local net = post and netAt(post, s, vendor, (D.Odds(id, post, s, sells))) -- même chance que le Bilan
      if net and net > vendor * D.VENDOR_EDGE and net >= 1 then
        local meta = AHLedgerDB.items[id]
        local sub = meta and meta.sc
        if meta and not sub and ns.GetItemInfo then
          sub = select(13, ns.GetItemInfo(id))
          meta.sc = sub
        end
        local share = (sells.rate or 0) * A.VENDOR_SHARE
        local e = { id = id, s = s, net = net, post = post, rate = sells.rate, share = share, daily = net * share,
                    conf = Adv.Conf(sells), why = sells.why, vendor = vendor }
        -- où le trouver : ton farm, le dépeçage, sinon la sorte de ressource (en vert : touche tes métiers)
        e.source = (looted[id] and ("ton farm : " .. looted[id])) or (ns.Prof.SKINNING[id] and "Dépeçage")
          or SUBCLASS_SRC[sub] or (rel[id] == "composant" and "tes recettes") or "ressource"
        e.mine = rel[id] ~= nil or looted[id] ~= nil
        -- prouvé d'abord (les anciens scans surestiment le débit), puis ce qui touche tes métiers
        e.rank = (e.conf == "prouvé" and 2e9 or 0) + (e.mine and 1e9 or 0) + e.daily
        out[#out + 1] = e
      end
    end
  end
  return out
end

-------------------------------------------------------------------------------
-- Monter un métier : la recette la moins chère par point, métier par métier
-------------------------------------------------------------------------------
function Adv.LevelNext()
  local out = {}
  if not ns.Plan then return out end
  local c = ns.Prof.Char()
  for _, prof in ipairs(ns.Plan.CraftProfs()) do
    local rank, max = c.skills[prof], c.max and c.max[prof]
    if rank and (not max or rank < max) then
      local best
      for _, e in ipairs(ns.Plan.NextPoints(prof)) do
        if e.perPoint and (not best or e.perPoint < best.perPoint) then best = e end
      end
      if best then
        best.rank, best.max = rank, max
        out[#out + 1] = best
      end
    end
  end
  return out
end

-------------------------------------------------------------------------------
-- Tout : ce que tu as de mieux à faire maintenant
-------------------------------------------------------------------------------
-- { tier, verb, id, label, qty, price, gold, perDay, conf, why, mode (onglet à ouvrir) }
local function plainName(id)
  local m = id and AHLedgerDB.items[id]
  return m and m.n or (id and ("#" .. id)) or "?"
end

local cache, cacheKey
function Adv.Actions()
  local key = tostring(ns.dataVersion) .. ":" .. tostring(ns.bagVersion)
  if cache and cacheKey == key then return cache end
  local out = {}
  local function add(e) e.rank = (Adv.TIER[e.kind] or 0) * 1e12 + math.max(e.gold or 0, 0); out[#out + 1] = e end

  -- 1. Ce que tu as : sacs et banque (la décision de Decide pour chaque objet)
  local npc = { n = 0, gold = 0, names = {} }
  for _, e in ipairs(ns.UI.BagRows()) do
    local d = e.d
    local conf = Adv.Conf(d.sells, d)
    if e.action == "HV" then
      add({ kind = "sell", id = e.id, s = e.s, qty = e.qtyNow, price = e.priceNow, gold = e.cashNow, conf = conf, why = e.plain, mode = "bags" })
    elseif e.action == "Tester" then
      add({ kind = "test", id = e.id, s = e.s, qty = e.qtyNow, price = e.priceNow, gold = e.cashNow, conf = "à tester", why = e.plain, mode = "bags" })
    elseif e.action == "Fabriquer" then
      add({ kind = "craftup", id = e.id, s = e.s, qty = d.craft.crafts, label = ("%s → %s"):format(plainName(e.id), d.craft.name),
            price = d.craft.post,
            gold = d.craft.total, conf = d.craft.to == "HV" and Adv.Conf(ns.Decide.Sells(d.craft.out)) or "certain",
            why = e.plain, mode = "bags" })
    elseif e.action == "PNJ" then
      npc.n, npc.gold = npc.n + 1, npc.gold + (e.cashNow or 0)
      npc.names[#npc.names + 1] = { plainName(e.id), e.cashNow or 0 }
    end
  end
  if npc.n > 0 then
    table.sort(npc.names, function(a, b) return a[2] > b[2] end)
    local list = {}
    for i = 1, math.min(4, #npc.names) do list[i] = npc.names[i][1] end
    add({ kind = "npc", label = ("%d objet%s"):format(npc.n, npc.n > 1 and "s" or ""), qty = npc.n, gold = npc.gold, conf = "certain",
          why = ("le marchand paie plus que l'HV ne rapporterait : %s%s"):format(table.concat(list, ", "), npc.n > 4 and "…" or ""),
          mode = "bags" })
  end

  -- 2. Tes enchères : l'or qui t'attend, celles à reprendre
  local mail = { n = 0, gold = 0 }
  for _, e in ipairs(Adv.Auctions()) do
    if e.verdict == "sold" then
      mail.n, mail.gold = mail.n + 1, mail.gold + (e.gold or 0)
    elseif e.verdict == "relist" or e.verdict == "relistlater" then
      add({ kind = "relist", id = e.id, s = e.s, qty = e.qty, price = e.post, gold = e.gold, conf = e.conf, why = e.why, mode = "auctions",
            verbText = e.verdict == "relist" and "Reprendre" or "Remettre" })
    end
  end
  if mail.n > 0 then
    add({ kind = "mail", label = ("%d vente%s"):format(mail.n, mail.n > 1 and "s" or ""), qty = mail.n, gold = mail.gold,
          conf = "certain", why = "tes enchères vendues : l'or t'attend à la boîte aux lettres", mode = "auctions" })
  end

  -- 3. Tes flips en cours bons à vendre
  if ns.Positions then
    for _, e in ipairs(ns.Positions.Rows()) do
      if e.action and e.action > 0 and (e.verdict == "high" or e.verdict == "sell" or e.verdict == "drop" or e.verdict == "late"
        or e.verdict == "undercut") then
        add({ kind = "flipsell", id = e.id, s = e.s, qty = e.action, price = e.sellAt, gold = (e.gainU or 0) * e.action,
              conf = Adv.Conf(ns.Decide.Sells(e.id, e.s)), why = e.why or "", mode = "positions" })
      end
    end
  end

  -- 4. Occasions : flips prouvés, achats PNJ à revendre. Pas d'achat conseillé sur un scan périmé :
  -- les enchères bradées qu'il montre sont sûrement parties
  local stale = ns.Analysis.Stale()
  local flips = stale and {} or ns.Analysis.Flips()
  table.sort(flips, function(a, b) return (a.profit or 0) > (b.profit or 0) end)
  local n = 0
  for _, f in ipairs(flips) do
    if f.kind ~= "stock" and n < Adv.TOP.flip then
      n = n + 1
      local s = f.s or ns.Analysis.Get(f.id)
      add({ kind = "flip", id = f.id, s = s, qty = f.qty, price = f.maxBuy, gold = f.profit,
            conf = s and s.measured and "prouvé" or "à confirmer",
            why = ("achète jusqu'à %s/u, revends tout de suite %s/u (ventes sûres ~%s/j)"):format(money(f.maxBuy), money(f.resale),
              rate(s and s.surePerDay)), mode = "flip" })
    end
  end
  local vflips = stale and {} or ns.Analysis.VendorFlips()
  table.sort(vflips, function(a, b) return (a.gpd or 0) > (b.gpd or 0) end)
  for i = 1, math.min(Adv.TOP.vendor, #vflips) do
    local v = vflips[i]
    add({ kind = "vendor", id = v.id, s = v.s, qty = math.max(1, math.floor(v.vol or 1)), price = v.buy, gold = v.gpd, perDay = true,
          conf = Adv.Conf(ns.Decide.Sells(v.id, v.s)), why = ("chez %s (%s) à %s/u, revends %s/u à l'HV"):format(v.npc or "?", v.zone or "?", money(v.buy),
            money(v.s and v.s.price or 0)), mode = "vendor" })
  end

  -- 5. À préparer : fabriquer pour vendre, farmer, monter un métier
  local crafts = {}
  for _, e in ipairs(ns.Analysis.Crafts()) do
    if e.daily and e.daily >= Adv.CRAFT_MIN_DAILY and e.sellTo == "HV" then crafts[#crafts + 1] = e end
  end
  table.sort(crafts, function(a, b) return a.daily > b.daily end)
  for i = 1, math.min(Adv.TOP.craft, #crafts) do
    local e = crafts[i]
    local sells = ns.Decide.Sells(e.id, e.s)
    add({ kind = "craft", id = e.id, s = e.s, qty = math.max(1, math.floor(e.vol + 0.5)), price = e.cost, gold = e.daily, perDay = true,
          conf = Adv.Conf(sells), why = ("composants %s (bruts ou achetés), rapporte %s net : +%s par fabrication ; %s"):format(money(e.base),
            money(e.value or 0), money(e.profit), sells.why), mode = "craft" })
  end
  local farm = Adv.FarmTargets()
  table.sort(farm, function(a, b) return a.rank > b.rank end)
  for i = 1, math.min(Adv.TOP.farm, #farm) do
    local e = farm[i]
    if e.conf == "prouvé" and e.mine then
      add({ kind = "farm", id = e.id, s = e.s, qty = math.floor(e.share + 0.5), price = e.post, gold = e.daily, perDay = true,
            conf = e.conf, why = ("%s : l'HV en prend ~%s/j, ta part ~%s/j à %s net"):format(e.source, rate(e.rate),
              rate(e.share), money(e.net)), mode = "farmwhat" })
    end
  end
  for _, e in ipairs(Adv.LevelNext()) do
    local label = ns.Prof.LABEL[e.prof] or e.prof
    add({ kind = "level", id = e.id, s = e.s, qty = e.rank, label = ("%s %d%s : %s"):format(label, e.rank, e.max and ("/" .. e.max) or "",
          plainName(e.id)), price = e.cost, gold = -e.perPoint, conf = "calcul",
          why = e.perPoint <= 0 and ("chaque point te rapporte %s (revente comprise)"):format(money(-e.perPoint))
            or ("%s par point (composants %s − revente %s), %.0f %% de chance par fabrication%s"):format(money(e.perPoint),
              money(e.cost or 0), money(e.value or 0), e.chance * 100, e.learnCost and (", recette à acheter " .. money(e.learnCost)) or ""),
          mode = "level" })
  end

  cache, cacheKey = out, key
  return out
end

-- « À encaisser maintenant : … » : la phrase d'en-tête de l'onglet Conseils
function Adv.Headline(rows)
  local cash, npcGold, relist, mail, daily = 0, 0, 0, 0, 0
  for _, e in ipairs(rows or Adv.Actions()) do
    if e.kind == "sell" or e.kind == "test" or e.kind == "flipsell" then cash = cash + (e.gold or 0)
    elseif e.kind == "npc" then npcGold = npcGold + (e.gold or 0)
    elseif e.kind == "relist" then relist = relist + 1
    elseif e.kind == "mail" then mail = mail + (e.gold or 0)
    elseif e.perDay then daily = daily + math.max(e.gold or 0, 0) end
  end
  local t = Adv.ReviewTotals()
  return ("À encaisser : HV ~%s · PNJ %s%s%s · à préparer ~%s/j. Bilan 30 j : %d qui marchent, %d à revoir, %d à arrêter."):format(
    money(cash), money(npcGold), mail > 0 and (" · courrier " .. money(mail)) or "",
    relist > 0 and (" · %d enchère%s à reprendre"):format(relist, relist > 1 and "s" or "") or "",
    money(daily), t.works + t.gain, t.price + t.loss, t.stop)
end
