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
Ledger.DAYS = 30            -- période affichée dans l'onglet Bilan
Ledger.MIN_CALIB = 5        -- ventes nécessaires pour faire confiance à la commission mesurée

function Ledger.DB()
  local db = ns.realmDB()
  db.ledger = db.ledger or {}
  db.ledgerSeen = db.ledgerSeen or {}
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

-- Un courrier n'a pas d'identifiant : on le reconnaît à son sujet, son montant et sa date
-- d'expiration (fixe, contrairement à « jours restants »). Plusieurs courriers identiques
-- (même pile vendue au même prix) sont comptés chacun une fois.
Ledger.EXPIRY_TOLERANCE = 300

local function mailBase(subject, money) return (subject or "") .. "|" .. (money or 0) end

function Ledger.ReadInbox()
  if not (GetInboxNumItems and GetInboxHeaderInfo) then return 0 end
  local db = Ledger.DB()
  local expiredPat = subjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT)
  local added, used = 0, {}
  for i = 1, GetInboxNumItems() do
    local _, _, _, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
    local base = mailBase(subject, money)
    local expiry = time() + (daysLeft or 0) * 86400
    local known = db.ledgerSeen[base]
    local seen = false
    for j, x in ipairs(known or {}) do
      local tag = base .. "#" .. j
      if not used[tag] and math.abs(x - expiry) <= Ledger.EXPIRY_TOLERANCE then
        used[tag], seen = true, true
        break
      end
    end
    if subject and not seen then
      local e
      local kind, itemName, bid, buyout, deposit, consignment, count
      if GetInboxInvoiceInfo then
        kind, itemName, _, bid, buyout, deposit, consignment, _, _, count = GetInboxInvoiceInfo(i)
      end
      if kind == "seller" or kind == "buyer" then
        local name, c = splitCount(itemName)
        e = { k = kind == "seller" and "sold" or "bought", n = name, c = count or c or 1,
              g = kind == "seller" and (buyout and buyout > 0 and buyout or bid) or (bid or 0),
              dep = deposit or 0, cut = consignment or 0 }
        e.id = idForName(name)
      elseif expiredPat and subject:match(expiredPat) then
        local link = GetInboxItemLink and GetInboxItemLink(i, 1)
        local name, c = splitCount(subject:match(expiredPat))
        local cnt
        if GetInboxItem then cnt = select(4, GetInboxItem(i, 1)) end
        e = { k = "expired", n = name, id = ns.itemIdFromLink(link) or idForName(name), c = tonumber(cnt) or c or 1 }
      end
      if e then
        e.t = time()
        db.ledger[#db.ledger + 1] = e
        known = known or {}
        known[#known + 1] = expiry
        db.ledgerSeen[base] = known
        used[base .. "#" .. #known] = true
        added = added + 1
      end
    end
  end
  if added > 0 then
    Ledger.Prune()
    Ledger.Calibrate()
    ns.print(("Bilan : %d courrier(s) d'HV enregistré(s) (onglet Bilan)."):format(added))
    if ns.UI then ns.UI.OnData() end
  end
  return added
end

function Ledger.Prune()
  local db = Ledger.DB()
  local limit = time() - Ledger.KEEP_DAYS * 86400
  local keep = {}
  for _, e in ipairs(db.ledger) do if e.t >= limit then keep[#keep + 1] = e end end
  db.ledger = keep
  -- un courrier expiré ne peut plus réapparaître dans la boîte
  local now = time()
  for k, list in pairs(db.ledgerSeen) do
    local keep2 = {}
    for _, x in ipairs(list) do if x > now - 86400 then keep2[#keep2 + 1] = x end end
    db.ledgerSeen[k] = #keep2 > 0 and keep2 or nil
  end
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
  if n >= Ledger.MIN_CALIB and gross > 0 then
    db.calib.cut = cut / gross
    if base > 0 then db.calib.dep = dep / base end
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
        r = { id = e.id, name = e.n, bought = 0, spent = 0, sold = 0, gross = 0, revenue = 0, expired = 0 }
        by[key] = r
      end
      if e.k == "bought" then
        r.bought, r.spent = r.bought + e.c, r.spent + e.g
      elseif e.k == "sold" then
        r.sold, r.gross = r.sold + e.c, r.gross + e.g
        r.revenue = r.revenue + e.g - (e.cut or 0)
        tot.cut = tot.cut + (e.cut or 0)
      else
        r.expired = r.expired + e.c
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

ns.on("MAIL_INBOX_UPDATE", function() Ledger.ReadInbox() end)
ns.on("PLAYER_LOGIN", function() Ledger.Calibrate() end)

function Ledger.Report()
  local _, tot = Ledger.Summary()
  local c = Ledger.DB().calib or {}
  ns.print(("Bilan %d j : recettes %s, achats %s, solde %s · %d vendus, %d expirés."):format(
    Ledger.DAYS, ns.money(tot.revenue), ns.money(tot.spent), ns.money(tot.revenue - tot.spent), tot.sold, tot.expired))
  if c.cut then
    ns.print(("Commission mesurée : %.1f %% · dépôt mesuré : %s (sur %d ventes)."):format(
      c.cut * 100, c.dep and ("%.1f %% du prix PNJ"):format(c.dep * 100) or "?", c.n))
  else
    ns.print(("Commission et dépôt encore supposés (%d/%d ventes relevées)."):format(c.n or 0, Ledger.MIN_CALIB))
  end
end
