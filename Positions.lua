-- AHLedger - Mes flips : ce que tu as acheté sur un conseil de l'onglet « Flip HV », et quand le revendre.
--
-- * Chaque conseil affiché dans « Flip HV » est retenu 24 h (prix max, revente visée, délai).
-- * Tes achats à l'HV sont relevés au moment où le jeu les confirme (achat d'une marchandise ou rachat
--   d'une enchère), quelle que soit la fenêtre qui achète : Daylight UI, Auctionator ou celle du jeu.
--   AHLedger n'achète rien : il regarde seulement ce que tu as confirmé. Un achat d'un objet conseillé
--   devient un flip suivi. Les courriers d'achat ne servent pas : leur quantité est fausse sur les piles.
-- * Les ventes lues dans tes courriers (Ledger) referment tes flips, le plus ancien d'abord.
-- * Après chaque scan (et à l'ouverture de l'HV), chaque flip ouvert reçoit un conseil : vendre maintenant
--   quand le prix d'aujourd'hui atteint la revente visée, attendre sinon. Un message dans le chat te
--   prévient quand c'est le moment.
local _, ns = ...

local Pos = {}
ns.Positions = Pos

Pos.RECO_HOURS = 24        -- un conseil vu il y a plus longtemps ne compte plus
Pos.MERGE_SECONDS = 900    -- achats du même objet à moins de 15 min : un seul flip
Pos.KEEP_DAYS = 30         -- flips refermés gardés pour le bilan
Pos.TARGET_OK = 0.98       -- prix net à 98 % de l'objectif : on vend
Pos.TARGET_HIGH = 1.10     -- 10 % au-dessus : prix haut, on vend vite
Pos.GONE_DAYS = 3          -- plus aucune unité sur toi ni en vente depuis 3 j : flip refermé (utilisé, vendu au PNJ…)
Pos.ALERT_BETTER = 1.05    -- on te reprévient si le prix de vente monte encore de 5 %

local SELL = { sell = true, high = true, late = true, drop = true }

function Pos.DB()
  local db = ns.realmDB()
  db.positions = db.positions or {}
  db.recos = db.recos or {}
  return db
end

local function charKey()
  return (UnitName("player") or "?") .. "-" .. ns.realmName()
end

-- Conseils affichés dans « Flip HV » : ce que tu as vu au moment d'acheter
function Pos.Remember(flips)
  local db, now = Pos.DB(), time()
  for id, r in pairs(db.recos) do
    if now - r.t > Pos.RECO_HOURS * 3600 then db.recos[id] = nil end
  end
  for _, f in ipairs(flips or {}) do
    db.recos[f.id] = { t = now, kind = f.kind, maxBuy = f.maxBuy, resale = f.resale, days = f.days, qty = f.qty,
                       profit = f.profit and f.qty and f.qty > 0 and f.profit / f.qty or nil }
  end
end

-- Conseil pour un objet : celui que tu as vu, sinon celui du dernier scan
local function recoFor(id)
  local db = Pos.DB()
  local r = db.recos[id]
  if r and time() - r.t <= Pos.RECO_HOURS * 3600 then return r end
  local A = ns.Analysis
  local s = A.Get(id)
  local book = ns.realmDB().book
  local f = s and book and not A.Stale() and A.FlipFor(s, ns.Scan.UnpackBook(book[id]))
  if f then
    return { t = time(), kind = f.kind, maxBuy = f.maxBuy, resale = f.resale, days = f.days, qty = f.qty,
             profit = f.qty > 0 and f.profit / f.qty or nil }
  end
end

