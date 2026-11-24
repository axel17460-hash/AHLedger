-- AHLedger - Infos marché dans les tooltips d'objets : ce qu'Auctionator n'affiche pas
local _, ns = ...

local UP = "|TInterface\\Buttons\\Arrow-Up-Up:14:14|t"
local DOWN = "|TInterface\\Buttons\\Arrow-Down-Up:14:14|t"

-- "+4.2 %/j" coloré avec flèche
local function trendText(v, suffix)
  if not v then return "|cff808080pas assez de scans|r" end
  local arrow = v >= 0.02 and UP or (v <= -0.02 and DOWN or "")
  return arrow .. ns.pct(v) .. (suffix or "")
end

-- role.crafted : tu le fabriques avec bénéfice ; role.reagent : composant d'une de tes recettes.
-- Le conseil change selon que tu vends l'objet ou que tu l'achètes.
local function verdict(s, role)
  local t = s.trend24 or s.trend
  if not t then return nil end
  role = role or {}
  local rising, falling = t >= 0.03, t <= -0.03
  local cheap = s.vsAvg and s.vsAvg <= -0.10
  local dear = s.vsAvg and s.vsAvg >= 0.10
  if role.crafted then
    if falling then return "|cffffd100Rentable mais prix en baisse : fabrique et vends tout de suite, ne stocke pas|r" end
    if rising then return "|cff40ff40Rentable et prix en hausse : bon moment pour fabriquer|r" end
    return "|cff40ff40Rentable à fabriquer, marché stable|r"
  end
  if role.reagent then
    if falling then return "|cffffd100Composant en baisse : attends pour acheter (vends vite ton surplus)|r" end
    if rising and cheap then return "|cff40ff40Composant en hausse et sous la moyenne : achète maintenant|r" end
    if rising then return "|cffffd100Composant en hausse : achète tôt, garde ton stock|r" end
    if cheap then return "|cff40ff40Composant sous la moyenne : bon moment pour acheter|r" end
    return "|cffccccccMarché stable|r"
  end
  if rising and cheap then return "|cff40ff40Prix en hausse et sous la moyenne : bon moment pour acheter / farmer|r" end
  if rising then return "|cff40ff40Prix en hausse : garder son stock, farmer|r" end
  if falling and dear then return "|cffff5050Prix en baisse et encore cher : vendre maintenant|r" end
  if falling then return "|cffff5050Prix en baisse : vendre vite, ne pas stocker|r" end
  if cheap then return "|cffffd100Prix stable mais sous la moyenne : achat intéressant|r" end
  return "|cffccccccMarché stable|r"
end

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

