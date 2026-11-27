-- AHLedger - Liste de surveillance avec alertes de prix
--
-- Par objet surveillé, des règles (toutes facultatives) :
--   buy   : le moins cher /u ≤ X           → bon moment pour acheter
--   sell  : le moins cher /u ≥ Y           → bon moment pour vendre (personne ne vend en dessous)
--   pct   : écart du moins cher /u à la moyenne des 7 derniers jours ≥ N (0,2 = 20 %), dans un sens ou l'autre
--   sig   : signal de l'analyse apparu (pénurie, afflux, hausse, baisse, pic, demande+)
--   stock : unités en vente < Z
-- Évaluées après chaque scan complet (Scan.Finish). Une règle qui se déclenche envoie une alerte dans
-- le chat (lien, raison, prix), avec un son si l'option est active, puis se tait : elle ne se réarme
-- que quand sa condition est retombée, avec une marge (REARM) pour qu'un prix qui oscille autour du
-- seuil ne sonne pas à chaque scan. Une condition inconnue (objet absent du scan, pas de moyenne)
-- ne déclenche ni ne réarme.
--
-- Jamais d'achat ni de vente automatique : l'alerte informe, le joueur agit.
--
-- Données : AHLedgerDB.watch = { items = { [id] = règles }, sound = true|false } (communes aux royaumes),
-- état des alertes par royaume dans ns.realmDB().watchState[id] = { on = { [clé] = true }, last = {…} }.
local _, ns = ...

local Watch = {}
ns.Watch = Watch

Watch.REARM = 0.03       -- marge de réarmement des règles de prix et de stock (3 %)
Watch.REARM_PCT = 0.8    -- la règle de variation se réarme sous 80 % de son seuil
Watch.MAX_LINES = 10     -- alertes affichées par scan au plus (le reste est résumé)
Watch.SIGNALS = { ["pénurie"] = true, afflux = true, hausse = true, baisse = true, pic = true, ["demande+"] = true }
local SIG_ALIAS = { penurie = "pénurie", ["pénurie"] = "pénurie", afflux = "afflux", hausse = "hausse", baisse = "baisse",
                    pic = "pic", ["demande+"] = "demande+", demande = "demande+" }
local KEYWORDS = { achat = "buy", vente = "sell", signal = "sig", variation = "pct", stock = "stock" }

function Watch.DB()
  AHLedgerDB.watch = AHLedgerDB.watch or {}
  local d = AHLedgerDB.watch
  d.items = d.items or {}
  if d.sound == nil then d.sound = true end
  return d
end

local function stateDB()
  local r = ns.realmDB()
  r.watchState = r.watchState or {}
  return r.watchState
end

function Watch.State(id)
  local st = stateDB()
  st[id] = st[id] or { on = {} }
  st[id].on = st[id].on or {}
  return st[id]
end

------------------------------------------------------------------------
-- Prix au format WoW : « 1g20s », « 1g 20s 5c », « 35s », « 12c », « 1.5g », aussi po/pa/pc.
-- Un nombre seul est en cuivre (comme /ahl vendre). Renvoie des pièces de cuivre, ou nil si illisible.
------------------------------------------------------------------------
local UNIT = { g = 10000, po = 10000, s = 100, pa = 100, c = 1, pc = 1 }
function Watch.ParseMoney(str)
  if type(str) ~= "string" then return nil end
  local s = str:lower():gsub("%s+", "")
  if s == "" then return nil end
  local total, pos, n, seen, bare = 0, 1, 0, {}, false
  while pos <= #s do
    local num, unit, stop = s:match("^(%d+%.?%d*)(%a*)()", pos)
    if not num then return nil end
    local mult
    if unit == "" then mult, bare = 1, true else mult = UNIT[unit] end
    if not mult or seen[unit] then return nil end
    seen[unit] = true
    total = total + tonumber(num) * mult
    n = n + 1
    pos = stop
  end
  if bare and n > 1 then return nil end -- « 1g 20 » : ambigu
  return math.floor(total + 0.5)
