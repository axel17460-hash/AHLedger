-- AHLedger - Bilan réel : ventes, achats et expirations lus dans les courriers de l'HV.
--
-- * Chaque courrier « Vente réussie » / « Enchère gagnée » contient une facture (prix, dépôt, commission) :
--   on l'enregistre une seule fois, même si tu rouvres la boîte aux lettres.
-- * Les factures servent aussi à mesurer la vraie commission et le vrai dépôt de Forever :
--   dès 5 ventes, ils remplacent les valeurs supposées (Analysis.AH_CUT et DEPOSIT_RATE).
local _, ns = ...

local Ledger = {}
ns.Ledger = Ledger

Ledger.KEEP_DAYS = 60
Ledger.DAYS = 30            -- période affichée dans l'onglet Opérations
Ledger.MIN_CALIB = 5        -- ventes nécessaires pour faire confiance à la commission mesurée
Ledger.CUT_MIN, Ledger.CUT_MAX = 0.03, 0.10 -- commission mesurée acceptée (Forever : 5 %)
Ledger.DEP_MIN, Ledger.DEP_MAX = 0.05, 0.60 -- dépôt mesuré, en part du prix PNJ (mesuré : 20 à 45 %)

function Ledger.DB()
  local db = ns.realmDB()
  db.ledger = db.ledger or {}
  return db
end

-- nom d'objet -> identifiant, à partir des objets déjà vus
local nameIndex, nameIndexSize
local function idForName(name)
  if not name then return nil end
  local n = 0
  for _ in pairs(AHLedgerDB.items) do n = n + 1 end
  if not nameIndex or n ~= nameIndexSize then
    nameIndex, nameIndexSize = {}, n
    for id, m in pairs(AHLedgerDB.items) do if m.n then nameIndex[m.n] = id end end
  end
  return nameIndex[name]
end

-- "Silk Cloth (20)" -> "Silk Cloth", 20
local function splitCount(name)
  local base, c = (name or ""):match("^(.-)%s*%((%d+)%)$")
  if base then return base, tonumber(c) end
  return name, nil
end

