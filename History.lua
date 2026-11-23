-- AHLedger - Historique journalier compact par objet
--
-- db.days[jour]  = { obs = secondes de marché observées (somme des écarts entre scans comparables),
--                    scans = nombre de scans }
-- db.hist[id][jour] = "sommePrix,nbPrix,sommeStock,vendu,ambigu,valeurVendue,expiré"
--   sommePrix/nbPrix : moyenne des prix médians affichés ce jour-là
--   sommeStock       : à diviser par days[jour].scans (stock moyen à l'HV)
--   vendu/ambigu     : unités disparues estimées vendues / incertaines
--   valeurVendue     : cuivre total des enchères vendues (=> prix réel de vente)
--   expiré           : unités disparues en fin de durée (=> taux d'écoulement) ; absent des anciennes données
local _, ns = ...

local History = {}
ns.History = History

History.KEEP_DAYS = 30

function History.today(t)
  return math.floor((t or time()) / 86400)
end

function History.parse(s)
  if not s then return nil end
  local a, b, c, d, e, f, g = s:match("^(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),?(%d*)$")
  if not a then return nil end
  return { pSum = tonumber(a), pN = tonumber(b), qSum = tonumber(c),
           sold = tonumber(d), amb = tonumber(e), soldVal = tonumber(f), exp = tonumber(g) or 0 }
end

local function pack(r)
  return table.concat({ r.pSum, r.pN, r.qSum, r.sold, r.amb, r.soldVal, r.exp or 0 }, ",")
end

-- stats[id] = { med=, q= } pour les objets présents ; diff[id] = { sold, amb, soldVal, ... } ou nil
function History.Record(db, now, stats, diff, gap)
  db.hist = db.hist or {}
  db.days = db.days or {}
  local day = History.today(now)
  local dayRec = db.days[day]
  if not dayRec then
    dayRec = { obs = 0, scans = 0 }
    db.days[day] = dayRec
  end
  dayRec.scans = dayRec.scans + 1
  if diff and gap then dayRec.obs = dayRec.obs + gap end

  local ids = {}
  for id in pairs(stats) do ids[id] = true end
  if diff then for id in pairs(diff) do ids[id] = true end end

  for id in pairs(ids) do
    local h = db.hist[id]
    if not h then h = {}; db.hist[id] = h end
    local r = History.parse(h[day]) or { pSum = 0, pN = 0, qSum = 0, sold = 0, amb = 0, soldVal = 0, exp = 0 }
    local s = stats[id]
    if s and s.med and s.med > 0 then
      r.pSum = r.pSum + s.med
      r.pN = r.pN + 1
    end
    if s then r.qSum = r.qSum + s.q end
    local d = diff and diff[id]
    if d then
      r.sold = r.sold + d.sold
      r.amb = r.amb + d.amb
      r.soldVal = r.soldVal + d.soldVal
      r.exp = (r.exp or 0) + (d.exp or 0)
    end
    h[day] = pack(r)
  end

  if db.lastDay ~= day then
    db.lastDay = day
    History.Prune(db, day)
  end
  ns.dataVersion = (ns.dataVersion or 0) + 1
end

-- Série intra-journalière sur 48 h : db.recent[id] = "t,médiane,qté;t,médiane,qté;…"
History.RECENT_SECS = 48 * 3600

function History.RecordRecent(db, now, stats)
  db.recent = db.recent or {}
  local limit = now - History.RECENT_SECS
  for id, s in pairs(stats) do
    if s.med and s.med > 0 then
      local str = (db.recent[id] or "") .. now .. "," .. s.med .. "," .. s.q .. ";"
      -- retire les points de plus de 48 h en tête de chaîne
      while true do
        local t, rest = str:match("^(%d+),[^;]*;(.*)$")
        if t and tonumber(t) < limit then str = rest else break end
      end
      db.recent[id] = str
    end
  end
  -- objets absents depuis plus de 48 h
  for id, str in pairs(db.recent) do
    local last = str:match("(%d+),[^;]*;$")
    if not last or tonumber(last) < limit then db.recent[id] = nil end
  end
end

function History.Recent(db, id)
  local out = {}
  local str = db.recent and db.recent[id]
  if not str then return out end
  for t, med, q in str:gmatch("(%d+),(%d+),(%d+);") do
    out[#out + 1] = { tonumber(t), tonumber(med), tonumber(q) }
  end
  return out
end

function History.Prune(db, today)
  local limit = today - History.KEEP_DAYS
  for d in pairs(db.days) do
    if d < limit then db.days[d] = nil end
  end
  for id, h in pairs(db.hist) do
    local any = false
    for d in pairs(h) do
      if d < limit then h[d] = nil else any = true end
    end
    if not any then db.hist[id] = nil end
  end
end