-- Avertissement « fabrique-le plutôt » : { titre, détail } ou nil
local ALERT = "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:14:14|t "
local function craftUpLines(id)
  local u = ns.Analysis.CraftUp and ns.Analysis.CraftUp(id)
  if not u then return nil end
  local name = u.name or (AHLedgerDB.items[u.out] and AHLedgerDB.items[u.out].n) or ("#" .. u.out)
  local pct = u.gainPct and (" (+%.0f %%)"):format(u.gainPct * 100) or ""
  local head = ("%sFabrique-le plutôt : %s rapporte %s/u contre %s en vente brute%s"):format(
    ALERT, name, ns.money(u.perUnit), ns.money(u.raw), pct)
  local d = { ("%d par fabrication%s, vendu %s"):format(u.q, u.made > 1 and (" (%d fabriqués)"):format(u.made) or "",
    u.sellTo) }
  if u.others > 0 then d[#d + 1] = "autres composants " .. ns.money(u.others) end
  if u.learnCost then d[#d + 1] = "recette à apprendre (" .. ns.money(u.learnCost) .. ")" end
  if u.unitsPerDay then d[#d + 1] = ("l'HV en absorbe ~%.0f/j"):format(u.unitsPerDay) end
  if u.slow then d[#d + 1] = "se vend peu" end
  if u.unsure then d[#d + 1] = "prix affiché, aucune vente vue" end
  return head, table.concat(d, " · ")
end

local function build(id)
  local db = ns.realmDB()
  local s = ns.Analysis.Get(id)
  local meta = AHLedgerDB.items[id]
  local vendor = db.vendor and db.vendor[id]
  local L = {}
  local function kv(a, b) L[#L + 1] = { a, b } end
  local function line(text, r, g, b) L[#L + 1] = { text, r = r or 1, g = g or 1, b = b or 1 } end

  -- HV ou PNJ : en tête, lisible d'un coup d'œil
  local cmp = ns.Bags and ns.Bags.Compare(id)
  if cmp then
    local head, detail = ns.Bags.CompareText(cmp)
    local c = ns.Bags.COLORS[cmp.kind]
    L[#L + 1] = { head, detail, color = c }
  end
  local up, upDetail = craftUpLines(id)
  if up then L[#L + 1] = { up, upDetail, color = { 1, 0.6, 0 } } end

  -- Prix
  if s then
    line(("Données : %d j, %.0f h de marché observées, confiance volume %.0f%%"):format(
      s.days or 0, s.obsHours or 0, (s.confidence or 0) * 100), 0.6, 0.6, 0.6)
    if s.minNow then
      local vs = s.vsAvg and ("  (%s vs moy. 7 j)"):format(ns.pct(s.vsAvg)) or ""
      kv("Achat le moins cher /u", ns.money(s.minNow) .. vs)
    end
    if s.avg7 then kv("Prix affiché moyen 7 j /u", ns.money(s.avg7)) end
    kv("Prix réel de vente /u", s.realPrice and ns.money(s.realPrice) or "|cff808080trop peu de ventes vues|r")
    if s.ev and s.ev.maxSold then
      kv("Plus haut prix vu vendu /u", ns.money(s.ev.maxSold) .. (s.capped and ("  |cffff8040(affiché %s)|r"):format(ns.money(s.listedPrice)) or ""))
    end
    if s.trust then kv("Fiabilité du prix", ns.Trust.LABEL[s.trust] .. " · " .. (s.trustWhy or "")) end
    kv("Net /u (commission, dépôts)", ns.money(s.netExp))
    if meta and meta.s and meta.s > 0 then kv("Rachat par le PNJ /u", ns.money(meta.s)) end
  else
    line("Pas de marché HV observé récemment", 0.6, 0.6, 0.6)
  end
  if vendor and vendor.p and vendor.p > 0 then
    kv("Achat chez un PNJ /u", ("%s  (%s, %s)"):format(ns.money(vendor.p), vendor.npc or "?", vendor.zone or "?"))
  end

  if s then
    -- Tendances
    kv("Tendance 24 h", trendText(s.trend24, s.n24 and (" /j  (%d scans, %.0f h)"):format(s.n24, s.span24) or nil))
    kv("Tendance 7 j" .. (s.trendSrc and " (Auctionator)" or ""), trendText(s.trend, " /j"))
    -- Volume et concurrence
    if s.perDay then kv("Vendus /jour (estim.)", ("%.0f  (stock moyen %.0f)"):format(s.perDay, s.stock or 0)) end
    if s.relistPerDay and s.relistPerDay >= 1 then kv("Relistes écartés /jour", ("%.0f"):format(s.relistPerDay)) end
    local parts = {}
    if s.sellThrough then parts[#parts + 1] = ("%.0f%% vendues"):format(s.sellThrough * 100) end
    if s.stockDays then parts[#parts + 1] = ("%.1f j de stock"):format(s.stockDays) end
    if s.sellers then parts[#parts + 1] = ("%d vendeurs (top %.0f%%)"):format(s.sellers, (s.topShare or 0) * 100) end
    if #parts > 0 then kv("Écoulement", table.concat(parts, " · ")) end
    local book = db.book and ns.Scan.UnpackBook(db.book[id])
    local qty, n, first = bookSummary(book)
    if qty then kv(("En vente : %d u, %d prix"):format(qty, n), first) end
    if s.demandChg or s.stockChg then
      kv("Demande / stock (3 j vs avant)", ("%s / %s"):format(ns.pct(s.demandChg), ns.pct(s.stockChg)))
    end

    -- Opportunités
    local f = book and ns.Analysis.FlipFor(s, book)
    if f and f.kind == "stock" then
      line(("Flip à stocker : acheter %d jusqu'à %s, revendre %s quand le prix remonte → ~+%s espéré"):format(
        f.qty, ns.money(f.maxBuy), ns.money(f.resale), ns.money(f.profit)), 0.4, 0.8, 1)
      if f.known then
        line(("  %d creux sur %d remontés, en ~%s j (lent : %s j) ; sans rebond %s"):format(f.recovered, f.events,
          tostring(f.wait or "?"), tostring(f.slow or "?"), ((f.ifDown >= 0 and "+" or "") .. ns.money(f.ifDown))), 0.7, 0.7, 0.7)
      else
        line(("  Rebond encore inconnu (%d creux vus) : teste petit ; sans rebond %s"):format(
          f.events or 0, ((f.ifDown >= 0 and "+" or "") .. ns.money(f.ifDown))), 1, 0.6, 0)
      end
      if f.weekday then
        line(("  Meilleur jour pour vendre : %s (+%.0f %%)"):format(f.weekday.name, f.weekday.gain * 100), 0.7, 0.7, 0.7)
      end
    elseif f then
      line(("Flip : acheter %d jusqu'à %s, revendre tout de suite %s → +%s (ROI %.0f%%)"):format(
        f.qty, ns.money(f.maxBuy), ns.money(f.resale), ns.money(f.profit), f.roi * 100), 0.4, 1, 0.4)
    end
    local held = ns.Ledger.Holds()[id]
    if held and held.units > 0 then
      line(("Tes reventes : %d achetés puis revendus, gardés ~%.1f j, %s/u"):format(
        held.units, held.days, (held.profit >= 0 and "+" or "-") .. ns.money(math.abs(held.profit))), 0.7, 0.7, 0.7)
    end
    local vf = vendor and ns.Analysis.VendorFlip(id, s, vendor, ns.Analysis.RealSales())
    if vf then
      if vf.reliable then
        line(("PNJ → HV : +%s/u net, vise ~%.0f/j"):format(ns.money(vf.margin), vf.vol), 0.4, 1, 0.4)
      else
        line(("PNJ → HV : +%s/u net, à tester (%s) : %d u d'abord"):format(ns.money(vf.margin), vf.why, vf.testQty or 1),
          1, 0.6, 0)
      end
    end
  end

  -- Métiers : ce que tu fabriques avec, ou ce que ça te coûte à fabriquer
  local role = {}
  if ns.Prof then
    for prof, list in pairs(ns.Prof.Recipes()) do
      local r = list[id]
      if r then
        for _, c in ipairs(ns.Analysis.Crafts()) do
          if c.id == id and c.prof == prof then
            if c.cost then
              if c.profit and c.profit > 0 then role.crafted = true end
              line(("Tu le fabriques : coût %s, bénéfice %s (%s)"):format(ns.money(c.cost), ns.money(c.profit), c.sellTo or "?"),
                0.6, 0.9, 1)
            else
              line(("Tu le fabriques (%d composants sans prix)"):format(c.missing), 0.6, 0.9, 1)
            end
            break
          end
        end
      end
    end
    local uses = {}
    for _, list in pairs(ns.Prof.Recipes()) do
      for outId, r in pairs(list) do
        if r.r[id] then uses[#uses + 1] = ("%s (%d)"):format(r.n or (AHLedgerDB.items[outId] and AHLedgerDB.items[outId].n) or "?", r.r[id]) end
      end
    end
    if #uses > 0 then
      role.reagent = true
      table.sort(uses)
      local more = #uses > 3 and (" +%d"):format(#uses - 3) or ""
      line("Composant de : " .. table.concat(uses, ", ", 1, math.min(3, #uses)) .. more, 0.6, 0.9, 1)
    elseif ns.Prof.Related()[id] == "dépeçage" then
      line("Tu peux le dépecer", 0.6, 0.9, 1)
    end

    -- Ton stock et ton conseil
    local c = ns.Prof.Char()
    local nb, nk = (c.bags or {})[id] or 0, (c.bank or {})[id] or 0
    if nb + nk > 0 then
      local a = ns.Bags.Advise(id, nb + nk)
      local adv = ""
      if a then
        adv = " : " .. a.action .. (a.post and (" à %s/u, %d à la fois"):format(ns.money(a.post), a.postQty or 1) or "")
          .. (" (%s)"):format(ns.money(a.value))
      end
      line(("Tu en as %d (sacs %d, banque %d)%s"):format(nb + nk, nb, nk, adv), 1, 0.82, 0)
    end
  end

  -- Tes ventes réelles (courriers d'HV)
  local real = ns.Analysis.RealSales()[id]
  if real and (real.sold + real.bought + real.expired) > 0 then
    kv(("Toi, %d j"):format(ns.Ledger.DAYS), ("%d vendus%s, %d expirés, %d achetés"):format(
      real.sold, real.avgSale and (" à " .. ns.money(real.avgSale)) or "", real.expired, real.bought))
  end

  if s then
    local v = verdict(s, role)
    if v then line(v) end
    local sig = {}
    for _, x in ipairs(s.signals) do if x ~= "hausse" and x ~= "baisse" then sig[#sig + 1] = x end end
    if #sig > 0 then line(table.concat(sig, " · "), 1, 0.82, 0) end
  end
  if not s and #L == 1 then return {} end -- rien d'autre à dire qu'« aucun marché » : on n'encombre pas
  return L
end

-- Version courte (hors HV par défaut) : HV ou PNJ, puis prix et tendance sur une ligne
local function buildCompact(id)
  local L = {}
  local cmp = ns.Bags and ns.Bags.Compare(id)
  if cmp then
    local head = ns.Bags.CompareText(cmp)
    local c = ns.Bags.COLORS[cmp.kind]
    L[#L + 1] = { head, r = c[1], g = c[2], b = c[3] }
  end
  local up = craftUpLines(id)
  if up then L[#L + 1] = { up, r = 1, g = 0.6, b = 0 } end
  local s = ns.Analysis.Get(id)
  local price = s and (s.minNow or s.realPrice or s.avg7)
  if price then
    local t = s.trend24 or s.trend
    L[#L + 1] = { "HV /u", ns.money(price) .. (t and ("  " .. trendText(t, " /j")) or "") }
  end
  return L
end

local function addLines(tooltip, id)
  if not id or not AHLedgerDB then return end
  local mode = ns.Options.TooltipMode()
  local shiftHint = mode ~= "full" and ns.Options.Get("ttShift")
  if mode == "off" then return end
  local now = GetTime and GetTime() or time()
  local key = mode .. ":" .. id
  local c = cache[key]
  if not (c and c.ver == ns.dataVersion and now - c.t < 3) then
    c = { t = now, ver = ns.dataVersion, lines = mode == "compact" and buildCompact(id) or build(id) }
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
    if l.color then
      tooltip:AddLine(l[1], l.color[1], l.color[2], l.color[3])
      tooltip:AddLine(l[2], GRAY[1], GRAY[2], GRAY[3], true)
    elseif l[2] then
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