local function subjectPattern(global)
  if not global then return nil end
  return "^" .. global:gsub("([%(%)%.%-%+%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$"
end

-- Un courrier n'a pas d'identifiant : on le reconnaît à sa facture (type, objet, montant, quantité,
-- commission, dépôt) et à sa date d'expiration (fixe, contrairement à « jours restants »). Les lignes
-- du bilan servent elles-mêmes de liste des courriers déjà vus : une ligne qui a la même facture et
-- la même expiration (à EXPIRY_TOLERANCE près) est ce courrier. Le montant d'argent du courrier
-- n'entre pas dans la clé : il tombe à 0 quand tu récupères l'or, et le courrier serait recompté.
-- Plusieurs courriers identiques (même pile vendue au même prix) sont comptés chacun une fois.
Ledger.EXPIRY_TOLERANCE = 300

local function sameMail(a, b)
  return a.k == b.k and a.n == b.n and a.c == b.c and (a.g or 0) == (b.g or 0)
    and (a.cut or 0) == (b.cut or 0) and (a.dep or 0) == (b.dep or 0)
end

-- Lit le courrier i. Renvoie la ligne de bilan, ou nil si ce n'est pas un courrier d'HV.
-- GetInboxInvoiceInfo : type, objet, joueur, enchère, rachat, dépôt, commission, délai, heure, minute,
-- quantité (11e retour, comme le lisent TSM et Daylight UI). Le prix payé est l'enchère : sur Forever,
-- le champ « rachat » d'une vente de pile ne contient pas le prix. Si l'enchère manque ou paraît fausse
-- (inférieure à la commission), on la recalcule depuis l'argent du courrier : or reçu = prix + dépôt − commission.
function Ledger.ReadMail(i, expiredPat)
  local _, _, _, subject, money = GetInboxHeaderInfo(i)
  if not subject then return nil end
  local kind, itemName, bid, buyout, deposit, consignment, count
  if GetInboxInvoiceInfo then
    kind, itemName, _, bid, buyout, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(i)
  end
  if kind == "seller" or kind == "buyer" then
    local name, c = splitCount(itemName)
    deposit, consignment = deposit or 0, consignment or 0
    local gross = (bid and bid > 0) and bid or nil
    if kind == "seller" and (not gross or gross < consignment) and money and money > 0 then
      gross = money - deposit + consignment
    end
    gross = gross or ((buyout and buyout > 0) and buyout or 0)
    count = tonumber(count)
    if not count or count < 1 then count = c or 1 end
    return { k = kind == "seller" and "sold" or "bought", n = name, id = idForName(name), c = count,
             g = gross, dep = deposit, cut = consignment }
  elseif expiredPat and subject:match(expiredPat) then
    local link = GetInboxItemLink and GetInboxItemLink(i, 1)
    local name, c = splitCount(subject:match(expiredPat))
    local cnt
    if GetInboxItem then cnt = select(4, GetInboxItem(i, 1)) end
    return { k = "expired", n = name, id = ns.itemIdFromLink(link) or idForName(name), c = tonumber(cnt) or c or 1 }
  end
end

function Ledger.ReadInbox()
  if not (GetInboxNumItems and GetInboxHeaderInfo) then return 0 end
  local db = Ledger.DB()
  Ledger.Repair()
  local expiredPat = subjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT)
  local added, used = 0, {}
  for i = 1, GetInboxNumItems() do
    local e = Ledger.ReadMail(i, expiredPat)
    if e then
      local daysLeft = select(7, GetInboxHeaderInfo(i))
      e.x = math.floor(time() + (daysLeft or 0) * 86400)
      -- déjà enregistré ? (ligne sans expiration : relevée par une ancienne version, réclamée une fois)
      local match
      for _, old in ipairs(db.ledger) do
        if not used[old] and sameMail(old, e) and (old.x == nil or math.abs(old.x - e.x) <= Ledger.EXPIRY_TOLERANCE) then
          match = old
          break
        end
      end
      if match then
        used[match] = true
        match.x = match.x or e.x
      else
        e.t = time()
        db.ledger[#db.ledger + 1] = e
        used[e] = true
        added = added + 1
      end
    end
  end
  if added > 0 then
    Ledger.Prune()
    Ledger.Calibrate()
    ns.print(("Bilan : %d courrier(s) d'HV enregistré(s) (onglet Opérations)."):format(added))
    if ns.UI then ns.UI.OnData() end
  end
  return added
end

-- Réparation des lignes relevées avant la version 0.8.1 : la quantité était lue dans le 10e retour
-- de la facture (la minute de livraison, souvent 0), le prix dans le champ « rachat » (sur Forever,
-- la quantité de la pile), et un courrier était recompté quand tu récupérais son or.
-- Prix réel = commission / 5 % (vérifié en jeu sur les ventes d'équipement, où le rachat était juste).
Ledger.REPAIR_VERSION = 1
Ledger.FOREVER_CUT = 0.05
function Ledger.Repair()
  local db = Ledger.DB()
  if (db.ledgerFix or 0) >= Ledger.REPAIR_VERSION then return 0 end
  local fixed, keep = 0, {}
  for _, e in ipairs(db.ledger) do
    if e.k ~= "expired" and (e.c or 0) < 1 then
      fixed = fixed + 1
      if e.k == "sold" and (e.cut or 0) > 0 and (e.g or 0) < e.cut then
        e.c = math.max(1, e.g or 1)                       -- le champ lu contenait la quantité
        e.g = math.floor(e.cut / Ledger.FOREVER_CUT + 0.5)
      else
        e.c = 1
      end
    end
    -- doublon : même facture relevée deux fois en moins de 10 minutes
    local dup = false
    for _, k in ipairs(keep) do
      if sameMail(k, e) and math.abs((k.t or 0) - (e.t or 0)) <= 600 then dup = true; break end
    end
    if dup then fixed = fixed + 1 else keep[#keep + 1] = e end
  end
  db.ledger = keep
  db.ledgerSeen = nil
  db.ledgerFix = Ledger.REPAIR_VERSION
  Ledger.Calibrate()
  return fixed
end

function Ledger.Prune()
  local db = Ledger.DB()
  local limit = time() - Ledger.KEEP_DAYS * 86400
  local keep = {}
  for _, e in ipairs(db.ledger) do if e.t >= limit then keep[#keep + 1] = e end end
  db.ledger = keep
end

-- Commission et dépôt réels, mesurés sur les factures de vente
function Ledger.Calibrate()
  local db = Ledger.DB()
  local gross, cut, dep, base, n = 0, 0, 0, 0, 0
  for _, e in ipairs(db.ledger) do
    if e.k == "sold" and e.g and e.g > 0 then
      n = n + 1
      gross, cut = gross + e.g, cut + (e.cut or 0)
      local meta = e.id and AHLedgerDB.items[e.id]
      if meta and meta.s and meta.s > 0 and e.dep then
        dep, base = dep + e.dep, base + meta.s * (e.c or 1)
      end
    end
  end
  local A = ns.Analysis
  A.DEFAULT_CUT = A.DEFAULT_CUT or A.AH_CUT
  A.DEFAULT_DEPOSIT = A.DEFAULT_DEPOSIT or A.DEPOSIT_RATE
  db.calib = { n = n }
  -- bornes : une facture mal lue (quantité fausse) ne doit pas fausser tous les prix nets
  if n >= Ledger.MIN_CALIB and gross > 0 then
    db.calib.cut = math.max(Ledger.CUT_MIN, math.min(Ledger.CUT_MAX, cut / gross))
    if base > 0 then db.calib.dep = math.max(Ledger.DEP_MIN, math.min(Ledger.DEP_MAX, dep / base)) end
  end
  A.AH_CUT = db.calib.cut or A.DEFAULT_CUT
  A.DEPOSIT_RATE = db.calib.dep or A.DEFAULT_DEPOSIT
  ns.dataVersion = (ns.dataVersion or 0) + 1
end

-- Bilan par objet sur les Ledger.DAYS derniers jours
function Ledger.Summary()
  local db = Ledger.DB()
  local limit = time() - Ledger.DAYS * 86400
  local by, tot = {}, { spent = 0, revenue = 0, sold = 0, bought = 0, expired = 0, cut = 0 }
  for _, e in ipairs(db.ledger) do
    if e.t >= limit then
      local key = e.id or e.n or "?"
      local r = by[key]
      if not r then
        r = { id = e.id, name = e.n, bought = 0, spent = 0, sold = 0, gross = 0, revenue = 0, expired = 0,
              soldN = 0, expiredN = 0 } -- soldN, expiredN : nombre de courriers (mises en vente), pas d'unités
        by[key] = r
      end
      if e.k == "bought" then
        r.bought, r.spent = r.bought + e.c, r.spent + e.g
      elseif e.k == "sold" then
        r.sold, r.gross, r.soldN = r.sold + e.c, r.gross + e.g, r.soldN + 1
        r.revenue = r.revenue + e.g - (e.cut or 0)
        tot.cut = tot.cut + (e.cut or 0)
      else
        r.expired, r.expiredN = r.expired + e.c, r.expiredN + 1
      end
    end
  end
  local out = {}
  for _, r in pairs(by) do
    r.balance = r.revenue - r.spent
    r.avgSale = r.sold > 0 and r.gross / r.sold or nil
    local s = r.id and ns.Analysis.Get(r.id)
    r.predicted = s and s.price
    if r.avgSale and r.predicted then r.gap = r.avgSale / r.predicted - 1 end
    r.sellThrough = (r.sold + r.expired) > 0 and r.sold / (r.sold + r.expired) or nil
    tot.spent, tot.revenue = tot.spent + r.spent, tot.revenue + r.revenue
    tot.sold, tot.bought, tot.expired = tot.sold + r.sold, tot.bought + r.bought, tot.expired + r.expired
    out[#out + 1] = r
  end
  return out, tot
end

-- Tes flips réels : chaque vente est rapprochée de tes achats précédents du même objet, le plus ancien
-- d'abord. Donne, par objet, les unités rachetées puis revendues, le temps moyen entre l'achat et la vente
-- (dates de lecture des courriers : approximatif, à quelques heures près) et le bénéfice net par unité.
-- holds[id] = { units, days, profit (par unité, commission déduite) }
function Ledger.Holds()
  local rows = {}
  for _, e in ipairs(Ledger.DB().ledger) do
    if e.id and e.t and (e.c or 0) > 0 and (e.k == "bought" or e.k == "sold") then rows[#rows + 1] = e end
  end
  table.sort(rows, function(a, b) return a.t < b.t end)
  local queues, acc = {}, {}
  for _, e in ipairs(rows) do
    local q = queues[e.id]
    if not q then q = {}; queues[e.id] = q end
    if e.k == "bought" then
      q[#q + 1] = { t = e.t, left = e.c, unit = (e.g or 0) / e.c }
    else
      local left, unitNet = e.c, ((e.g or 0) - (e.cut or 0)) / e.c
      while left > 0 and q[1] do
        local b = q[1]
        local m = math.min(left, b.left)
        local a = acc[e.id]
        if not a then a = { units = 0, daySum = 0, gain = 0 }; acc[e.id] = a end
        a.units = a.units + m
        a.daySum = a.daySum + m * (e.t - b.t) / 86400
        a.gain = a.gain + m * (unitNet - b.unit)
        left, b.left = left - m, b.left - m
        if b.left <= 0 then table.remove(q, 1) end
      end
    end
  end
  local out = {}
  for id, a in pairs(acc) do out[id] = { units = a.units, days = a.daySum / a.units, profit = a.gain / a.units } end
  return out
end

ns.on("MAIL_INBOX_UPDATE", function() Ledger.ReadInbox() end)
ns.on("PLAYER_LOGIN", function() Ledger.Repair(); Ledger.Calibrate() end)

function Ledger.Report()
  -- le bilan en or est celui de Tracker (/ahl bilan l'affiche juste avant) : ici, les volumes et le calibrage
  local _, tot = Ledger.Summary()
  local c = Ledger.DB().calib or {}
  ns.print(("Courriers %d j : %d vendus, %d expirés, %d achetés."):format(Ledger.DAYS, tot.sold, tot.expired, tot.bought))
  if c.cut then
    ns.print(("Commission mesurée : %.1f %% · dépôt mesuré : %s (sur %d ventes)."):format(
      c.cut * 100, c.dep and ("%.1f %% du prix PNJ"):format(c.dep * 100) or "?", c.n))
  else
    ns.print(("Commission et dépôt encore supposés (%d/%d ventes relevées)."):format(c.n or 0, Ledger.MIN_CALIB))
  end
end
