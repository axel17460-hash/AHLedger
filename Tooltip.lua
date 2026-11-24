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
  if u.slow then d[#d + 1] = u.slowWhy or "se vend peu" end
  if u.unsure then d[#d + 1] = "prix affiché, aucune vente vue" end
  return head, table.concat(d, " · ")
end

local GRAYT = "|cff999999"
local function join(t, sep) return table.concat(t, sep or " · ") end
local function signed(v) return (v >= 0 and "+" or "-") .. ns.money(math.abs(v)) end

-- Ce que le jeu et les autres addons écrivent déjà dans l'infobulle d'un objet de tes sacs :
-- prix PNJ (ligne du jeu, et « Vendor » d'Auctionator), nombre possédé (case du sac, comptes
-- de Daylight Bags), prix HV le plus bas (« Auction » d'Auctionator, si activé). On ne le répète pas.
local function auctionatorShowsAuction()
  local C = Auctionator and Auctionator.Config
  if not (C and C.Get and C.Options and C.Options.AUCTION_TOOLTIPS) then return false end
  local ok, v = pcall(C.Get, C.Options.AUCTION_TOOLTIPS)
  return ok and v == true
end
ns.Tooltip = ns.Tooltip or {}
ns.Tooltip.AuctionatorShowsAuction = auctionatorShowsAuction

-- Infobulle complète, regroupée : l'action d'abord, puis une ligne par thème
-- (prix, repères, tendance, marché, opportunités, métiers, toi), la qualité des données en pied.
local function build(id)
  local db = ns.realmDB()
  local s = ns.Analysis.Get(id)
  local vendor = db.vendor and db.vendor[id]
  local L = {}
  local function kv(a, b) L[#L + 1] = { a, b } end
  local function line(text, r, g, b) L[#L + 1] = { text, r = r or 1, g = g or 1, b = b or 1 } end

  -- 1. Quoi faire : HV ou PNJ, fabrique-le plutôt, conseil de marché (rempli plus bas, une fois le rôle connu)
  local cmp = ns.Bags and ns.Bags.Compare(id)
  if cmp then
    local head, detail = ns.Bags.CompareText(cmp)
    L[#L + 1] = { head, detail, color = ns.Bags.COLORS[cmp.kind] }
  end
  local up, upDetail = craftUpLines(id)
  if up then L[#L + 1] = { up, upDetail, color = { 1, 0.6, 0 } } end
  local verdictAt = #L + 1
  L[verdictAt] = false -- réservé

  -- 2. Prix /u : le moins cher maintenant, ce qui part vraiment, ce qui te reste
  if s then
    local p = {}
    if s.minNow and not auctionatorShowsAuction() then
      p[#p + 1] = ns.money(s.minNow) .. (s.vsAvg and (" (%s vs moy.)"):format(ns.pct(s.vsAvg)) or "")
    elseif s.vsAvg then
      p[#p + 1] = "le - cher " .. ns.pct(s.vsAvg) .. " vs moy."
    end
    p[#p + 1] = "réel " .. (s.realPrice and ns.money(s.realPrice) or "|cff808080?|r")
    local net = "net " .. ns.money(s.netExp)
    if s.bias and s.bias < 0.995 then net = net .. (" %s(×%.2f tes ventes)|r"):format(GRAYT, s.bias) end
    p[#p + 1] = net
    kv("Prix /u", join(p))
    if s.spike then
      kv("Pic de prix", ("habituel %s · |cffff8040vends ce que tu as, n'investis pas|r"):format(ns.money(s.usual)))
    end
    -- Repères : moyenne, plus haut vendu (le rachat PNJ est déjà sur la ligne « Vendor » du jeu)
    local r = {}
    if s.avg7 then r[#r + 1] = "moy. 7 j " .. ns.money(s.avg7) end
    if s.ev and s.ev.maxSold then
      r[#r + 1] = "haut vendu " .. ns.money(s.ev.maxSold)
        .. (s.capped and (" |cffff8040(affiché %s)|r"):format(ns.money(s.listedPrice)) or "")
    end
    if #r > 0 then kv("Repères /u", join(r)) end
  else
    line("Pas de marché HV observé récemment", 0.6, 0.6, 0.6)
  end
  if vendor and vendor.p and vendor.p > 0 then
    kv("PNJ vend /u", ("%s  %s(%s, %s)|r"):format(ns.money(vendor.p), GRAYT, vendor.npc or "?", vendor.zone or "?"))
  end

  local book
  if s then
    -- 3. Tendance : court terme, 7 j, et plusieurs mois si l'archive le permet
    kv("Tendance", ("24 h %s · 7 j%s %s"):format(trendText(s.trend24, " /j"),
      s.trendSrc and " (Auct.)" or "", trendText(s.trend, " /j")))
    local lt = ns.History.LongTerm and ns.History.LongTerm(db, id)
    if lt then
      local vs = s.price and (" · maintenant %s"):format(ns.pct(s.price / lt.avg - 1)) or ""
      kv(("Sur %d semaines"):format(lt.weeks), ("moy. %s · %s (%s) → %s (%s)%s"):format(
        ns.money(lt.avg), ns.money(lt.lo), date("%d/%m", lt.loT), ns.money(lt.hi), date("%d/%m", lt.hiT), vs))
    end

    -- 4. Marché : se vend-il, à quel rythme, contre qui
    local sells, sellsWhy = ns.Analysis.Sells(s, ns.Analysis.RealSales()[id])
    kv("Se vend ?", ns.Analysis.SELLS_LABEL[sells])
    if sellsWhy ~= "" then line("  " .. sellsWhy, 0.6, 0.6, 0.6) end
    local m = {}
    if s.perDay then m[#m + 1] = ("%.0f/j"):format(s.perDay) end
    if s.stock then
      m[#m + 1] = ("stock %.0f"):format(s.stock) .. (s.stockDays and (" (%.1f j)"):format(s.stockDays) or "")
    end
    if s.sellers then m[#m + 1] = ("%d vendeurs (top %.0f%%)"):format(s.sellers, (s.topShare or 0) * 100) end
    if s.relistPerDay and s.relistPerDay >= 1 then m[#m + 1] = ("%.0f relistes/j"):format(s.relistPerDay) end
    if s.demandChg or s.stockChg then
      m[#m + 1] = ("3 j : demande %s, stock %s"):format(ns.pct(s.demandChg), ns.pct(s.stockChg))
    end
    if #m > 0 then kv("Marché", join(m)) end
    book = db.book and ns.Scan.UnpackBook(db.book[id])
    local qty, n, first = bookSummary(book)
    if qty then kv(("En vente : %d u, %d prix"):format(qty, n), first) end

    -- 5. Opportunités : flips HV, PNJ → HV
    local f = book and ns.Analysis.FlipFor(s, book, nil, ns.Analysis.Budget())
    local fd = {}
    if f and f.kind == "stock" then
      line(("Flip à stocker : acheter %d jusqu'à %s, revendre %s → ~+%s espéré"):format(
        f.qty, ns.money(f.maxBuy), ns.money(f.resale), ns.money(f.profit)), 0.4, 0.8, 1)
      if f.known then
        fd[#fd + 1] = ("%d creux sur %d remontés, en ~%s j (lent %s j), sans rebond %s"):format(f.recovered, f.events,
          tostring(f.wait or "?"), tostring(f.slow or "?"), (f.ifDown >= 0 and "+" or "") .. ns.money(f.ifDown))
      else
        fd[#fd + 1] = ("|cffff9900rebond inconnu (%d creux vus), teste petit|r, sans rebond %s"):format(
          f.events or 0, (f.ifDown >= 0 and "+" or "") .. ns.money(f.ifDown))
      end
      if f.weekday then
        fd[#fd + 1] = ("Meilleur jour pour vendre : %s (+%.0f %%)"):format(f.weekday.name, f.weekday.gain * 100)
      end
    elseif f then
      line(("Flip : acheter %d jusqu'à %s, revendre tout de suite %s → +%s (ROI %.0f%%)"):format(
        f.qty, ns.money(f.maxBuy), ns.money(f.resale), ns.money(f.profit), f.roi * 100), 0.4, 1, 0.4)
    end
    if f and f.budgetCut then
      fd[#fd + 1] = ("limité par ton or (budget %s)"):format(ns.money(ns.Analysis.Budget() or 0))
    end
    if #fd > 0 then line("  " .. join(fd), 0.7, 0.7, 0.7) end
    local vf = vendor and ns.Analysis.VendorFlip(id, s, vendor, ns.Analysis.RealSales(), ns.Analysis.Budget())
    if vf then
      if vf.reliable then
        line(("PNJ → HV : +%s/u net, vise ~%.0f/j"):format(ns.money(vf.margin), vf.vol), 0.4, 1, 0.4)
      else
        line(("PNJ → HV : +%s/u net, à tester (%s) : %d u d'abord"):format(ns.money(vf.margin), vf.why, vf.testQty or 1),
          1, 0.6, 0)
      end
    end
  else
    local sells, sellsWhy = ns.Analysis.Sells(s, ns.Analysis.RealSales()[id])
    if sells ~= "unknown" or sellsWhy:find("chez toi") then
      kv("Se vend ?", ns.Analysis.SELLS_LABEL[sells])
      if sellsWhy ~= "" then line("  " .. sellsWhy, 0.6, 0.6, 0.6) end
    end
  end

  -- 6. Métiers : ce que tu fabriques avec, ou ce que ça te coûte à fabriquer
  local role = {}
  if ns.Prof then
    for prof, list in pairs(ns.Prof.Recipes()) do
      if list[id] then
        for _, c in ipairs(ns.Analysis.Crafts()) do
          if c.id == id and c.prof == prof then
            if c.cost then
              if c.profit and c.profit > 0 then role.crafted = true end
              local slow = c.slow and (c.ahValue or 0) > c.vendorValue
                and (" |cffff9933· HV écartée : %s, vends plutôt les composants|r"):format(c.slowWhy) or ""
              line(("Tu le fabriques : coût %s, bénéfice %s (%s)%s"):format(ns.money(c.cost), ns.money(c.profit),
                c.sellTo or "?", slow), 0.6, 0.9, 1)
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

    -- 7. Toi : le conseil pour ton stock (le détail sacs / banque est déjà dans la case et chez Daylight Bags)
    local c = ns.Prof.Char()
    local n = ((c.bags or {})[id] or 0) + ((c.bank or {})[id] or 0)
    local a = n > 0 and ns.Bags.Advise(id, n)
    if a then
      line(("Tes %d : %s%s (%s)"):format(n, a.action,
        a.post and (" à %s/u, %d à la fois"):format(ns.money(a.post), a.postQty or 1) or "", ns.money(a.value)), 1, 0.82, 0)
    end
  end

  -- Tes ventes réelles (courriers d'HV) et tes reventes, sur une ligne
  local real = ns.Analysis.RealSales()[id]
  local held = s and ns.Ledger.Holds()[id]
  local me = {}
  if real and (real.sold + real.bought + real.expired) > 0 then
    me[#me + 1] = ("%d vendus%s, %d expirés, %d achetés"):format(
      real.sold, real.avgSale and (" à " .. ns.money(real.avgSale)) or "", real.expired, real.bought)
  end
  if held and held.units > 0 then
    me[#me + 1] = ("reventes %d u en ~%.1f j, %s/u"):format(held.units, held.days, signed(held.profit))
  end
  if #me > 0 then kv(("Toi, %d j"):format(ns.Ledger.DAYS), join(me)) end

  -- Conseil de marché (en tête) + signaux ; qualité des données en pied
  local v
  if s then
    v = verdict(s, role)
    local sig = {}
    for _, x in ipairs(s.signals) do if x ~= "hausse" and x ~= "baisse" then sig[#sig + 1] = x end end
    if #sig > 0 then v = (v and (v .. "  ") or "") .. "|cffffd100" .. join(sig) .. "|r" end
  end
  if v then L[verdictAt] = { v, r = 1, g = 1, b = 1 } else table.remove(L, verdictAt) end
  if s then
    local q = ("Données : %d j, %.0f h observées, confiance volume %.0f%%"):format(
      s.days or 0, s.obsHours or 0, (s.confidence or 0) * 100)
    if s.trust then q = q .. " · prix " .. ns.Trust.LABEL[s.trust] .. (s.trustWhy and (" (" .. s.trustWhy .. ")") or "") end
    if s.n24 then q = q .. (" · 24 h : %d scans sur %.0f h"):format(s.n24, s.span24) end
    line(q, 0.6, 0.6, 0.6)
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
  local sells = ns.Analysis.Sells(s, ns.Analysis.RealSales()[id])
  -- Auctionator affiche déjà le moins cher : on donne alors le prix réel de vente, ou rien
  local dup = auctionatorShowsAuction()
  local price = s and (dup and s.realPrice or not dup and (s.minNow or s.realPrice or s.avg7))
  local t = s and (s.trend24 or s.trend)
  if price or (dup and t) then
    L[#L + 1] = { dup and "HV réel /u" or "HV /u", (price and ns.money(price) or "")
                  .. (t and ("  " .. trendText(t, " /j")) or "") .. "  · " .. ns.Analysis.SELLS_LABEL[sells] }
  elseif sells ~= "unknown" then
    L[#L + 1] = { "Se vend à l'HV ?", ns.Analysis.SELLS_LABEL[sells] }
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
