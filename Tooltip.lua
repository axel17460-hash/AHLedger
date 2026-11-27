-- AHLedger - Infobulle d'objet : la décision (que faire, à quel prix, combien) et ses preuves.
-- Rien hors de l'HV. À l'HV, version complète par défaut (les chiffres qui justifient la décision,
-- sans tendances ni signaux spéculatifs) ou courte (la décision et sa raison) ; Maj : la complète.
local _, ns = ...

-- Lignes du tooltip : { gauche, droite } ou { texte, r, g, b }. Mises en cache quelques secondes
-- (le jeu redemande le tooltip en continu tant que la souris reste dessus).
local GRAY, WHITE = { 0.8, 0.8, 0.8 }, { 1, 1, 1 }
local cache = {}

local function bookSummary(book)
  if not (book and book.levels and #book.levels > 0) then return nil end
  local qty, parts = 0, {}
  for i, l in ipairs(book.levels) do
    qty = qty + l[2]
    if i <= 3 then parts[#parts + 1] = ("%d × %s"):format(l[2], ns.money(l[1])) end
  end
  if #book.levels > 3 then parts[#parts + 1] = "…" end
  return qty, #book.levels, table.concat(parts, ", ")
end

-- Décision en tête : verdict coloré, raison et preuves en gris, avertissements en orange
-- (compact : le premier avertissement à la suite de la raison, 2 lignes en tout)
local function decision(L, id, compact)
  local n = ns.Bags.Count(id)
  local d = ns.Decide.For(id, math.max(n, 1))
  if not d then return nil, n end
  local c = ns.Decide.COLORS[d.action] or WHITE
  L[#L + 1] = { ns.Decide.Line(d), r = c[1], g = c[2], b = c[3] }
  -- objet que tu fabriques : le prix à partir duquel la vente est rentable, coloré selon le prix du moment
  local cost, state = ns.Decide.CostLine(d)
  if cost then
    local cc = ns.Decide.COST_COLORS[state] or WHITE
    L[#L + 1] = { cost, r = cc[1], g = cc[2], b = cc[3] }
  end
  local why = ns.Decide.Why(d, nil, compact and 2 or nil, true)
  if compact and d.warn[1] then why = why .. " · |cffff9900" .. d.warn[1] .. "|r" end
  L[#L + 1] = { why, r = GRAY[1], g = GRAY[2], b = GRAY[3] }
  if not compact then
    for _, w in ipairs(d.warn) do L[#L + 1] = { w, r = 1, g = 0.6, b = 0 } end
  end
  return d, n
end

-- Une recherche faite après le dernier scan a vu moins cher que lui : le conseil est périmé
local function liveLine(L, id)
  local w = ns.Live and ns.Live.Warning(id)
  if w then L[#L + 1] = { w, r = 1, g = 0.6, b = 0 } end
end

-- Verdicts du bilan allumés sur les sacs : la raison de la bande de couleur de la case, à sa couleur
local function verdictLine(L, id)
  local v = ns.BagMarks and ns.BagMarks.VerdictIfReady(id)
  local spec = v and ns.BagMarks.VERDICT[v.kind]
  if not spec then return end
  L[#L + 1] = { ("Bilan : %s · %s"):format(spec.label, v.why or ""), r = spec.color[1], g = spec.color[2], b = spec.color[3] }
end

local function build(id)
  local db = ns.realmDB()
  local s = ns.Analysis.Get(id)
  local L = {}
  local function kv(a, b) L[#L + 1] = { a, b } end
  local function line(text, r, g, b) L[#L + 1] = { text, r = r or 1, g = g or 1, b = b or 1 } end

  local d, n = decision(L, id)
  liveLine(L, id)
  if d and d.alt then line("Sinon : " .. ns.Decide.AltLine(d), 0.7, 0.7, 0.7) end
  verdictLine(L, id)
  if n > 0 then
    local c = ns.Prof.Char()
    kv("Tu en as", ("%d (sacs %d, banque %d)"):format(n, (c.bags or {})[id] or 0, (c.bank or {})[id] or 0))
  end
  -- prix de revient : seulement s'il en vient d'un achat ou d'une fabrication relevés (le reste vaut
  -- sa valeur brute, déjà dans la décision)
  if d and d.basis and d.basis.known > 0 then kv("Prix de revient", ns.Decide.UnitCostText(d.basis)) end

  -- Les chiffres derrière la décision
  local book = db.book and ns.Scan.UnpackBook(db.book[id])
  local qty, levels, first = bookSummary(book)
  if qty then kv(("En vente : %d u, %d prix"):format(qty, levels), first) end
  if s then
    local v = s.surePerDay
    local per = not v and "?" or v >= 10 and ("%.0f"):format(v) or (("%.1f"):format(v):gsub("%.0$", ""))
    if s.measured then
      local st = s.stReliable and (", %.0f %% partent"):format(s.sellThrough * 100) or ""
      kv(("Ventes sûres /j (scans 0.9, %.0f h)"):format(s.obs9Hours), ("%s, %d j sur 7%s"):format(per, s.salesDays or 0, st))
    else
      -- avant 12 h de scans 0.9, le chiffre compte encore des retraits : on le dit
      kv("Disparitions /j (anciens scans)", ("%s, retraits compris"):format(per))
    end
    if s.stockDays then kv("Stock en rayon", ("%.1f j de ventes"):format(s.stockDays)) end
  end
  -- déjà cité dans les preuves de la décision, sauf quand elle dit PNJ
  local usual, src, days = ns.Analysis.UsualMin(id, s)
  if usual and not (d and d.action ~= "PNJ") then kv(("Plus bas habituel (%s, %d j)"):format(src, days), ns.money(usual)) end
  local eqText = ns.Market and ns.Market.EqText(id)
  if eqText and not (d and d.action ~= "PNJ") then kv("Prix auquel il part", eqText) end
  local real = ns.Analysis.RealSales()[id]
  if real and (real.sold + real.bought + real.expired) > 0 then
    kv(("Toi, %d j (courrier)"):format(ns.Ledger.DAYS), ("%d vendus%s, %d expirés, %d achetés"):format(
      real.sold, real.avgSale and (" à " .. ns.money(real.avgSale)) or "", real.expired, real.bought))
  end
  -- le rachat PNJ est déjà dans la décision (sa ligne ou ses preuves) : seulement s'il n'y en a pas
  local sell = ns.Decide.VendorPrice(id)
  if sell > 0 and not d then kv("Rachat par le PNJ /u", ns.money(sell)) end
  local vendor = db.vendor and db.vendor[id]
  if vendor and vendor.p and vendor.p > 0 then
    kv("Achat chez un PNJ /u", ("%s  (%s, %s)"):format(ns.money(vendor.p), vendor.npc or "?", vendor.zone or "?"))
  end

  -- Occasions d'achat : seulement celles qui reposent sur des ventes prouvées
  if s and not ns.Analysis.Stale() then
    local f = book and ns.Analysis.FlipFor(s, book)
    if f and f.kind == "stock" then
      line(("Flip à stocker : acheter %d jusqu'à %s, revendre %s au rebond (%d creux sur %d remontés, ~%s j) → ~+%s"):format(
        f.qty, ns.money(f.maxBuy), ns.money(f.resale), f.recovered, f.events, tostring(f.wait or "?"), ns.money(f.profit)), 0.4, 0.8, 1)
    elseif f then
      line(("Flip : acheter %d jusqu'à %s, revendre tout de suite %s → +%s"):format(
        f.qty, ns.money(f.maxBuy), ns.money(f.resale), ns.money(f.profit)), 0.4, 1, 0.4)
    end
    local vf = vendor and ns.Analysis.VendorFlip(id, s, vendor, ns.Analysis.RealSales())
    if vf and vf.reliable then
      line(("PNJ → HV : +%s/u net, vise ~%.0f/j"):format(ns.money(vf.margin), vf.vol), 0.4, 1, 0.4)
    end
  end

  -- Métiers : tu le fabriques, ou il sert à une de tes recettes
  if ns.Prof then
    for _, list in pairs(ns.Prof.Recipes()) do
      local r = list[id]
      if r then
        -- le verdict unique de Decide (matière brute ou fabriqué), pas le prix de la décision du
        -- moment (0 pour « Garder », bradé pour « Attendre »)
        local rc = ns.Decide.RawOrCraft(id, r)
        if rc.cost and rc.ov then
          line(("Tu le fabriques : composants vendus bruts %s (coût %s), fabriqué %s (%s) → %s"):format(ns.money(rc.raw), ns.money(rc.cost),
            ns.money(rc.craft), rc.to, rc.ok and ("fabrique : +%s"):format(ns.money(rc.gain))
              or rc.gain > 0 and ("marge faible : +%s"):format(ns.money(rc.gain))
              or ("ne fabrique pas : %s"):format(ns.money(rc.gain))), 0.6, 0.9, 1)
        end
        break
      end
    end
    local uses = {}
    for _, list in pairs(ns.Prof.Recipes()) do
      for outId, r in pairs(list) do
        if r.r[id] then uses[#uses + 1] = ("%s (%d)"):format(r.n or (AHLedgerDB.items[outId] and AHLedgerDB.items[outId].n) or "?", r.r[id]) end
      end
    end
    if #uses > 0 then
      table.sort(uses)
      local more = #uses > 3 and (" +%d"):format(#uses - 3) or ""
      line("Composant de : " .. table.concat(uses, ", ", 1, math.min(3, #uses)) .. more, 0.6, 0.9, 1)
    end
  end
  return L
end

-- Version courte (option de l'infobulle à l'HV) : la décision et sa raison, 2 lignes sous le titre
-- (plus le verdict du bilan, quand ses bandes sont allumées sur les sacs, et l'avertissement de
-- recherche quand une recherche récente a vu moins cher que le dernier scan)
local function buildCompact(id)
  local L = {}
  decision(L, id, true)
  liveLine(L, id)
  verdictLine(L, id)
  return L
end

local function addLines(tooltip, id)
  if not id or not AHLedgerDB or not ns.ahOpen then return end -- hors de l'HV : rien
  local mode = ns.Options.TooltipMode()
  local shiftHint = mode ~= "full" and ns.Options.Get("ttShift")
  if mode == "off" then return end
  local now = GetTime and GetTime() or time()
  local key = mode .. ":" .. id
  local c = cache[key]
  if not (c and c.ver == ns.dataVersion and c.opt == ns.optVersion and now - c.t < 3) then
    c = { t = now, ver = ns.dataVersion, opt = ns.optVersion, lines = mode == "compact" and buildCompact(id) or build(id) }
    cache[key] = c
  end
  if #c.lines == 0 then return end
  if mode == "compact" then
    if shiftHint then
      tooltip:AddDoubleLine("|cff33ccffAHLedger|r", "Maj : détails", 1, 1, 1, 0.5, 0.5, 0.5)
    else
      tooltip:AddLine("|cff33ccffAHLedger|r")
    end
  else
    tooltip:AddLine(" ")
    tooltip:AddLine("|cff33ccffAHLedger|r")
  end
  for _, l in ipairs(c.lines) do
    if l[2] then
      tooltip:AddDoubleLine(l[1], l[2], GRAY[1], GRAY[2], GRAY[3], WHITE[1], WHITE[2], WHITE[3])
    else
      tooltip:AddLine(l[1], l.r, l.g, l.b, true)
    end
  end
  tooltip:Show()
end

local function idFromTooltip(tooltip)
  local _, link = tooltip:GetItem()
  return ns.itemIdFromLink(link)
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip == GameTooltip or tooltip == ItemRefTooltip then
      ns.safe("tooltip", addLines, tooltip, data and data.id or idFromTooltip(tooltip))
    end
  end)
else
  for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tt then tt:HookScript("OnTooltipSetItem", function(self) ns.safe("tooltip", addLines, self, idFromTooltip(self)) end) end
  end
end
