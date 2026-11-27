-- Tests de la liste de surveillance (Watch.lua) : parseur de prix, commandes, déclenchement, anti-spam,
-- réarmement, scan réel, infobulle, interface. Lancé par tests/test_watch.py (fournit la table NS).
local ns = NS
local Watch = ns.Watch
local fails = {}
local function check(name, cond, extra)
  if not cond then fails[#fails + 1] = name .. (extra ~= nil and (" : " .. tostring(extra)) or "") end
end
local function plain(s) return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local function lastLog(n)
  local out = {}
  for i = math.max(1, #LOG - n + 1), #LOG do out[#out + 1] = plain(LOG[i]) end
  return table.concat(out, "\n")
end
local function cmd(s) SlashCmdList.AHLEDGER("surveiller " .. s) end

------------------------------------------------------------------------
-- Parseur de prix
------------------------------------------------------------------------
local P = Watch.ParseMoney
check("1g20s", P("1g20s") == 12000, P("1g20s"))
check("1g 20s 5c", P("1g 20s 5c") == 12005, P("1g 20s 5c"))
check("35s", P("35s") == 3500)
check("12c", P("12c") == 12)
check("nombre seul = cuivre", P("250") == 250)
check("1.5g", P("1.5g") == 15000)
check("majuscules 2G", P("2G") == 20000)
check("2po50pa (client français)", P("2po50pa") == 25000, P("2po50pa"))
check("illisible : abc", P("abc") == nil)
check("illisible : vide", P("") == nil and P(nil) == nil)
check("illisible : 12x", P("12x") == nil)
check("illisible : unité répétée 1g1g", P("1g1g") == nil)
check("illisible : 1g 20 (ambigu)", P("1g 20") == nil)
check("illisible : -5s", P("-5s") == nil)

------------------------------------------------------------------------
-- Commandes
------------------------------------------------------------------------
AHLedgerDB.items[4306] = { n = "Silk Cloth", s = 150, c = 7 }
AHLedgerDB.items[4338] = { n = "Mageweave Cloth", s = 250, c = 7 }
AHLedgerDB.items[2589] = { n = "Linen Cloth", s = 13, c = 7 }
AHLedgerDB.items[2592] = { n = "Wool Cloth", s = 33, c = 7 }

cmd("Silk Cloth achat 1g20s vente 2g signal pénurie")
local w = Watch.Get(4306)
check("ajout par nom : règles", w and w.buy == 12000 and w.sell == 20000 and w.sig and w.sig["pénurie"], w and Watch.Describe(w))
check("ajout : confirmation dans le chat", lastLog(1):find("Surveillé") ~= nil, lastLog(1))
cmd("|cffffffff|Hitem:4338::::|h[Mageweave Cloth]|h|r achat 1g 5s variation 20% stock 50")
w = Watch.Get(4338)
check("ajout par lien, prix avec espace", w and w.buy == 10500 and math.abs(w.pct - 0.2) < 1e-9 and w.stock == 50, w and Watch.Describe(w))
cmd("linen signal penurie hausse")
w = Watch.Get(2589)
check("nom partiel, signal sans accent, deux signaux", w and w.sig and w.sig["pénurie"] and w.sig.hausse, w and Watch.Describe(w))
cmd("Silk Cloth vente off")
check("off retire une règle, garde les autres", Watch.Get(4306).sell == nil and Watch.Get(4306).buy == 12000)
cmd("cloth achat 1g")
check("nom ambigu : refusé", lastLog(1):find("plusieurs objets") ~= nil, lastLog(1))
cmd("Unobtainium achat 1g")
check("objet inconnu : refusé", lastLog(1):find("objet inconnu") ~= nil, lastLog(1))
cmd("Wool Cloth achat 1x")
check("prix illisible : refusé", lastLog(1):find("prix illisible") ~= nil and Watch.Get(2592) == nil, lastLog(1))
cmd("Wool Cloth signal soleil")
check("signal inconnu : refusé", lastLog(1):find("signal inconnu") ~= nil and Watch.Get(2592) == nil, lastLog(1))
cmd("liste")
check("liste : objets affichés", lastLog(4):find("Silk Cloth") and lastLog(4):find("Mageweave"), lastLog(4))
cmd("Wool Cloth stock 10")
cmd("retirer wool")
check("retirer par nom partiel", Watch.Get(2592) == nil and lastLog(1):find("n'est plus surveillé") ~= nil, lastLog(1))
cmd("")
check("sans argument : aide", lastLog(6):find("/ahl surveiller") ~= nil)

------------------------------------------------------------------------
-- Déclenchement, anti-spam et réarmement (marché simulé)
------------------------------------------------------------------------
local db = ns.realmDB()
local STATS = {}
local realGet = ns.Analysis.Get
ns.Analysis.Get = function(id) return STATS[id] end
local sounds = 0
PlaySound = function() sounds = sounds + 1 end
SOUNDKIT = { RAID_WARNING = 8959 }
local function scan(lastMin, q)
  db.lastMin = lastMin
  local before = #LOG
  local alerts = Watch.OnScan(db, time(), q)
  advance(600)
  local msgs = {}
  for i = before + 1, #LOG do msgs[#msgs + 1] = plain(LOG[i]) end
  return alerts, msgs
end
local function alertFor(alerts, id)
  for _, a in ipairs(alerts) do if a.id == id then return table.concat(a.why, " ; ") end end
end
-- 4306 : achat ≤ 1g20s + pénurie ; 4338 : achat ≤ 1g05s, ±20 %, stock < 50 ; 2589 : pénurie + hausse
STATS[4306] = { signals = {} }
STATS[4338] = { signals = {}, vsAvg = -0.05, avg7 = 11000 }
STATS[2589] = { signals = { "hausse" } }
local a, msgs = scan({ [4306] = 13000, [4338] = 11000, [2589] = 100 }, { [4306] = { q = 100 }, [4338] = { q = 200 }, [2589] = { q = 500 } })
check("1er scan : seule la hausse du lin alerte", #a == 1 and alertFor(a, 2589) == "signal hausse", #a)
check("alerte dans le chat avec le lien", msgs[1] and msgs[1]:find("Surveillance") and msgs[1]:find("Linen Cloth") and msgs[1]:find("signal hausse"), msgs[1])
check("son joué une fois", sounds == 1, sounds)

a = scan({ [4306] = 11900, [4338] = 11000, [2589] = 100 }, { [4306] = { q = 100 }, [4338] = { q = 200 }, [2589] = { q = 500 } })
check("prix sous le seuil : alerte achat avec le prix", alertFor(a, 4306) and plain(alertFor(a, 4306)):find("achat : 1g 19s/u ≤ 1g 20s") ~= nil, alertFor(a, 4306))
check("anti-spam : la hausse déjà signalée se tait", alertFor(a, 2589) == nil)
a = scan({ [4306] = 11000, [4338] = 11000, [2589] = 100 }, { [4306] = { q = 100 }, [4338] = { q = 200 }, [2589] = { q = 500 } })
check("anti-spam : prix toujours sous le seuil, pas de 2e alerte", #a == 0, #a)
-- remonte juste au-dessus du seuil, dans la marge de 3 % : pas de réarmement
a = scan({ [4306] = 12200 }, { [4306] = { q = 100 } })
check("dans la marge : toujours désarmé", Watch.State(4306).on.buy == true)
a = scan({ [4306] = 11800 }, { [4306] = { q = 100 } })
check("oscillation dans la marge : pas d'alerte", alertFor(a, 4306) == nil)
-- remonte nettement : réarmé, puis redescend : nouvelle alerte
a = scan({ [4306] = 13000 }, { [4306] = { q = 100 } })
check("condition retombée : réarmé", Watch.State(4306).on.buy == nil)
a = scan({ [4306] = 11500 }, { [4306] = { q = 100 } })
check("réarmé puis redéclenché : nouvelle alerte", alertFor(a, 4306) ~= nil)
-- objet absent du scan : prix inconnu (ni alerte ni réarmement), stock 0 < 50 alerte
-- (les scans ci-dessus sans 4338 l'ont déjà vu à 0 en vente : on repart d'un état armé)
Watch.State(4338).on = {}
a = scan({}, {})
check("absent : prix inconnu, état gardé", Watch.State(4306).on.buy == true and alertFor(a, 4306) == nil)
check("absent : stock 0 < 50 alerte", alertFor(a, 4338) and alertFor(a, 4338):find("stock : 0 en vente < 50") ~= nil, alertFor(a, 4338))
-- signal apparu, puis disparu (réarme), puis revenu
STATS[4306].signals = { "pénurie" }
a = scan({ [4306] = 11500 }, { [4306] = { q = 100 } })
check("signal apparu : alerte", alertFor(a, 4306) == "signal pénurie", alertFor(a, 4306))
STATS[4306].signals = {}
scan({ [4306] = 11500 }, { [4306] = { q = 100 } })
check("signal disparu : réarmé", Watch.State(4306).on["sig:pénurie"] == nil)
STATS[4306].signals = { "pénurie" }
a = scan({ [4306] = 11500 }, { [4306] = { q = 100 } })
check("signal revenu : nouvelle alerte", alertFor(a, 4306) == "signal pénurie")
-- pas d'analyse (objet sans historique) : signal inconnu, état gardé
STATS[4306] = nil
scan({ [4306] = 11500 }, { [4306] = { q = 100 } })
check("sans analyse : état du signal gardé", Watch.State(4306).on["sig:pénurie"] == true)
-- variation : -25 % vs moyenne → alerte ; -18 % (entre 80 % et 100 % du seuil) → rien ; -10 % → réarmé
STATS[4338] = { signals = {}, vsAvg = -0.25, avg7 = 14000 }
a = scan({ [4338] = 10500 }, { [4338] = { q = 200 } })
check("variation ≥ 20 % : alerte", alertFor(a, 4338) and plain(alertFor(a, 4338)):find("variation %-25.0%% vs moy. 7 j") ~= nil, alertFor(a, 4338))
check("plusieurs règles à la fois : une seule ligne", alertFor(a, 4338):find("achat") ~= nil and alertFor(a, 4338):find(" ; ") ~= nil, alertFor(a, 4338))
STATS[4338].vsAvg = -0.18
scan({ [4338] = 10500 }, { [4338] = { q = 200 } })
check("variation dans la marge : désarmée", Watch.State(4338).on.pct == true)
STATS[4338].vsAvg = -0.10
scan({ [4338] = 10500 }, { [4338] = { q = 200 } })
check("variation retombée : réarmée", Watch.State(4338).on.pct == nil)
check("stock remonté (200 ≥ 50) : réarmé", Watch.State(4338).on.stock == nil)
-- règle de vente
cmd("Silk Cloth vente 1g50s")
check("modifier les règles réarme l'objet", next(Watch.State(4306).on) == nil)
a = scan({ [4306] = 16000 }, { [4306] = { q = 100 } })
check("vente : prix ≥ seuil alerte", alertFor(a, 4306) and plain(alertFor(a, 4306)):find("vente : 1g 60s/u ≥ 1g 50s") ~= nil, alertFor(a, 4306))
-- son coupé
local s0 = sounds
cmd("son off")
cmd("Silk Cloth achat 2g")
a = scan({ [4306] = 16000 }, { [4306] = { q = 100 } })
check("son coupé : alerte sans son", #a == 1 and sounds == s0, sounds - s0)
cmd("son on")
ns.Analysis.Get = realGet

------------------------------------------------------------------------
-- Scan réel : Scan.Finish appelle la surveillance
------------------------------------------------------------------------
cmd("retirer 4338"); cmd("retirer 2589")
cmd("Silk Cloth achat 15s vente off signal off")
AUCTIONS = { { id = 4306, count = 20, buyout = 20000, owner = "A", tl = 4 }, { id = 2589, count = 20, buyout = 2000, owner = "B", tl = 4 } }
local before = #LOG
SlashCmdList.AHLEDGER("scan"); runTimers()
local got
for i = before + 1, #LOG do if plain(LOG[i]):find("Surveillance") then got = plain(LOG[i]) end end
check("scan complet : alerte de la surveillance", got and got:find("Silk Cloth") and got:find("achat : 10s 00c/u ≤ 15s") ~= nil, got or lastLog(3))
check("aucune erreur pendant le scan", #ns.errors == 0, ns.errors[1])

------------------------------------------------------------------------
-- Infobulle et interface
------------------------------------------------------------------------
local label, text = Watch.TooltipLine(4306)
check("infobulle : objet surveillé", label == "Surveillé" and plain(text):find("achat ≤ 15s") and plain(text):find("alerte"), text)
check("infobulle : objet non surveillé", Watch.TooltipLine(4338) == nil)
TT = {}
GameTooltip.AddLine = function(_, t) TT[#TT + 1] = t end
GameTooltip.AddDoubleLine = function(_, x, y) TT[#TT + 1] = x .. " = " .. y end
GameTooltip.GetItem = function() return "Silk", "|Hitem:4306::::|h" end
GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
local found
for _, l in ipairs(TT) do if plain(l):find("^Surveillé = ") then found = plain(l) end end
check("infobulle du jeu : ligne Surveillé", found ~= nil, table.concat(TT, " / "))

SlashCmdList.AHLEDGER("")
local UI = ns.UI
UI.SetMode("snipe")
check("Revente PNJ : bouton de vue vers la surveillance", UI.viewButton.shown and plain(UI.viewButton.text) == "Vue : surveillance", UI.viewButton.text)
UI.SetMode("watch")
local rows = {}
for _, row in pairs(UI.rows) do
  if row.shown then
    local cells = {}
    for i = 1, 10 do if row.cells[i].text and row.cells[i].text ~= "" then cells[#cells + 1] = plain(row.cells[i].text) end end
    rows[#rows + 1] = table.concat(cells, " | ")
  end
end
check("vue Surveillance : une ligne", #rows == 1, #rows)
check("vue Surveillance : objet, règle, prix, alerte", rows[1] and rows[1]:find("Silk Cloth") and rows[1]:find("achat ≤ 15s")
  and rows[1]:find("10s 00c") and rows[1]:find("alerte"), rows[1])
check("vue Surveillance : pied de page", plain(UI.footer.text):find("son activé") ~= nil, plain(UI.footer.text))
check("vue Surveillance : onglet Revente PNJ en surbrillance", UI.PARENT.watch == "snipe")
cmd("retirer Silk Cloth")
UI.SetMode("watch")
check("liste vide : explication", UI.empty.shown and plain(UI.empty.text):find("Aucun objet surveillé") ~= nil)
check("aucune erreur", #ns.errors == 0, ns.errors[1])

return fails
