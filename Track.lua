-- AHLedger - Fiabilité des conseils : chaque conseil (Flip HV, Achat PNJ, artisanat à revendre à l'HV,
-- conseils des sacs « Vendre HV » et « PNJ ») est noté au scan où il apparaît, puis vérifié sur les
-- scans suivants, pendant son délai :
--   * prix tenu : le prix auquel tu aurais pu revendre (enchère la moins chère restante, hors unités
--     que le conseil t'aurait fait acheter) atteint-il le prix de revente annoncé ?
--   * écoulé : le marché a-t-il acheté au moins ta quantité à ce prix ou plus (enchères disparues
--     entre deux scans, donc estimé ; les relistes repérés par Scan.Diff sont écartés) ?
--   Réussi = prix tenu ET écoulé. Bénéfice constaté = quantité × net du prix tenu − coût.
--   Artisanat : coût = composants ; sacs « Vendre HV » : coût = ce que le marchand t'aurait payé.
--   Sacs « PNJ » : le conseil est faux si l'HV aurait clairement payé plus (prix tenu et écoulé au-dessus
--   du rachat PNJ + Bags.SAME_BAND) ; « bénéfice constaté » = or manqué (négatif) dans ce cas.
--   Pas suivis : « Garder », « Attendre » et « Fabriquer » (pas de prix de revente à vérifier).
-- Et si tu l'as suivi (achat de l'objet dans les 24 h, d'après tes courriers d'HV) : gain réel de
-- tes reventes, achat par achat (premier acheté, premier vendu).
local _, ns = ...

local Track = {}
ns.Track = Track

Track.FOLLOW_SECS = 86400     -- un achat dans les 24 h qui suivent le conseil = conseil suivi
Track.HORIZON = { now = 3, vendor = 3, stock = 14, craft = 3, bag = 3 } -- jours de vérification (à stocker : selon les rebonds connus)
Track.MAX_QTY = 20            -- artisanat et sacs : on vérifie au plus 20 unités (une pile)
Track.HELD = 0.97             -- prix tenu : revente constatée à 3 % près du prix annoncé
Track.SOLD_AT = 0.95          -- écoulé : unités parties à au moins 95 % du prix de revente
Track.KEEP_DAYS = 90

Track.GROUPS = {
  { key = "now", label = "Flip HV tout de suite" },
  { key = "stock", label = "Flip HV à stocker" },
  { key = "stockTest", label = "Flip HV à stocker (à tester)" },
  { key = "vendor", label = "Achat PNJ → HV" },
  { key = "vendorTest", label = "Achat PNJ → HV (à tester)" },
  { key = "craft", label = "Artisanat → HV" },
  { key = "bagAH", label = "Sacs : vendre à l'HV" },
  { key = "bagNPC", label = "Sacs : vendre au PNJ" },
}

function Track.DB(db)
  db = db or ns.realmDB()
  db.track = db.track or {}
  local t = db.track
  t.open = t.open or {}
  t.done = t.done or {}
  return t
end

local function net(p) return p * (1 - ns.Analysis.AH_CUT) end

local function median(t)
  if #t == 0 then return nil end
  local s = {}
  for i, v in ipairs(t) do s[i] = v end
  table.sort(s)
  local m = (#s + 1) / 2
  return (s[math.floor(m)] + s[math.ceil(m)]) / 2
end

-- Prix auquel tu aurais pu revendre à ce scan : enchère la moins chère restante, après avoir retiré
-- les unités que le conseil t'aurait fait acheter (au plus qty, au prix d'achat maxi ou moins).
-- nil = plus rien en vente.
function Track.Achievable(rec, book)
  if not (book and book.levels) then return nil end
  -- flips : tu achètes d'abord les unités conseillées, ta revente se place derrière
  local skip = (rec.k == "now" or rec.k == "stock") and rec.qty or 0
  for _, l in ipairs(book.levels) do
    if skip > 0 and l[1] <= rec.buy then
      local s = math.min(skip, l[2])
      skip = skip - s
      if s < l[2] then return l[1] end
    else
      return l[1]
    end
  end
