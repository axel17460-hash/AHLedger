-- AHLedger - Suivi de tes achats et ventes : es-tu gagnant ?
--
-- * Achats : relevés au moment où le jeu confirme l'achat (Positions.lua), quantité et prix exacts.
--   Les courriers d'achat ne servent que pour les achats d'avant ce relevé (leur quantité est souvent
--   fausse sur les piles : elle est alors estimée d'après le prix du marché, marquée « ≈ »).
-- * Ventes et expirations : lues dans tes courriers d'HV (Ledger.lua).
-- * Achats chez le marchand (Vendor.lua) et fabrications (Professions.lua) : relevés à ton clic, pour le
--   prix de revient (voir T.Compute).
-- * Chaque vente est rapprochée de tes achats et fabrications du même objet, le plus ancien d'abord :
--   gain = vente nette (commission déduite) − prix de revient. Une vente d'un objet que tu n'as ni
--   acheté ni fabriqué (farm, loot) n'a pas de coût : elle est comptée à part.
-- * Ce que tu as acheté et pas encore vendu est valorisé au prix auquel tu peux le vendre maintenant :
--   résultat = gain réalisé + (valeur de ton stock − ce qu'il t'a coûté) − dépôts perdus.
-- * Une unité achetée qui n'est plus sur toi ni en vente (utilisée, vendue au PNJ) sort à son prix
--   d'achat : ni gagnée, ni perdue.
local _, ns = ...

local T = {}
ns.Tracker = T

T.KEEP_DAYS = 60
T.BUY_KEEP = 1500 -- achats gardés au plus (les plus récents) : ceux du marchand se font clic par clic
T.MAIL_DEDUP = 3 * 86400   -- un courrier d'achat dans les 3 j après un achat relevé du même objet : le même achat
T.MAIL_SUSPECT = 3         -- prix /u du courrier > 3× le prix du marché : quantité fausse, on l'estime

function T.DB()
  local db = ns.realmDB()
  db.buys = db.buys or {}
  db.ledger = db.ledger or {}
  return db
end

-- Un achat confirmé par le jeu (toutes les fenêtres d'achat de l'HV, et le marchand : w = "PNJ").
-- reco = conseillé par Flip HV.
function T.LogBuy(id, qty, total, reco, w)
  local db, now = T.DB(), time()
  local meta = AHLedgerDB.items[id]
  db.buys[#db.buys + 1] = { t = now, id = id, n = meta and meta.n, c = qty, g = total, r = reco and true or nil, w = w }
  local keep, limit = {}, now - T.KEEP_DAYS * 86400
  for _, b in ipairs(db.buys) do if b.t >= limit then keep[#keep + 1] = b end end
  while #keep > T.BUY_KEEP do table.remove(keep, 1) end
  db.buys = keep
  ns.dataVersion = (ns.dataVersion or 0) + 1
end

-- Une fabrication relevée (Professions.lua) : made × id reçus, composants consommés use = { [id] = qté },
-- val = { [id] = valeur brute /u au moment de fabriquer } : ce que vaut un composant qui ne vient pas
-- d'un achat relevé (farmé, looté), c'est-à-dire ce qu'il t'aurait rapporté vendu brut.
T.CRAFT_KEEP = 400 -- fabrications gardées au plus (les plus récentes), sur KEEP_DAYS jours
function T.LogCraft(id, made, use, val)
  local db, now = T.DB(), time()
  db.crafts = db.crafts or {}
  local meta = AHLedgerDB.items[id]
  db.crafts[#db.crafts + 1] = { t = now, id = id, n = meta and meta.n, c = made, u = use, v = val }
  local keep, limit = {}, now - T.KEEP_DAYS * 86400
  for _, e in ipairs(db.crafts) do if e.t >= limit then keep[#keep + 1] = e end end
  while #keep > T.CRAFT_KEEP do table.remove(keep, 1) end
  db.crafts = keep
  ns.dataVersion = (ns.dataVersion or 0) + 1
end

local function keyOf(e) return e.id or e.n or "?" end

-- Quantité d'un courrier d'achat : estimée quand le prix /u qu'elle donne est absurde
local function mailCount(e)
  local s = e.id and ns.Analysis.Get(e.id)
  local ref = s and (s.price or s.avg7)
  local c = math.max(e.c or 1, 1)
  if ref and ref > 0 and (e.g or 0) / c > ref * T.MAIL_SUSPECT then
    return math.max(1, math.floor(e.g / ref + 0.5)), true
  end
  return c, false
end

-- Ce que vaut une unité de ton stock maintenant : la formule unique de Decide (Decide.RawValue :
-- le meilleur entre le rachat PNJ et l'HV au prix « juste », net, si l'objet se vend)
local function netNow(id)
  if not ns.Analysis.Get(id) then return nil end
  return ns.Decide.RawValue(id)
end

local function ownedNow(id)
  local c = ns.Prof.Char()
  if not c.bags then return nil end
  local n = (c.bags[id] or 0) + (c.bank and c.bank[id] or 0)
  for _, a in ipairs(c.auctions and c.auctions.list or {}) do
    if a.id == id then n = n + a.qty end
  end
  return n
end

-- Le bilan réel (l'or vraiment gagné) = ventes de farm + gain des reventes + valeur ajoutée par tes
-- fabrications − dépôts perdus. Le stock (acheté à l'HV ou fabriqué) pas encore vendu est à part :
-- c'est un gain latent, au prix du marché, pas encore encaissé.
--
-- Prix de revient (1.0 phase 3) : chaque unité entre dans un lot, sorti le plus ancien d'abord.
--   achetée (HV ou marchand) : le prix payé ;
--   fabriquée (relevée) : ses composants à leur propre prix de revient (leurs lots), et ceux qui ne
--     viennent d'aucun achat (farmés) à ce qu'ils valaient vendus bruts au moment de fabriquer.
-- Un lot fabriqué garde à part l'or vraiment payé (paid) : à la vente, net − prix de revient est la
-- valeur ajoutée par la fabrication, et la valeur brute de tes propres composants compte en farm.
-- Ainsi farm + revente + fabrication = net − or payé, toujours.
--
-- Tout le calcul. Renvoie journal (lignes chronologiques), objets achetés ou fabriqués (par objet),
-- totaux, tous les objets (par id ou nom) sur days jours (ou depuis from, heure du jeu, si donné), et
-- le prix de revient de ce que tu as encore : basis[id] = { units, cost, paid, bought, boughtCost,
-- crafted, craftCost }.
function T.Compute(days, from)
  days = days or ns.Ledger.DAYS
  local db = T.DB()
  local limit = from or (time() - days * 86400)
  local ev = {}
  for _, b in ipairs(db.buys) do
    ev[#ev + 1] = { t = b.t, k = "buy", id = b.id, n = b.n, c = b.c, g = b.g, reco = b.r,
                    src = b.w == "PNJ" and "PNJ" or "live" }
  end
  for _, e in ipairs(db.crafts or {}) do
    if e.id and (e.c or 0) > 0 then
      ev[#ev + 1] = { t = e.t, k = "craft", id = e.id, n = e.n, c = e.c, g = 0, use = e.u or {}, val = e.v or {} }
    end
  end
  for _, e in ipairs(db.ledger) do
    if e.k == "bought" then
      local dup = false
      for _, b in ipairs(db.buys) do
        -- un courrier d'achat ne vient que de l'HV : un achat au marchand n'en a pas
        if b.w ~= "PNJ" and b.id and b.id == e.id and e.t >= b.t - 60 and e.t - b.t <= T.MAIL_DEDUP then dup = true; break end
      end
      if not dup then
        local c, est = mailCount(e)
        ev[#ev + 1] = { t = e.t, k = "buy", id = e.id, n = e.n, c = c, g = e.g or 0, est = est, src = "mail" }
      end
    elseif e.k == "sold" then
      ev[#ev + 1] = { t = e.t, k = "sell", id = e.id, n = e.n, c = math.max(e.c or 1, 1), g = e.g or 0, cut = e.cut or 0 }
    elseif e.k == "expired" then
      local dep = (e.id and ns.Decide.VendorPrice(e.id) or 0) * ns.Analysis.DEPOSIT_RATE * math.max(e.c or 1, 1)
      ev[#ev + 1] = { t = e.t, k = "exp", id = e.id, n = e.n, c = math.max(e.c or 1, 1), g = 0, dep = dep }
    end
  end
  -- même heure : la fabrication après l'achat de ses composants, la vente après la fabrication
  local ORDER = { buy = 1, craft = 2, sell = 3, exp = 3 }
  table.sort(ev, function(a, b)
    if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) < (b.t or 0) end
    return ORDER[a.k] < ORDER[b.k]
  end)

  local lots, items, journal = {}, {}, {}
  local tot = { spent = 0, spentPNJ = 0, revenue = 0, gain = 0, craft = 0, farm = 0, lostDep = 0, stockCost = 0,
                stockValue = 0, buys = 0, sells = 0, wins = 0, losses = 0, crafts = 0 }
  local running = 0 -- bilan réel cumulé (farm compris)
  local function item(key, id, name)
    local it = items[key]
    if not it then
      it = { id = id, name = name, bought = 0, spent = 0, boughtPNJ = 0, spentPNJ = 0, crafted = 0, sold = 0,
             soldFromBuys = 0, craftSold = 0, revenue = 0, gain = 0, craftGain = 0, farm = 0, lostDep = 0, left = 0,
             leftCost = 0, leftValue = 0, gone = 0, usedInCrafts = 0 }
      items[key] = it
    end
    return it
  end
  local function queue(key)
    local q = lots[key]
    if not q then q = {}; lots[key] = q end
    return q
  end
  for _, e in ipairs(ev) do
    local k, inWin = keyOf(e), (e.t or 0) >= limit
    local q = queue(k)
    local it = item(k, e.id, e.n)
    local row = { t = e.t, kind = e.k, id = e.id, n = e.n, c = e.c, total = e.g, unit = e.c > 0 and e.g / e.c or 0,
                  est = e.est, reco = e.reco, src = e.src }
    if e.k == "buy" then
      local pnj = e.src == "PNJ"
      q[#q + 1] = { left = e.c, unit = e.g / e.c, paid = e.g / e.c, pnj = pnj or nil }
      if e.est then it.est = true end
      if inWin then
        if pnj then
          it.boughtPNJ, it.spentPNJ, tot.spentPNJ = it.boughtPNJ + e.c, it.spentPNJ + e.g, tot.spentPNJ + e.g
        else
          it.bought, it.spent, tot.spent = it.bought + e.c, it.spent + e.g, tot.spent + e.g
        end
        tot.buys = tot.buys + 1
      end
    elseif e.k == "craft" then
      -- les composants sortent de leurs lots (le plus ancien d'abord) ; ce qui ne vient d'aucun lot
      -- (farmé, looté, d'avant le relevé) vaut ce qu'il valait vendu brut au moment de fabriquer
      local paid, own = 0, 0
      for rid, used in pairs(e.use) do
        local rq = queue(rid)
        local left = used
        while left > 0 and rq[1] do
          local l = rq[1]
          local m = math.min(left, l.left)
          paid, own = paid + m * l.paid, own + m * (l.unit - l.paid)
          left, l.left = left - m, l.left - m
          if l.left <= 0 then table.remove(rq, 1) end
        end
        own = own + left * math.max(e.val[rid] or 0, 0)
        local rit = item(rid, rid, AHLedgerDB.items[rid] and AHLedgerDB.items[rid].n)
        rit.usedInCrafts = rit.usedInCrafts + used
      end
      q[#q + 1] = { left = e.c, unit = (paid + own) / e.c, paid = paid / e.c, craft = true }
      row.total, row.unit, row.paid, row.own = paid + own, (paid + own) / e.c, paid, own
      if inWin then it.crafted, tot.crafts = it.crafted + e.c, tot.crafts + 1 end
    elseif e.k == "sell" then
      local net = e.g - e.cut
      local unitNet = net / e.c
      local left = e.c
      local buyCost, buyN, craftCost, craftN, ownValue = 0, 0, 0, 0, 0
      while left > 0 and q[1] do
        local l = q[1]
        local m = math.min(left, l.left)
        if l.craft then
          craftCost, craftN, ownValue = craftCost + m * l.unit, craftN + m, ownValue + m * (l.unit - l.paid)
        else
          buyCost, buyN = buyCost + m * l.unit, buyN + m
        end
        left, l.left = left - m, l.left - m
        if l.left <= 0 then table.remove(q, 1) end
      end
      row.net, row.matched = net, buyN + craftN
      row.gain = buyN > 0 and (buyN * unitNet - buyCost) or nil
      row.craftGain = craftN > 0 and (craftN * unitNet - craftCost) or nil
      local farm = (left > 0 and left * unitNet or 0) + ownValue
      row.farm = (left > 0 or ownValue ~= 0) and farm or nil
      row.farmN = left
      if inWin then
        it.sold, it.soldFromBuys, it.craftSold, it.revenue = it.sold + e.c, it.soldFromBuys + buyN,
          it.craftSold + craftN, it.revenue + net
        tot.revenue, tot.sells = tot.revenue + net, tot.sells + 1
        if row.gain then
          it.gain, tot.gain = it.gain + row.gain, tot.gain + row.gain
          if row.gain >= 0 then tot.wins = tot.wins + 1 else tot.losses = tot.losses + 1 end
        end
        if row.craftGain then it.craftGain, tot.craft = it.craftGain + row.craftGain, tot.craft + row.craftGain end
        if row.farm then it.farm, tot.farm = it.farm + row.farm, tot.farm + row.farm end
        row.effect = (row.gain or 0) + (row.craftGain or 0) + (row.farm or 0)
        running = running + row.effect
      end
    else
      row.gain = -e.dep
      if inWin then
        it.lostDep, tot.lostDep = it.lostDep + e.dep, tot.lostDep + e.dep
        running = running - e.dep
      end
      row.effect = -e.dep
    end
    row.running = inWin and running or nil
    if inWin then
      journal[#journal + 1] = row
      row.seq = #journal
    end
  end

  -- ce qu'il te reste : sorti sans vente HV (utilisé, mangé, vendu au PNJ) au prix de revient, le plus
  -- ancien d'abord : ni gagné, ni perdu. Le reste fait ton prix de revient ; le stock acheté à l'HV ou
  -- fabriqué est valorisé au prix auquel tu peux le vendre maintenant (les achats au marchand sont des
  -- fournitures : prix de revient seulement, pas de stock latent)
  local basis = {}
  for k, q in pairs(lots) do
    local it = items[k]
    local left = 0
    for _, l in ipairs(q) do left = left + l.left end
    local own = left > 0 and it and it.id and ownedNow(it.id)
    if own and own < left then
      local drop = left - own
      it.gone = drop
      while drop > 0 and q[1] do
        local m = math.min(drop, q[1].left)
        q[1].left, drop = q[1].left - m, drop - m
        if q[1].left <= 0 then table.remove(q, 1) end
      end
    end
    local b = { units = 0, cost = 0, paid = 0, bought = 0, boughtCost = 0, crafted = 0, craftCost = 0 }
    local stockN, stockCost = 0, 0
    for _, l in ipairs(q) do
      b.units, b.cost, b.paid = b.units + l.left, b.cost + l.left * l.unit, b.paid + l.left * l.paid
      if l.craft then b.crafted, b.craftCost = b.crafted + l.left, b.craftCost + l.left * l.unit
      else b.bought, b.boughtCost = b.bought + l.left, b.boughtCost + l.left * l.unit end
      if not l.pnj then stockN, stockCost = stockN + l.left, stockCost + l.left * l.unit end
    end
    if b.units > 0 and it and it.id then basis[it.id] = b end
    if stockN > 0 and it then
      it.left, it.leftCost = stockN, stockCost
      local nn = it.id and netNow(it.id)
      it.leftValue = nn and math.max(nn, 0) * stockN or stockCost
      it.priced = nn ~= nil
      tot.stockCost, tot.stockValue = tot.stockCost + stockCost, tot.stockValue + it.leftValue
    end
  end

  local list = {}
  for _, it in pairs(items) do
    it.unrealized = it.leftValue - it.leftCost
    it.result = it.gain + it.craftGain + it.unrealized - it.lostDep
    it.real = it.farm + it.gain + it.craftGain - it.lostDep  -- or vraiment gagné sur cet objet
    it.withStock = it.real + it.unrealized
    local nb = it.bought + it.boughtPNJ
    it.avgBuy = nb > 0 and (it.spent + it.spentPNJ) / nb or nil
    it.avgSell = it.sold > 0 and it.revenue / it.sold or nil
    it.farmSold = it.sold - it.soldFromBuys - it.craftSold
    -- un objet que tu n'as fait que vendre (farm), ou acheté au marchand pour toi (fournitures), n'est
    -- pas un achat-revente : il reste dans le journal
    if it.bought > 0 or it.left > 0 or it.soldFromBuys > 0 or it.craftSold > 0 then list[#list + 1] = it end
  end
  tot.unrealized = tot.stockValue - tot.stockCost
  tot.result = tot.gain + tot.craft + tot.unrealized - tot.lostDep
  tot.real = tot.farm + tot.gain + tot.craft - tot.lostDep
  tot.withStock = tot.real + tot.unrealized
  tot.expired = 0
  for _, r in ipairs(journal) do if r.kind == "exp" then tot.expired = tot.expired + 1 end end
  return journal, list, tot, items, basis
end

-- Journal lisible : les lignes du même objet, de même nature, dans la même minute, en une seule
-- (« Simple Wildflowers × 6 enchères »). Ordre chronologique gardé (seq, celui de la dernière ligne
-- regroupée) : le tri par date ne mélange plus les lignes de même heure, et le cumul se lit d'une
-- ligne à l'autre (à une minute près quand un autre objet s'intercale dans un groupe).
function T.Journal(journal)
  local out, open = {}, {}
  for _, r in ipairs(journal) do
    -- même minute, même objet, même nature : regroupées même si d'autres lignes s'intercalent
    local k = table.concat({ math.floor((r.t or 0) / 60), r.kind, tostring(keyOf(r)), tostring(r.src),
                             tostring(r.reco) }, "|")
    local last = open[k]
    if last then
      last.lines = last.lines + 1
      last.c, last.total = last.c + r.c, (last.total or 0) + (r.total or 0)
      if r.net then last.net = (last.net or 0) + r.net end
      if r.gain then last.gain = (last.gain or 0) + r.gain end
      if r.farm then last.farm = (last.farm or 0) + r.farm end
      if r.craftGain then last.craftGain = (last.craftGain or 0) + r.craftGain end
      if r.paid then last.paid, last.own = (last.paid or 0) + r.paid, (last.own or 0) + (r.own or 0) end
      last.farmN = (last.farmN or 0) + (r.farmN or 0)
      last.matched = (last.matched or 0) + (r.matched or 0)
      last.effect = (last.effect or 0) + (r.effect or 0)
      last.est = last.est or r.est
      last.t, last.running, last.seq = r.t, r.running, r.seq
      last.unit = last.c > 0 and last.total / last.c or 0
    else
      last = {}
      for kk, v in pairs(r) do last[kk] = v end
      last.lines = 1
      out[#out + 1] = last
      open[k] = last
    end
  end
  return out
end

-- Séparateurs de jour pour le journal : bilan réel du jour et cumul en fin de journée.
-- seq = dernier seq du jour + 0,5 : en tri par date décroissante, le séparateur coiffe sa journée.
function T.Days(journal)
  local out, cur = {}, nil
  for _, r in ipairs(journal) do
    local d = date("%Y-%m-%d", r.t)
    if not cur or cur.day ~= d then
      cur = { kind = "day", day = d, t = r.t, effect = 0, lines = 0 }
      out[#out + 1] = cur
    end
    cur.effect = cur.effect + (r.effect or 0)
    cur.lines = cur.lines + 1
    cur.running, cur.seq, cur.t = r.running, (r.seq or 0) + 0.5, r.t
  end
  return out
end

-- Le calcul sur KEEP_DAYS, gardé tant que rien ne change (données, sacs) : lu à chaque décision
local keepCache, keepKey
local function keep()
  local key = (ns.dataVersion or 0) .. ":" .. (ns.bagVersion or 0)
  if keepKey ~= key or not keepCache then
    keepCache, keepKey = { T.Compute(T.KEEP_DAYS) }, key
  end
  return keepCache
end

-- Tes reventes réelles (achats puis ventes, le plus ancien d'abord), pour les flips :
-- [id] = { units = revendues, profit = gain net /u }
function T.Holds()
  local list = keep()[2]
  local out = {}
  for _, it in ipairs(list) do
    if it.id and it.soldFromBuys > 0 then out[it.id] = { units = it.soldFromBuys, profit = it.gain / it.soldFromBuys } end
  end
  return out
end

-- Prix de revient de ce que tu as encore (achats et fabrications relevés, voir T.Compute) :
-- [id] = { units, cost, paid, bought, boughtCost, crafted, craftCost } (coûts en tout, pas /u).
-- À lire, pas à modifier (gardé en cache).
function T.CostBasis()
  return keep()[5]
end

-- « 30 j : bilan réel +12 po » : une phrase pour le chat (/ahl), mêmes définitions que l'onglet Bilan
function T.Headline(tot, days)
  local function sg(v) return (v >= 0 and "+" or "-") .. ns.money(math.abs(v)) end
  local r = tot.real
  local col = r >= 0 and "|cff40ff40" or "|cffff5050"
  return ("%d j : bilan réel %s%s|r = ventes de farm %s + achat-revente %s (%d gagnantes, %d perdantes) + fabrication %s − dépôts perdus %s · en plus, stock pas encore vendu : %s (prix de revient %s, vaut %s)."):format(
    days or ns.Ledger.DAYS, col, sg(r), sg(tot.farm), sg(tot.gain), tot.wins, tot.losses, sg(tot.craft),
    ns.money(tot.lostDep), sg(tot.unrealized), ns.money(tot.stockCost), ns.money(tot.stockValue))
end

function T.Report()
  local _, _, tot = T.Compute()
  ns.print(T.Headline(tot))
end