-- Un achat confirmé par le jeu. total = prix payé pour qty unités.
function Pos.Bought(id, qty, total)
  if not (id and qty and qty > 0 and total and total > 0) then return end
  ns.rememberItem(id)
  local reco = recoFor(id)
  if ns.Tracker then ns.Tracker.LogBuy(id, qty, total, reco ~= nil) end -- suivi de tous tes achats
  if not reco then
    ns.dataVersion = (ns.dataVersion or 0) + 1
    if ns.UI then ns.UI.OnData() end
    return                               -- pas un achat conseillé : pas un flip suivi
  end
  local db, now, who = Pos.DB(), time(), charKey()
  local unit = total / qty
  -- plusieurs clics pour la même affaire : un seul flip
  for _, p in ipairs(db.positions) do
    if p.id == id and not p.done and p.who == who and now - (p.last or p.t) <= Pos.MERGE_SECONDS then
      p.unit = (p.unit * p.c + total) / (p.c + qty)
      p.c, p.last = p.c + qty, now
      Pos.Notify(p, qty, unit)
      return p
    end
  end
  local meta = AHLedgerDB.items[id]
  local p = { id = id, n = meta and meta.n, t = now, last = now, c = qty, unit = unit, who = who,
              sold = 0, rev = 0, reco = reco, scan = ns.realmDB().lastScanTime }
  db.positions[#db.positions + 1] = p
  Pos.Notify(p, qty, unit)
  return p
end

function Pos.Notify(p, qty, unit)
  local over = p.reco.maxBuy and unit > p.reco.maxBuy * 1.001
  ns.print(("Flip suivi : %d × %s à %s/u%s — objectif %s/u (%s). Onglet Marché, vue « Mes flips »."):format(
    qty, p.n or ("#" .. p.id), ns.money(unit),
    over and (" |cffff8040(au-dessus du conseil, " .. ns.money(p.reco.maxBuy) .. "/u)|r") or "",
    ns.money(p.reco.resale), p.reco.kind == "stock" and "à stocker" or "revente tout de suite"))
  ns.dataVersion = (ns.dataVersion or 0) + 1
  if ns.UI then ns.UI.OnData() end
end

-- Ventes lues dans les courriers : chaque vente postérieure à l'achat referme le flip le plus ancien
-- du même objet. Une ligne de bilan garde dans « pu » les unités déjà attribuées.
function Pos.MatchSales()
  local db = Pos.DB()
  local ledger = db.ledger or {}
  local sales = {}
  for _, e in ipairs(ledger) do
    if e.k == "sold" and e.id and (e.c or 0) > (e.pu or 0) then sales[#sales + 1] = e end
  end
  if #sales == 0 then return end
  table.sort(sales, function(a, b) return (a.t or 0) < (b.t or 0) end)
  for _, e in ipairs(sales) do
    local unitNet = ((e.g or 0) - (e.cut or 0)) / e.c
    for _, p in ipairs(db.positions) do
      local left = e.c - (e.pu or 0)
      if left <= 0 then break end
      if p.id == e.id and not p.done and (e.t or 0) >= p.t then
        local m = math.min(left, p.c - p.sold)
        if m > 0 then
          p.sold, p.rev = p.sold + m, p.rev + m * unitNet
          e.pu = (e.pu or 0) + m
          if p.sold >= p.c then p.done, p.why = e.t or time(), "vendu" end
        end
      end
    end
  end
end

-- Ce que tu as encore de cet objet sur ce personnage : sacs, banque, en vente, vendu (courrier à lire)
local function owned(id)
  local c = ns.Prof.Char()
  local bags = c.bags and c.bags[id] or 0
  local bank = c.bank and c.bank[id] or 0
  local listed, listPrice, soldWait = 0, nil, 0
  for _, a in ipairs(c.auctions and c.auctions.list or {}) do
    if a.id == id then
      if a.sold then soldWait = soldWait + a.qty
      else
        listed = listed + a.qty
        if a.unit and (not listPrice or a.unit < listPrice) then listPrice = a.unit end
      end
    end
  end
  return { bags = bags + bank, listed = listed, listPrice = listPrice, soldWait = soldWait,
           known = c.bags ~= nil, all = bags + bank + listed + soldWait }
end

-- Prix auquel tu peux vendre maintenant : juste sous l'enchère la moins chère qui n'est ni à toi,
-- ni celle que tu viens d'acheter (le scan d'avant ton achat la montre encore).
function Pos.SellPrice(p, own)
  local db = ns.realmDB()
  -- aucun carnet d'ordres (scan incomplet retiré) : pas de prix, plutôt qu'un « vends » à l'aveugle
  if not (db.book and next(db.book)) then return nil, true end
  local book = db.book and ns.Scan.UnpackBook(db.book[p.id])
  local levels = {}
  for _, l in ipairs(book and book.levels or {}) do levels[#levels + 1] = { l[1], l[2] } end
  local function take(n, maxP)
    for _, l in ipairs(levels) do
      if n <= 0 then return end
      if not maxP or l[1] <= maxP then
        local m = math.min(n, l[2])
        l[2], n = l[2] - m, n - m
      end
    end
  end
  if (db.lastScanTime or 0) <= p.t then take(p.c, (p.reco.maxBuy or p.unit) * 1.001) end
  if own.listed > 0 and own.listPrice then take(own.listed, own.listPrice + 0.5) end
  for _, l in ipairs(levels) do
    if l[2] > 0 then return math.max(1, l[1] - 1), false end
  end
  -- plus rien en vente : le prix habituel (personne ne vend en dessous)
  local s = ns.Analysis.Get(p.id)
  return s and (s.realPrice or s.price), true
end

-- Ce que rapporte une unité vendue à ce prix : la formule unique (commission et dépôts perdus déduits)
local function netAt(s, price)
  if not price then return nil end
  return (ns.Analysis.NetAt(price, s))
end
Pos.NetAt = netAt

-- Conseil pour un flip : sell / high / late / drop (vendre), wait, loss, listed, done
function Pos.Evaluate(p)
  local s = ns.Analysis.Get(p.id)
  local own = owned(p.id)
  local e = { id = p.id, p = p, s = s, name = p.n, unit = p.unit, bought = p.c, sold = p.sold }
  e.left = p.c - p.sold
  e.age = (time() - p.t) / 86400
  e.expect = math.max(p.reco.days or 1, 0.5)
  if p.done then
    e.verdict = "done"
    e.gain = p.rev - p.unit * p.sold
    e.why = p.why == "vendu" and ("vendu %s/u net"):format(ns.money(p.sold > 0 and p.rev / p.sold or 0))
      or (p.why or "refermé")
    return e
  end
  -- unités parties sans vente à l'HV (utilisées, vendues au PNJ…) : on ne compte que ce que tu as encore
  if own.known and p.who == charKey() then e.left = math.min(e.left, own.all) end
  e.listed = math.min(own.listed, e.left)
  e.sellAt, e.empty = Pos.SellPrice(p, own)
  e.target = p.reco.resale
  local netNow, netTarget = netAt(s, e.sellAt), netAt(s, e.target)
  e.netNow = netNow
  e.gainU = netNow and netNow - p.unit
  e.gain = e.gainU and e.gainU * math.max(e.left, 0)
  e.vsTarget = netNow and netTarget and netTarget > 0 and netNow / netTarget - 1

  if e.left <= 0 then
    e.verdict, e.why = "gone", own.soldWait > 0 and "vendu : récupère l'or au courrier" or "plus rien sur toi"
  elseif e.listed >= e.left then
    if own.listPrice and e.sellAt and not e.empty and e.sellAt < own.listPrice - 0.5 then
      e.verdict, e.why = "undercut", ("sous-coté : remets à %s/u"):format(ns.money(e.sellAt))
    else
      e.verdict, e.why = "listed", ("en vente à %s/u"):format(ns.money(own.listPrice))
    end
  elseif not netNow then
    e.verdict, e.why = "wait", "pas de prix : rescanne"
  elseif netTarget and netNow >= netTarget * Pos.TARGET_HIGH and e.gainU > 0 then
    e.verdict, e.why = "high", ("prix haut : %s au-dessus de l'objectif"):format(("%+.0f %%"):format(e.vsTarget * 100))
  elseif netTarget and netNow >= netTarget * Pos.TARGET_OK and e.gainU > 0 then
    e.verdict, e.why = "sell", "objectif atteint"
  elseif e.gainU > 0 and s and s.trend and s.trend <= -0.03 then
    e.verdict, e.why = "drop", ("le prix baisse (%+.0f %%/j) : prends le gain"):format(s.trend * 100)
  elseif e.gainU > 0 and e.age > e.expect * 1.5 + 0.5 then
    e.verdict, e.why = "late", ("délai passé (%.1f j prévus) : petit gain"):format(e.expect)
  elseif e.gainU <= 0 and e.age > e.expect * 2 + 1 then
    local vend = AHLedgerDB.items[p.id] and AHLedgerDB.items[p.id].s or 0
    e.verdict = "loss"
    e.why = vend > netNow and ("pas remonté : PNJ %s/u > HV"):format(ns.money(vend))
      or "pas remonté : vends à perte ou garde"
  else
    e.verdict = "wait"
    e.why = e.vsTarget and ("objectif %s/u (%+.0f %%)"):format(ns.money(e.target), e.vsTarget * 100)
      or ("objectif %s/u"):format(ns.money(e.target))
  end
  e.action = SELL[e.verdict] and e.left - e.listed or nil
  return e
end

-- Les flips sortis sans vente (plus rien sur toi depuis GONE_DAYS) et les vieux flips refermés
local function tidy()
  local db, now, who = Pos.DB(), time(), charKey()
  local keep = {}
  for _, p in ipairs(db.positions) do
    if not p.done and p.who == who then
      local own = owned(p.id)
      if own.known and own.all == 0 then
        p.goneSince = p.goneSince or now
        if now - p.goneSince > Pos.GONE_DAYS * 86400 then p.done, p.why = now, "sorti sans vente HV" end
      else
        p.goneSince = nil
      end
    end
    if not (p.done and now - p.done > Pos.KEEP_DAYS * 86400) then keep[#keep + 1] = p end
  end
  db.positions = keep
end

function Pos.Rows()
  Pos.MatchSales()
  tidy()
  local out = {}
  for _, p in ipairs(Pos.DB().positions) do out[#out + 1] = Pos.Evaluate(p) end
  return out
end

-- Résumé : flips ouverts, or engagé, gain réalisé
function Pos.Totals(rows)
  local t = { open = 0, invested = 0, realized = 0, toSell = 0 }
  for _, e in ipairs(rows or Pos.Rows()) do
    if e.verdict == "done" then
      t.realized = t.realized + (e.gain or 0)
    else
      t.open = t.open + 1
      t.invested = t.invested + e.unit * math.max(e.left, 0)
      if e.action and e.action > 0 then t.toSell = t.toSell + 1 end
    end
  end
  return t
end

function Pos.Close(p, why)
  p.done, p.why = time(), why or "refermé à la main"
  ns.dataVersion = (ns.dataVersion or 0) + 1
  if ns.UI then ns.UI.OnData() end
end

-- Te prévient dans le chat quand un flip est bon à vendre. Une fois par scan au plus, et de nouveau
-- seulement si le conseil change ou si le prix monte encore.
function Pos.Check(force)
  local db = ns.realmDB()
  if not (db.positions and #db.positions > 0) then return 0 end
  local scan = db.lastScanTime or 0
  local n = 0
  for _, e in ipairs(Pos.Rows()) do
    local p = e.p
    if e.action and e.action > 0 then
      local a = p.alert
      local fresh = force or not a or a.scan ~= scan
      local better = not a or a.v ~= e.verdict or (e.sellAt or 0) > (a.price or 0) * Pos.ALERT_BETTER
      if fresh and better then
        p.alert = { scan = scan, v = e.verdict, price = e.sellAt }
        n = n + 1
        ns.print(("|cff40ff40Vends maintenant|r %d × %s à %s/u → gain %s (%s). Clic dans « Mes flips » pour le chercher."):format(
          e.action, e.name or ("#" .. e.id), ns.money(e.sellAt), ns.money(e.gainU * e.action), e.why))
      end
    elseif e.verdict == "undercut" then
      local a = p.alert
      if not a or a.scan ~= scan or a.v ~= "undercut" then
        p.alert = { scan = scan, v = "undercut", price = e.sellAt }
        n = n + 1
        ns.print(("%s : ton enchère est sous-cotée, remets-la à %s/u."):format(e.name or ("#" .. e.id), ns.money(e.sellAt)))
      end
    end
  end
  if n > 0 and UIErrorsFrame and UIErrorsFrame.AddMessage then
    UIErrorsFrame:AddMessage(("AHLedger : %d flip(s) à vendre maintenant"):format(n), 0.25, 1, 0.25)
  end
  return n
end

-- Relevé des achats : on suit les appels d'achat du jeu (sans rien changer à ce qu'ils font)
-- et leur confirmation par le serveur.
local pending, items, searched = nil, {}, {}
function Pos.HookAH()
  local AH = C_AuctionHouse
  if Pos.hooked or not (AH and hooksecurefunc) then return end
  Pos.hooked = true
  if AH.StartCommoditiesPurchase then
    hooksecurefunc(AH, "StartCommoditiesPurchase", function(itemID, qty)
      ns.safe("achat (début)", function() pending = { id = itemID, qty = qty } end)
    end)
  end
  if AH.ConfirmCommoditiesPurchase then
    hooksecurefunc(AH, "ConfirmCommoditiesPurchase", function(itemID, qty)
      ns.safe("achat (confirmation)", function()
        if pending and pending.id == itemID then pending.sent, pending.qty = true, qty or pending.qty end
      end)
    end)
  end
  if AH.PlaceBid and AH.GetItemSearchResultInfo then
    hooksecurefunc(AH, "PlaceBid", function(auctionID, amount) ns.safe("achat (rachat)", function()
      for _, key in ipairs(searched) do
        local n = AH.GetNumItemSearchResults and AH.GetNumItemSearchResults(key) or 0
        for i = 1, n do
          local r = AH.GetItemSearchResultInfo(key, i)
          if type(r) == "table" and r.auctionID == auctionID then
            -- seul un rachat est un achat (une simple enchère peut être dépassée)
            if r.buyoutAmount and r.buyoutAmount > 0 and amount >= r.buyoutAmount then
              items[auctionID] = { id = key.itemID, qty = r.quantity or 1, total = amount }
            end
            return
          end
        end
      end
    end) end)
  end
end

ns.on("COMMODITY_PRICE_UPDATED", function(unit, total)
  if pending then pending.unit, pending.total = unit, total end
end)
ns.on("COMMODITY_PURCHASE_SUCCEEDED", function()
  local p = pending
  pending = nil
  if p and p.sent then
    Pos.Bought(p.id, p.qty, p.total or (p.unit and p.unit * p.qty))
  end
end)
ns.on("COMMODITY_PURCHASE_FAILED", function() pending = nil end)
ns.on("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
  if type(itemKey) ~= "table" or not itemKey.itemID then return end
  for i = #searched, 1, -1 do
    if searched[i].itemID == itemKey.itemID then table.remove(searched, i) end
  end
  table.insert(searched, 1, itemKey)
  if #searched > 10 then searched[#searched] = nil end
end)
ns.on("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
  local b = items[auctionID]
  items[auctionID] = nil
  if b then Pos.Bought(b.id, b.qty, b.total) end
end)
ns.on("PLAYER_LOGIN", function() Pos.HookAH() end)
ns.on("AUCTION_HOUSE_SHOW", function()
  Pos.HookAH()
  -- les prix du dernier scan, le temps de relire tes enchères
  C_Timer.After(6, function() ns.safe("mes flips", Pos.Check, true) end)
end)
ns.on("AUCTION_HOUSE_CLOSED", function() pending, items = nil, {} end)
