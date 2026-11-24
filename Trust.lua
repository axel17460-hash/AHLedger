-- AHLedger - Fiabilité d'un prix : se vend-il vraiment à ce prix ?
--
-- Le prix d'un objet peu vendu est souvent un prix AFFICHÉ : quelques vendeurs demandent cher, rien ne
-- part, tout expire. Pour trancher, on garde par objet ce qui s'est réellement passé, au prix près :
--   * « s » : unités parties avant expiration (vendues, d'après le scan) et leur prix unitaire ;
--   * « e » : unités expirées, et à quel prix ;
--   * « l » : annonces restées en vente sans acheteur pendant LINGER_SECS (12 h), à quel prix.
-- S'y ajoutent tes propres courriers d'HV (vendu / expiré), la vérité terrain, et, pour les jours d'avant
-- cette mesure, le prix moyen des ventes du jour gardé dans l'historique.
--
-- Verdict pour un prix donné : « ok » (ventes vues à ce prix), « test » (trop peu de preuves : une seule
-- pile pour voir), « bad » (rien vu vendu aussi cher, invendus à ce prix ou moins, ou expiré chez toi).
local _, ns = ...

local Trust = {}
ns.Trust = Trust

Trust.KEEP_DAYS = 14
Trust.MAX_EVENTS = 60        -- par objet
Trust.LINGER_SECS = 12 * 3600
Trust.ABOVE_MAX = 1.10       -- plus de 10 % au-dessus du plus haut prix vu vendu : pas prouvé
Trust.OK_SALES = 3           -- ventes vues à ce prix (ou plus cher) pour faire confiance

local function today(now) return ns.History.today(now) end

-- Ajoute des événements « jour,prix,unités,genre; » et purge ce qui a plus de 14 jours
local function append(db, id, day, list, kind)
  db.outcomes = db.outcomes or {}
  local str = db.outcomes[id] or ""
  for _, l in ipairs(list) do
    if l[1] and l[1] > 0 and l[2] and l[2] > 0 then
      str = str .. ("%d,%d,%d,%s;"):format(day, math.floor(l[1] + 0.5), l[2], kind)
    end
  end
  local parts, limit = {}, day - Trust.KEEP_DAYS
  for d, rest in str:gmatch("(%d+),([^;]*);") do
    if tonumber(d) >= limit then parts[#parts + 1] = d .. "," .. rest .. ";" end
  end
  while #parts > Trust.MAX_EVENTS do table.remove(parts, 1) end
  db.outcomes[id] = #parts > 0 and table.concat(parts) or nil
end

-- Appelé à la fin d'un scan : ventes et expirations du diff, annonces qui traînent.
-- sigs reçoit la date de première apparition de chaque annonce (f) et une marque une fois notée (r).
function Trust.Record(db, now, diff, prevSigs, sigs)
  local day = today(now)
  for id, b in pairs(diff or {}) do
    if b.lv and #b.lv > 0 then append(db, id, day, b.lv, "s") end
    if b.lvExp and #b.lvExp > 0 then append(db, id, day, b.lvExp, "e") end
  end
  if not (sigs and prevSigs and diff) then
    for _, cur in pairs(sigs or {}) do cur.f = now end
    return
  end
  local linger = {}
  for sig, cur in pairs(sigs) do
    local prev = prevSigs[sig]
    cur.f = prev and prev.f or now
    cur.r = prev and prev.r or nil
    if not cur.r and now - cur.f >= Trust.LINGER_SECS then
      local id, count, buyout = sig:match("^(%d+):(%d+):(%d+):")
      id, count, buyout = tonumber(id), tonumber(count), tonumber(buyout)
      if id and buyout and buyout > 0 then
        linger[id] = linger[id] or {}
        linger[id][#linger[id] + 1] = { buyout / count, count * cur.c }
        cur.r = 1
      end
    end
  end
  for id, list in pairs(linger) do append(db, id, day, list, "l") end
end

-- Tes courriers d'HV par objet : { sold, expired, avg = prix moyen vendu /u }, relus quand ils changent
local ownCache, ownN
function Trust.Own()
  local led = ns.Ledger and ns.Ledger.DB and ns.Ledger.DB().ledger or {}
  if ownCache and ownN == #led then return ownCache end
  local by, limit = {}, time() - Trust.KEEP_DAYS * 2 * 86400
  for _, e in ipairs(led) do
    if e.id and e.t and e.t >= limit and (e.k == "sold" or e.k == "expired") then
      local r = by[e.id]
      if not r then r = { sold = 0, expired = 0, gross = 0 }; by[e.id] = r end
      if e.k == "sold" then r.sold, r.gross = r.sold + (e.c or 1), r.gross + (e.g or 0)
      else r.expired = r.expired + (e.c or 1) end
    end
  end
  for _, r in pairs(by) do r.avg = r.sold > 0 and r.gross / r.sold or nil end
  ownCache, ownN = by, #led
  return by
end

-- Preuves sur un objet : liste { prix, unités, genre } et plus haut prix vu vendu
function Trust.Evidence(db, id, day)
  local ev = { list = {}, soldUnits = 0 }
  -- w = poids en « ventes vues » : une annonce mesurée compte pour 1 ; une journée d'historique ou
  -- tes courriers comptent pour leurs unités (un prix moyen sur 2000 ventes vaut plus qu'une annonce)
  local function add(u, n, k, w)
    ev.list[#ev.list + 1] = { u, n, k, w or 1 }
    if k == "s" then
      ev.soldUnits = ev.soldUnits + n
      if not ev.maxSold or u > ev.maxSold then ev.maxSold = u end
    end
  end
  local measured = {}
  local str = db.outcomes and db.outcomes[id]
  if str then
    for d, u, n, k in str:gmatch("(%d+),(%d+),(%d+),(%a);") do
      add(tonumber(u), tonumber(n), k)
      measured[tonumber(d)] = true
    end
  end
  -- jours d'avant la mesure au prix près : prix moyen des ventes du jour (historique)
  local h = db.hist and db.hist[id]
  if h then
    for d = day - Trust.KEEP_DAYS + 1, day do
      local r = not measured[d] and ns.History.parse(h[d])
      if r and r.sold > 0 and r.soldVal > 0 then add(r.soldVal / r.sold, r.sold, "s", r.sold) end
    end
  end
  local own = Trust.Own()[id]
  if own and own.avg then add(own.avg, own.sold, "s", own.sold) end
  ev.own = own
  return ev
end

local function plain(c) return (ns.money(c):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- Verdict pour un prix : niveau, raison courte, prix plafond conseillé (plus haut prix vu vendu)
function Trust.Check(s, price)
  local ev = s and s.ev
  if not (ev and price) then return "test", "aucune donnée" end
  local own = ev.own
  if ev.maxSold and price > ev.maxSold * Trust.ABOVE_MAX then
    return "bad", ("rien vu vendu au-dessus de %s"):format(plain(ev.maxSold)), ev.maxSold
  end
  local soldAt, failAt = 0, 0
  for _, e in ipairs(ev.list) do
    if e[3] == "s" and e[1] >= price * 0.95 then soldAt = soldAt + e[4]
    elseif e[3] ~= "s" and e[1] <= price * 1.05 then failAt = failAt + e[2] end
  end
  -- tes enchères expirées, jamais vendues : décisif, sauf si le marché vend clairement à ce prix
  if own and own.sold == 0 and own.expired >= 1 and (own.expired >= 2 or soldAt < Trust.OK_SALES) then
    return "bad", ("expiré chez toi ×%d, jamais vendu"):format(own.expired), ev.maxSold
  end
  if failAt >= 2 and failAt > soldAt then
    return "bad", ("%d invendus à ce prix ou moins"):format(failAt), ev.maxSold
  end
  if not ev.maxSold then return "test", "aucune vente vue" end
  if soldAt >= Trust.OK_SALES or (own and own.sold >= 2 and own.sold > own.expired) then
    return "ok", ("%d ventes vues à ce prix ou plus"):format(soldAt), ev.maxSold
  end
  return "test", soldAt > 0 and ("seulement %d vente(s) vue(s) à ce prix"):format(soldAt) or "aucune vente vue à ce prix", ev.maxSold
end

Trust.LABEL = { ok = "|cff40ff40fiable|r", test = "|cffffd100à tester|r", bad = "|cffff5050prix non tenu|r" }