end

-- Nouveau conseil à suivre
local function fromFlip(f, now)
  local g = f.kind == "stock" and (f.known and "stock" or "stockTest") or "now"
  local days = Track.HORIZON.now
  if f.kind == "stock" then
    days = f.known and math.min(Track.HORIZON.stock, math.max(3, (f.slow or f.wait or 7) + 2)) or Track.HORIZON.stock
  end
  return { id = f.id, k = f.kind, g = g, t = now, till = now + days * 86400, qty = f.qty, buy = f.maxBuy,
           cost = f.cost, resale = f.resale, expect = f.profit, n = 0, held = {}, sold = 0 }
end

local function fromVendor(e, now)
  local qty = e.reliable and math.max(1, math.ceil(e.vol or 1)) or (e.testQty or 1)
  if e.lim and e.lim > 0 then qty = math.min(qty, e.lim) end
  return { id = e.id, k = "vendor", g = e.reliable and "vendor" or "vendorTest", t = now,
           till = now + Track.HORIZON.vendor * 86400, qty = qty, buy = e.buy, cost = qty * e.buy,
           resale = e.s.price, expect = qty * e.margin, n = 0, held = {}, sold = 0 }
end

-- Artisanat rentable à revendre à l'HV : quantité vendable en un jour, au prix du marché
local function fromCraft(e, now)
  local made = e.made or 1
  local qty = math.min(Track.MAX_QTY, math.max(made, math.ceil((e.vol or 0) * made)))
  return { id = e.id, k = "craft", g = "craft", t = now, till = now + Track.HORIZON.craft * 86400, qty = qty,
           cost = qty / made * e.cost, resale = e.s.price, expect = qty / made * e.profit, n = 0, held = {}, sold = 0 }
end