end

------------------------------------------------------------------------
-- Objets
------------------------------------------------------------------------
local function itemName(id)
  local meta = AHLedgerDB.items[id]
  return (meta and meta.n) or ns.GetItemInfo(id) or ("#" .. tostring(id))
end

function Watch.Link(id)
  local _, link = ns.GetItemInfo(id)
  if link then return link end
  return "[" .. itemName(id) .. "]"
end

-- Trouve un objet par lien, numéro (« 4306 » ou « #4306 ») ou nom (exact, puis partie unique du nom).
-- pool : table [id] = … pour limiter la recherche (liste surveillée), sinon tous les objets connus.
-- Renvoie id, ou nil et un message.
function Watch.FindItem(text, pool)
  text = (text or ""):match("^%s*(.-)%s*$")
  if text == "" then return nil, "objet manquant" end
  local id = text:match("item:(%d+)") or text:match("^#?(%d+)$")
  if id then return tonumber(id) end
  local low = text:lower()
  local exact, partial = nil, {}
  for iid in pairs(pool or AHLedgerDB.items) do
    local meta = AHLedgerDB.items[iid]
    local n = meta and meta.n or (pool and itemName(iid))
    if type(iid) == "number" and n then
      local ln = n:lower()
      if ln == low then exact = iid break end
      if ln:find(low, 1, true) then partial[#partial + 1] = iid end
    end
  end
  if exact then return exact end
  if #partial == 1 then return partial[1] end
  if #partial > 1 then
    table.sort(partial, function(a, b) return itemName(a) < itemName(b) end)
    local names = {}
    for i = 1, math.min(#partial, 5) do names[i] = itemName(partial[i]) end
    return nil, ("plusieurs objets contiennent « %s » : %s%s"):format(text, table.concat(names, ", "), #partial > 5 and "…" or "")
  end
  if not pool then
    local _, link = ns.GetItemInfo(text) -- objet en cache du client, jamais vu à l'HV
    local lid = ns.itemIdFromLink(link)
    if lid then return lid end
  end
  return nil, "objet inconnu : « " .. text .. " » (fais un Maj-clic dessus pour coller son lien)"
end

------------------------------------------------------------------------
-- Règles
------------------------------------------------------------------------
function Watch.Get(id) return Watch.DB().items[id] end

-- Ajoute ou modifie la surveillance d'un objet. changes : { buy, sell, pct, stock, sig = { nom = true } } ;
-- la valeur false retire la règle. Les alertes de l'objet sont réarmées (nouveaux seuils).
function Watch.Set(id, changes)
  local items = Watch.DB().items
  local w = items[id] or { t = time() }
  items[id] = w
  for _, k in ipairs({ "buy", "sell", "pct", "stock" }) do
    if changes[k] == false then w[k] = nil elseif changes[k] ~= nil then w[k] = changes[k] end
  end
  if changes.sig == false then
    w.sig = nil
  elseif changes.sig then
    w.sig = w.sig or {}
    for name in pairs(changes.sig) do w.sig[name] = true end
  end
  Watch.State(id).on = {}
  return w
end

function Watch.Remove(id)
  local items = Watch.DB().items
  if not items[id] then return false end
  items[id] = nil
  stateDB()[id] = nil
  return true
end

local function sigList(w)
  local out = {}
  for name in pairs(w.sig or {}) do out[#out + 1] = name end
  table.sort(out)
  return out
end

-- « achat ≤ 1g 20s · vente ≥ 2g · ±20 % · stock < 50 · pénurie »
function Watch.Describe(w)
  local p = {}
  if w.buy then p[#p + 1] = "achat ≤ " .. ns.money(w.buy) end
  if w.sell then p[#p + 1] = "vente ≥ " .. ns.money(w.sell) end
  if w.pct then p[#p + 1] = ("±%.0f %%"):format(w.pct * 100) end
  if w.stock then p[#p + 1] = ("stock < %d"):format(w.stock) end
  for _, name in ipairs(sigList(w)) do p[#p + 1] = name end
  return #p > 0 and table.concat(p, " · ") or "suivi du prix seulement"
end

------------------------------------------------------------------------
-- Évaluation
------------------------------------------------------------------------
-- Conditions d'un objet. m = { price = moins cher /u (nil : absent), q = unités en vente, vsAvg, avg7,
-- signals = { nom = true } (nil : analyse inconnue) }.
-- Renvoie une liste { key, fire = true|false|nil, why } : fire true = condition remplie,
-- false = retombée (réarme), nil = inconnue ou dans la marge de réarmement (ne change rien).
function Watch.Conditions(w, m)
  local out = {}
  local function add(key, fire, why) out[#out + 1] = { key = key, fire = fire, why = why } end
  local p, R = m.price, Watch.REARM
  if w.buy then
    if not p then add("buy", nil)
    elseif p <= w.buy then add("buy", true, ("achat : %s/u ≤ %s"):format(ns.money(p), ns.money(w.buy)))
    elseif p > w.buy * (1 + R) then add("buy", false)
    else add("buy", nil) end
  end
  if w.sell then
    if not p then add("sell", nil)
    elseif p >= w.sell then add("sell", true, ("vente : %s/u ≥ %s"):format(ns.money(p), ns.money(w.sell)))
    elseif p < w.sell * (1 - R) then add("sell", false)
    else add("sell", nil) end
  end
  if w.pct then
    local v = m.vsAvg
    if not v then add("pct", nil)
    elseif math.abs(v) >= w.pct then
      add("pct", true, ("variation %s vs moy. 7 j (%s)"):format(ns.pct(v), ns.money(m.avg7)))
    elseif math.abs(v) < w.pct * Watch.REARM_PCT then add("pct", false)
    else add("pct", nil) end
  end
  if w.stock then
    local q = m.q
    if not q then add("stock", nil)
    elseif q < w.stock then add("stock", true, ("stock : %d en vente < %d"):format(q, w.stock))
    elseif q >= w.stock * (1 + R) then add("stock", false)
    else add("stock", nil) end
  end
  for _, name in ipairs(sigList(w)) do
    if not m.signals then add("sig:" .. name, nil)
    elseif m.signals[name] then add("sig:" .. name, true, "signal " .. name)
    else add("sig:" .. name, false) end
  end
  return out
end

-- Applique les conditions à l'état (anti-spam) : renvoie les raisons des alertes nouvelles.
function Watch.Step(state, conds)
  local why = {}
  for _, c in ipairs(conds) do
    if c.fire == true then
      if not state.on[c.key] then
        state.on[c.key] = true
        why[#why + 1] = c.why
      end
    elseif c.fire == false then
      state.on[c.key] = nil
    end
  end
  return why
end

-- Mesures de marché d'un objet après un scan : stats = { [id] = { q } } du scan (Scan.Finish)
function Watch.Measure(db, id, stats)
  local s = ns.Analysis and ns.Analysis.Get(id)
  local m = { price = db.lastMin and db.lastMin[id], q = stats and (stats[id] and stats[id].q or 0) or nil }
  if s then
    m.vsAvg, m.avg7 = s.vsAvg, s.avg7
    m.signals = {}
    for _, x in ipairs(s.signals or {}) do m.signals[x] = true end
  end
  return m
end

local function playSound()
  if not Watch.DB().sound or not PlaySound or not SOUNDKIT then return end
  local snd = SOUNDKIT.RAID_WARNING or SOUNDKIT.MONEY_FRAME_OPEN
  if snd then PlaySound(snd) end
end

-- Appelé à la fin de chaque scan complet. Renvoie la liste des alertes { id, why = {…}, price }.
function Watch.OnScan(db, now, stats)
  local items = Watch.DB().items
  if not next(items) then return {} end
  local alerts = {}
  local ids = {}
  for id in pairs(items) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local m = Watch.Measure(db, id, stats)
    local st = Watch.State(id)
    st.price, st.q, st.t = m.price, m.q, now
    local why = Watch.Step(st, Watch.Conditions(items[id], m))
    if #why > 0 then
      st.last = { t = now, why = table.concat(why, " ; "), price = m.price }
      alerts[#alerts + 1] = { id = id, why = why, price = m.price }
    end
  end
  for i, a in ipairs(alerts) do
    if i > Watch.MAX_LINES then
      ns.print(("|cffffd100Surveillance|r : %d autres alertes (/ahl surveiller liste)."):format(#alerts - Watch.MAX_LINES))
      break
    end
    ns.print(("|cffffd100Surveillance|r %s — %s"):format(Watch.Link(a.id), table.concat(a.why, " ; ")))
  end
  if #alerts > 0 then playSound() end
  return alerts
end

------------------------------------------------------------------------
-- Affichage (interface, infobulle, chat)
------------------------------------------------------------------------
-- Lignes de la vue « Surveillance »
function Watch.Rows()
  local out = {}
  local st = stateDB()
  for id, w in pairs(Watch.DB().items) do
    local s = st[id] or {}
    local alerting = false
    for _ in pairs(s.on or {}) do alerting = true break end
    out[#out + 1] = { id = id, rules = Watch.Describe(w), price = s.price, q = s.q, alerting = alerting, alertRank = alerting and 1 or 0,
                      lastT = s.last and s.last.t, lastWhy = s.last and s.last.why }
  end
  return out
end

-- Ligne d'infobulle, ou nil si l'objet n'est pas surveillé
function Watch.TooltipLine(id)
  local w = id and AHLedgerDB and AHLedgerDB.watch and AHLedgerDB.watch.items and AHLedgerDB.watch.items[id]
  if not w then return nil end
  local s = stateDB()[id]
  local last = s and s.last and (" · alerte " .. date("%d/%m %H:%M", s.last.t)) or ""
  return "Surveillé", Watch.Describe(w) .. last
end

function Watch.PrintList()
  local rows = Watch.Rows()
  if #rows == 0 then ns.print("Liste de surveillance vide : /ahl surveiller <lien ou nom> achat 1g20s") return end
  table.sort(rows, function(a, b) return itemName(a.id) < itemName(b.id) end)
  ns.print(("Surveillance (%d objets, son %s) :"):format(#rows, Watch.DB().sound and "activé" or "coupé"))
  for _, r in ipairs(rows) do
    ns.print(("%s : %s — actuel %s%s"):format(Watch.Link(r.id), r.rules, r.price and (ns.money(r.price) .. "/u") or "?",
      r.lastT and (" — alerte " .. date("%d/%m %H:%M", r.lastT) .. " : " .. r.lastWhy) or ""))
  end
end

------------------------------------------------------------------------
-- Commandes : /ahl surveiller <lien ou nom> [achat <prix>] [vente <prix>] [signal <nom>] [variation <N>%] [stock <Z>]
--             /ahl surveiller liste | retirer <objet> | son on|off
------------------------------------------------------------------------
local HELP = "/ahl surveiller <lien ou nom> [achat <prix>] [vente <prix>] [signal pénurie|afflux|hausse|baisse] [variation 20%] [stock 50] · liste · retirer <objet> · son on|off. Prix : 1g20s, 35s, 12c ; « off » retire une règle."

-- Découpe « <objet> <options> » : renvoie le texte de l'objet et la liste des mots d'options
function Watch.SplitArgs(args)
  local itemText, rest
  local linkEnd = args:find("|h|r", 1, true)
  if args:find("|H", 1, true) and linkEnd then
    itemText, rest = args:sub(1, linkEnd + 3), args:sub(linkEnd + 4)
  else
    local words, cut = {}, nil
    for w in args:gmatch("%S+") do words[#words + 1] = w end
    for i = 2, #words do
      if KEYWORDS[words[i]:lower()] then cut = i break end
    end
    cut = cut or (#words + 1)
    itemText = table.concat(words, " ", 1, cut - 1)
    rest = table.concat(words, " ", cut)
  end
  local opts = {}
  for w in (rest or ""):gmatch("%S+") do opts[#opts + 1] = w end
  return itemText, opts
end

-- Lit les options. Renvoie changes, ou nil et un message.
function Watch.ParseOptions(opts)
  local changes, i = {}, 1
  while i <= #opts do
    local key = KEYWORDS[opts[i]:lower()]
    if not key then return nil, "mot inattendu : « " .. opts[i] .. " »" end
    i = i + 1
    local words = {}
    while i <= #opts and not KEYWORDS[opts[i]:lower()] do words[#words + 1] = opts[i]; i = i + 1 end
    local val = table.concat(words, " ")
    local low = val:lower()
    if val == "" then return nil, "valeur manquante après « " .. key .. " »" end
    if low == "off" then
      changes[key] = false
    elseif key == "buy" or key == "sell" then
      local c = Watch.ParseMoney(val)
      if not c or c <= 0 then return nil, "prix illisible : « " .. val .. " » (ex. 1g20s, 35s, 12c)" end
      changes[key] = c
    elseif key == "pct" then
      local n = tonumber(low:match("^(%d+%.?%d*)%s*%%?$") or "")
      if not n or n <= 0 then return nil, "variation illisible : « " .. val .. " » (ex. 20%)" end
      changes.pct = n / 100
    elseif key == "stock" then
      local n = tonumber(low)
      if not n or n <= 0 then return nil, "stock illisible : « " .. val .. " »" end
      changes.stock = math.floor(n)
    elseif key == "sig" then
      for _, word in ipairs(words) do
        local name = SIG_ALIAS[word:lower()]
        if not name then return nil, "signal inconnu : « " .. word .. " » (pénurie, afflux, hausse, baisse, pic, demande+)" end
        changes.sig = changes.sig or {}
        changes.sig[name] = true
      end
    end
  end
  return changes
end

function Watch.Command(rest)
  rest = (rest or ""):match("^%s*(.-)%s*$")
  local sub, args = rest:match("^(%S*)%s*(.-)$")
  local low = (sub or ""):lower()
  if rest == "" then
    ns.print(HELP)
    Watch.PrintList()
  elseif low == "liste" or low == "list" then
    Watch.PrintList()
  elseif low == "son" then
    local d = Watch.DB()
    if args == "on" then d.sound = true elseif args == "off" then d.sound = false else d.sound = not d.sound end
    ns.print("Son des alertes de surveillance : " .. (d.sound and "activé" or "coupé"))
  elseif low == "retirer" or low == "enlever" then
    local id, err = Watch.FindItem(args, Watch.DB().items)
    if not id then ns.print("Surveillance : " .. err) return end
    if Watch.Remove(id) then ns.print(Watch.Link(id) .. " n'est plus surveillé.")
    else ns.print(Watch.Link(id) .. " n'était pas surveillé.") end
  else
    local itemText, opts = Watch.SplitArgs(rest)
    local id, err = Watch.FindItem(itemText)
    if not id then ns.print("Surveillance : " .. err) return end
    local changes, perr = Watch.ParseOptions(opts)
    if not changes then ns.print("Surveillance : " .. perr .. ". " .. HELP) return end
    local w = Watch.Set(id, changes)
    ns.print(("Surveillé : %s — %s. Vérifié à chaque scan complet."):format(Watch.Link(id), Watch.Describe(w)))
  end
  if ns.UI and ns.UI.OnData then ns.UI.OnData() end
end