-- Conseil des sacs : « Vendre HV » au prix conseillé, ou « PNJ » (l'HV ne vaut pas la peine)
local function fromBag(e, now)
  local cut = ns.Analysis.AH_CUT
  local till = now + Track.HORIZON.bag * 86400
  if e.action == "Vendre HV" then
    local qty = math.min(Track.MAX_QTY, e.postQty or e.count or 1)
    return { id = e.id, k = "bagAH", g = "bagAH", t = now, till = till, qty = qty, cost = qty * (e.vendor or 0),
             resale = e.post, expect = qty * (e.unit - (e.vendor or 0)), n = 0, held = {}, sold = 0 }
  end
  -- PNJ : prix HV (brut) à partir duquel l'HV aurait clairement mieux payé
  local qty = math.min(Track.MAX_QTY, e.count or 1)
  local band = ns.Bags and ns.Bags.SAME_BAND or 0.10
  return { id = e.id, k = "bagNPC", g = "bagNPC", t = now, till = till, qty = qty, cost = qty * e.vendor,
           vendor = e.vendor, resale = e.vendor * (1 + band) / (1 - cut), expect = 0, n = 0, held = {}, sold = 0 }
end

-- Clôture : prix tenu, écoulé, bénéfice constaté
function Track.Close(rec)
  local r
  if rec.k == "stock" then
    r = rec.reached and rec.resale or rec.last  -- remonté au prix annoncé, sinon revente au dernier prix vu
  else
    r = median(rec.held)
  end
  rec.held = nil
  if not r or rec.n == 0 then rec.status = "nodata"; return rec end
  rec.realized = math.min(r, rec.resale)
  rec.priceOk = rec.realized >= rec.resale * Track.HELD
  rec.soldOk = rec.sold >= rec.qty
  rec.ok = rec.priceOk and rec.soldOk
  rec.gain = rec.qty * net(rec.realized) - rec.cost
  if rec.k == "bagNPC" then
    -- conseil juste tant que l'HV n'a PAS clairement fait mieux que le marchand
    local better = rec.ok
    rec.ok, rec.priceOk = not better, not rec.priceOk
    rec.realized = r -- pas plafonné : on veut l'or réellement manqué
    rec.gain = better and math.min(0, rec.cost - rec.qty * net(r)) or 0
  end
  rec.status = rec.ok and "ok" or "ko"
  return rec
end

-- Appelé à la fin de chaque scan, après la mise à jour du carnet d'ordres
function Track.OnScan(db, now, diff)
  local t = Track.DB(db)
  -- 1) vérifier les conseils en cours sur ce scan
  for key, rec in pairs(t.open) do
    if now > rec.t then
      local book = db.book and ns.Scan.UnpackBook(db.book[rec.id])
      local p = Track.Achievable(rec, book)
      if p then
        rec.n = rec.n + 1
        -- tu te mets juste en dessous ; sacs « PNJ » : pas de plafond, on veut l'or que l'HV aurait payé
        local cap = rec.k == "bagNPC" and math.huge or rec.resale
        rec.held[#rec.held + 1] = math.min(p - 1, cap)
        rec.last = math.min(p - 1, cap)
        if p - 1 >= rec.resale * Track.HELD then rec.reached = true end
      end
      local d = diff and diff[rec.id]
      if d and d.lv then
        for _, l in ipairs(d.lv) do
          if l[1] >= rec.resale * Track.SOLD_AT then rec.sold = rec.sold + l[2] end
        end
      end
    end
    local early = rec.k == "stock" and rec.reached and rec.sold >= rec.qty
    if now >= rec.till or early then
      t.done[#t.done + 1] = Track.Close(rec)
      t.open[key] = nil
    end
  end
  -- 2) noter les nouveaux conseils (un seul en cours par objet et par type)
  for _, f in ipairs(ns.Analysis.Flips()) do
    local key = f.id .. ":" .. f.kind
    if not t.open[key] then t.open[key] = fromFlip(f, now) end
  end
  for _, e in ipairs(ns.Analysis.VendorFlips()) do
    local key = e.id .. ":vendor"
    if not t.open[key] then t.open[key] = fromVendor(e, now) end
  end
  for _, e in ipairs(ns.Analysis.Crafts()) do
    if e.cost and e.sellTo == "HV" and (e.profit or 0) > 0 and e.s and e.s.price then
      local key = e.id .. ":craft"
      if not t.open[key] then t.open[key] = fromCraft(e, now) end
    end
  end
  for _, e in ipairs(ns.Bags and ns.Bags.Advice() or {}) do
    local ok = (e.action == "Vendre HV" and e.post and e.post > 0)
      or (e.action == "PNJ" and e.s and (e.vendor or 0) > 0)
    if ok then
      local key = e.id .. ":" .. (e.action == "PNJ" and "bagNPC" or "bagAH")
      if not t.open[key] then t.open[key] = fromBag(e, now) end
    end
  end
  -- 3) purge
  local keep = {}
  for _, rec in ipairs(t.done) do
    if rec.t >= now - Track.KEEP_DAYS * 86400 then keep[#keep + 1] = rec end
  end
  t.done = keep
end

-- Suivi réel : achats de l'objet dans les 24 h après le conseil, puis leurs reventes (premier acheté,
-- premier vendu). Une même ligne du journal ne sert qu'à un seul conseil.
function Track.Real(recs)
  local ledger = ns.Ledger and ns.Ledger.DB().ledger or {}
  local byId = {}
  for _, e in ipairs(ledger) do
    if e.id and e.t and (e.c or 0) > 0 and (e.k == "bought" or e.k == "sold") then
      local l = byId[e.id]
      if not l then l = {}; byId[e.id] = l end
      l[#l + 1] = e
    end
  end
  for _, l in pairs(byId) do table.sort(l, function(a, b) return a.t < b.t end) end
  local sorted = {}
  for _, r in ipairs(recs) do sorted[#sorted + 1] = r end
  table.sort(sorted, function(a, b) return a.t < b.t end)
  local used, out = {}, {}
  for _, rec in ipairs(sorted) do
    local q, res = {}, { units = 0, spent = 0, soldUnits = 0, gain = 0 }
    for _, e in ipairs(byId[rec.id] or {}) do
      if e.k == "bought" and not used[e] and e.t >= rec.t and e.t <= rec.t + Track.FOLLOW_SECS then
        used[e] = true
        q[#q + 1] = { left = e.c, unit = (e.g or 0) / e.c, t = e.t }
        res.units, res.spent = res.units + e.c, res.spent + (e.g or 0)
      elseif e.k == "sold" and q[1] and e.t >= q[1].t then
        local left = e.c - (used[e] or 0)
        local unitNet = ((e.g or 0) - (e.cut or 0)) / e.c
        while left > 0 and q[1] do
          local b = q[1]
          local m = math.min(left, b.left)
          res.soldUnits, res.gain = res.soldUnits + m, res.gain + m * (unitNet - b.unit)
          left, b.left = left - m, b.left - m
          used[e] = (used[e] or 0) + m
          if b.left <= 0 then table.remove(q, 1) end
        end
      end
    end
    if res.units > 0 then out[rec] = res end
  end
  return out
end

-- Bilan par type de conseil
function Track.Summary(db)
  local t = Track.DB(db)
  local all = {}
  for _, rec in ipairs(t.done) do all[#all + 1] = rec end
  for _, rec in pairs(t.open) do all[#all + 1] = rec end
  local real = Track.Real(all)
  local by, rows = {}, {}
  for i, g in ipairs(Track.GROUPS) do
    by[g.key] = { key = g.key, label = g.label, order = i, checked = 0, ok = 0, priceOk = 0, open = 0, nodata = 0,
                  expect = 0, gain = 0, followed = 0, realGain = 0, realSold = 0, realBought = 0 }
    rows[i] = by[g.key]
  end
  for _, rec in ipairs(all) do
    local s = by[rec.g]
    if s then
      if not rec.status then
        s.open = s.open + 1
      elseif rec.status == "nodata" then
        s.nodata = s.nodata + 1
      else
        s.checked = s.checked + 1
        if rec.ok then s.ok = s.ok + 1 end
        if rec.priceOk then s.priceOk = s.priceOk + 1 end
        s.expect = s.expect + (rec.expect or 0)
        s.gain = s.gain + (rec.gain or 0)
      end
      local r = real[rec]
      if r then
        s.followed = s.followed + 1
        s.realBought, s.realSold, s.realGain = s.realBought + r.units, s.realSold + r.soldUnits, s.realGain + r.gain
      end
    end
  end
  for _, s in ipairs(rows) do s.rate = s.checked > 0 and s.ok / s.checked or nil end
  return rows
end

-- Une ligne par type, pour le chat et le rapport
function Track.Lines(db, money)
  money = money or ns.money
  local out = {}
  for _, s in ipairs(Track.Summary(db)) do
    if s.checked + s.open + s.nodata > 0 then
      local l = ("%s : %d vérifiés, %s réussis, prix tenu %d/%d, %d en cours · bénéfice prévu %s, constaté %s"):format(
        s.label, s.checked, s.rate and ("%.0f%%"):format(s.rate * 100) or "-", s.priceOk, s.checked, s.open,
        money(s.expect), money(s.gain))
      if s.followed > 0 then
        l = l .. (" · suivis par toi %d fois : %d achetés, %d revendus, gain réel %s"):format(
          s.followed, s.realBought, s.realSold, money(s.realGain))
      end
      out[#out + 1] = l
    end
  end
  return out
end

function Track.Report()
  local lines = Track.Lines()
  if #lines == 0 then
    ns.print("Fiabilité des conseils : rien de vérifié pour l'instant. Chaque scan note les conseils et vérifie les anciens.")
    return
  end
  ns.print("Fiabilité des conseils (prix tenu = revente atteinte ; écoulé = le marché a acheté ta quantité à ce prix, estimé) :")
  for _, l in ipairs(lines) do ns.print("  " .. l) end
end
