# AHLedger — passation pour une session Claude locale

But de ce document : permettre à une session Claude Code qui tourne **sur le PC de jeu** de reprendre le travail sans relire tout l'historique. La session précédente tournait dans le cloud, sans accès au jeu : **rien n'a encore été testé en jeu**. C'est la priorité.

## Le projet
- Addon WoW pour **World of Warcraft: Forever** (Interface 16001, `_forever_`), personnel, gratuit. Il aide le joueur à gagner de l'or à l'hôtel des ventes (HV).
- Personnage principal : **Cyradil Beilar**, rogue elfe de la nuit niv. 39. Métiers : Travail du cuir 161/225, Dépeçage 253/300, Cuisine 174/225, Secourisme 220/225, Crochetage 89, Poisons 190.
- Le joueur utilise **Auctionator**. Forever n'a pas l'API d'HV Classic : scans complets via l'API Retail `C_AuctionHouse.ReplicateItems`, ou en lisant le scan d'Auctionator (`Bridge.lua`).
- Code, commentaires, interface et commits **en français**. Le joueur écrit en anglais ou en français ; réponds dans sa langue.
- Règles Blizzard à respecter : aucune automatisation d'achat ou de vente, aucun scan sans clic du joueur, pas de pub ni de dons.

## Dépôt
- GitHub `axel17460-hash/AHLedger`, branche de travail **`ccr-b6ab2be1-rg4weg`** (version 0.8). `main` est en retard. Ne crée pas de pull request sans demande explicite.
- Tests : `pip install lupa luaparser`, puis `python tests/check_globals.py` et `python tests/run_test.py`. Les deux passent. `tests/harness.lua` simule l'API du jeu (Classic, sauf indication) et 14 jours de marché.
- Workflow GitHub `.github/workflows/tests.yml` : jamais vu tourner (aucune exécution sur la branche au dernier contrôle). Les Actions sont peut-être désactivées sur le dépôt.

## Architecture (ordre de chargement du .toc)
| Fichier | Rôle |
|---|---|
| `Core.lua` | Base `AHLedgerDB`, bus d'événements `ns.on` (les événements inconnus du client sont ignorés et notés), `/ahl …`, `ns.safe` (garde les erreurs dans `ns.errors`) |
| `History.lua` | Historique journalier compact par objet : prix, stock, vendus, ambigus, valeur vendue, expirés ; série 48 h |
| `Analysis.lua` | Stats par objet : prix réel, vendus/j, tendances, écoulement, net de commission et de dépôt, concurrence, signaux, score. Aussi Flips HV, achat PNJ → HV, artisanat, zones de farm |
| `MidasLink.lua` | Lien facultatif, en lecture seule, avec l'addon Midas (MIT) : prix juste et chance de vente, en second recours (`Link.Fair`, `Link.Odds`, `Link.Status`) |
| `Market.lua` | Prix d'équilibre (`Market.Equilibrium`), journal des enchères au sort connu (`db.sales`, `Market.Record` / `Prune`), chance de vente et délai à un prix (`Market.Odds`, `Market.Hours`), durée conseillée (`Market.Duration`), textes (`Market.Text`, `EqText`) |
| `Rebound.lua` | Creux de prix et rebonds par objet (taux, délai médian, meilleur jour de la semaine), appris chaque jour et gardés sans purge ; servent aux flips « à stocker » |
| `Scan.lua` | Scan complet (Auctionator, Retail ou Classic), comparaison avec le scan précédent, carnet d'ordres compact `db.book` |
| `Vendor.lua`, `Farm.lua`, `Snipe.lua` | Prix des marchands (`/ahl pnj`) et achats chez le marchand relevés à ton clic (1.0 phase 3), sessions `/ahl farm`, enchères sous le prix PNJ |
| `Professions.lua` | Niveaux de métier, recettes relevées à l'ouverture des fenêtres de métier (Classic et Retail), fabrications relevées à ton clic « Créer » (1.0 phase 3), table des cuirs pour le dépeçage |
| `Decide.lua` | **Seul moteur de conseil** (0.9) : pour n unités d'un objet, décision HV / PNJ / Tester / Fabriquer / Attendre / Garder, prix, quantité, raison et preuves sourcées (courrier, scans, scan, Auctionator, jeu). Lu par l'infobulle, les pastilles, Mes objets et le rapport |
| `Bags.lua` | Lecture des sacs et de la banque ; `Bags.Advise` / `Bags.Compare` traduisent la décision de `Decide` |
| `Ledger.lua` | Lit les courriers d'HV (ventes, expirations, achats) ; calibre `AH_CUT` et `DEPOSIT_RATE` dès 5 ventes, bornés. Le bilan, lui, est celui de `Tracker` (1.0) |
| `RecipeDB.lua` | Fournisseurs de recettes (`RecipeDB.Register`) et planificateur de montée (`/ahl monter cuir 225`) |
| `Export.lua` | Rapport texte pour Claude (`/ahl claude`), aussi sauvé dans `AHLedgerDB.brief` |
| `Diag.lua` | `/ahl diag` : API présentes, variante utilisée, événements refusés, erreurs, accroches Auctionator / Daylight UI (`Diag.Addons`) |
| `Advisor.lua` | **Conseiller** (0.10) : `Actions` (tous les conseils, rangés par moment puis par gain), `Auctions` (verdict par enchère en cours), `Review` (ce qui marche / ne marche pas, 30 j de courriers), `FarmTargets`, `LevelNext`, `Headline`. Ne décide rien seul : lit `Decide`, `Analysis`, `Ledger`, `Tracker`, `Positions`, `Plan` |
| `Live.lua` | Plus bas vu dans les recherches du joueur après le dernier scan (mémoire de session) ; avertissement « conseil périmé » dans l'infobulle |
| `Bridge.lua`, `Tooltip.lua`, `UI.lua` | Auctionator, tooltips, fenêtre à 5 onglets dont 4 à vues (`UI.TABS`, `UI.VIEWS`, bouton Vue ; aussi en onglet de l'HV via LibAHTab ou Daylight UI) |
| `tools/ahledger.py` | `import`, `report`, `brief`, `sync` (rapport vers Google Drive) ; `tools/sync_drive.bat` sous Windows |

## Hypothèses non vérifiées (à confirmer en jeu)
- Le dossier de l'addon s'appelle bien `AHLedger` dans `Interface/AddOns` (le ZIP GitHub crée `AHLedger-ccr-b6ab2be1-rg4weg`, à renommer).
- API réellement présentes sur Forever : sacs (`C_Container` ou anciennes fonctions), courrier (`GetInboxInvoiceInfo` : ordre des retours, champ quantité), métiers (`GetSkillLineInfo` ou `GetProfessions`), recettes (`GetTradeSkill*` ou `C_TradeSkillUI`), tooltips. `/ahl diag` les liste.
- Commission HV (5 % supposés) et dépôt (15 % du prix PNJ supposés) : calibrés automatiquement par `Ledger.lua` après 5 ventes.
- Seuils de dépeçage par cuir (`Professions.lua`, `Prof.SKINNING`) : approximatifs.
- Fenêtre de copie de `/ahl claude` (EditBox multiligne) : jamais affichée en vrai.
- Relevés de la phase 3 : `BuyMerchantItem` et `DoTradeSkill` (ou `C_TradeSkillUI.CraftRecipe`) existent sur Forever et peuvent être accrochés (`hooksecurefunc`) ; la fonte (minage) passe par la même fenêtre de métier, donc ses barres sont relevées ; `C_Item.GetItemCount` (ou `GetItemCount`) compte bien les sacs à l'instant.
- Durées de mise en vente de Forever et leur dépôt (phase 2) : `Market.DURATIONS` suppose 12, 24 et 48 h (comme `Scan` pour le temps restant), et `Analysis.NetAt` compte le dépôt d'une mise en vente de 12 h. À vérifier dans l'onglet Vendre de l'HV : les durées proposées, et si le dépôt double à chaque palier.

## Prochaines étapes, dans l'ordre
1. **Premier test en jeu.** Installe ou mets à jour l'addon, `/reload`, puis `/ahl diag`. Corrige chaque ligne MANQUE et chaque erreur. Avec une session locale, lis directement :
   - le fichier `World of Warcraft\_forever_\WTF\Account\<COMPTE>\SavedVariables\AHLedger.lua`, écrit à `/reload` ou à la déconnexion. `AHLedgerDB.diag.lines` contient le diagnostic, `AHLedgerDB.brief.text` le rapport ;
   - ne lis pas le code d'Auctionator (son AGENTS.md l'interdit, voir CLAUDE.md) : les noms internes qu'utilise `Bridge.lua` (`Auctionator.State.FullScanFrameRef`, `FullScan.Events.ScanComplete`, `Database.db`, `Constants.SCAN_DAY_0`, `API.v1.MultiSearch`) se vérifient en jeu avec `/ahl diag`.
2. **Faire tourner chaque fonction une fois** : ouvrir les fenêtres de métier, la boîte aux lettres, la banque ; faire un scan ; parcourir les 5 onglets et leurs vues ; `/ahl monter cuir` ; `/ahl claude`.
3. **Brancher un addon de recettes Forever.** Le joueur en choisit un (proposition : LibProfessionDB, fait pour être lu par d'autres addons ; autres pistes : Forever Recipes, Fabrikao!! Forever, My Forever Recipe Book). Lis sa structure de données dans `Interface\AddOns\<addon>` et écris un adaptateur `RecipeDB.Register(...)` au format décrit en tête de `RecipeDB.lua`. Seuils jaune/vert/gris → plan de montée complet ; source et prix des recettes → « recettes à apprendre ». Ajoute l'addon en `## OptionalDeps` du `.toc`.
4. **Synchro Google Drive** : `tools\sync_drive.bat` (Python 3 et Google Drive pour ordinateur requis). Il écrit `Mon Drive/AHLedger/rapport.md`. Le dossier Drive `AHLedger` existe déjà, créé par la session cloud. Le connecteur Drive de Claude sert à lire ce rapport pour conseiller le joueur.
5. **Idées validées, pas encore faites** :
   - onglet « Aujourd'hui » : plan de séance qui combine flip, artisanat, farm et ventes ;
   - meilleur jour et meilleure heure pour vendre (motifs dans `db.recent` et `db.days`) ;
   - liste de surveillance avec alertes de prix ;
   - résumé quotidien envoyé par Gmail à partir du rapport Drive ;
   - méthode d'analyse écrite pour que les conseils de Claude restent cohérents.

## Sous-cotes (session locale du 26/11/2026)
- `Undercut.lua` (toc après `Live.lua`) : mises en vente détectées par différence de la liste d'enchères (`Auctions` `store` → `Undercut.OnOwned`), observations par `Live.Record` (recherches, hors tes enchères) et `Scan.Finish` (`ObserveScan`, plus bas que ta moins chère). `db.undercut.posts` = { id, unit, t, ok, hit, by, src, done, above }, 14 j, 400 au plus. `/ahl souscote`, section du rapport, alerte dans le chat.
- À vérifier en jeu : `OWNED_AUCTIONS_UPDATED` arrive bien juste après une mise en vente (par Daylight UI et Auctionator) ; sinon l'heure de mise en vente est celle de la relecture suivante et le délai est faussé (trop court).
- Règle unique (recherche et scan) : sous-coté = un autre vendeur sous ta moins chère encore en vente ; une observation = une sous-cote, même si elle touche plusieurs enchères d'une pile découpée.
- À vérifier aussi : si le jeu envoie une liste d'enchères vide transitoire à l'ouverture de l'HV, les enchères seraient marquées parties puis recréées avec une nouvelle heure (délais remis à zéro).
- Limites : pas de noms de vendeurs ; un reroll du même compte qui vend moins cher compte comme une sous-cote ; les scans sont trop espacés (20 min à 10 h) pour mesurer un délai, ce sont les recherches du joueur qui le donnent.

## Conventions
- Toute fonction du jeu est détectée avant d'être appelée (variantes Classic et Retail) ; les gestionnaires passent par `ns.safe`.
- Les données lourdes sont stockées en chaînes compactes (`History`, `db.book`, snapshots de scan).
- Toute nouvelle fonction du jeu utilisée doit être ajoutée à `.luacheckrc` (`read_globals`), sinon `check_globals.py` échoue. Ajoute un cas dans `tests/run_test.py` et le mock correspondant dans `tests/harness.lua` ou dans le test.
- Mets le README à jour avec chaque fonctionnalité. Pousse sur `ccr-b6ab2be1-rg4weg`.

## 0.9 : décisions fiables (session locale du 25/11/2026)
- Le joueur veut des décisions claires, sourcées, fiables, et pas de bruit (exemple : ne pas conseiller de fabriquer si l'objet fabriqué ne se vend pas). Interdit : acheter ou vendre à sa place (CGU).
- `Scan.Diff` réécrit : expirations au prorata de la catégorie de durée restante, annulations (enchère plus chère retirée alors qu'une moins chère reste), achats partiels de piles. `History` stocke deux champs de plus (annulé, somme des minimums) et `days[j].o9` (temps observé avec ce diff). Les « ventes » des jours d'avant la 0.9 comptent pour moitié (`Analysis.ItemStats`).
- `Analysis.ItemStats` : `surePerDay`, `salesDays`, `obs9Hours`, `measured`, `stReliable`, `dailyMins` ; `Analysis.UsualMin`. `obs9Hours` = heures des jours observés de bout en bout avec la 0.9 (`days[d].o9 >= obs`) ; dès 12 h (`measured`), ventes, valeur, expirations et jours de vente ne viennent plus que de ces jours (le jour mixte garde la moitié des anciennes « ventes », il est écarté aussi).
- `Bags` : sacs 0 à `NUM_TOTAL_EQUIPPED_BAG_SLOTS` (le sac de composants 5 sur Forever), banque -1 puis les sacs suivants (6 à 12 sur Forever). Avant, le sac 5 était lu comme banque : `c.bankLayout` = 2 marque la photo de banque corrigée (contenu du sac 5 retiré une fois). Tendances : 4 jours mini (5 avec Auctionator) ; tendance 24 h : 4 scans sur 6 h, |v| ≤ 100 %/j.
- Supprimé : « Garder (prix en hausse) », « Attendre (HV bradé) » contre un prix moyen biaisé, le verdict spéculatif de l'infobulle, `Analysis.CraftUp` (recettes non apprises comprises), les flips « à stocker » aux rebonds inconnus, les achats PNJ « à tester » dans la liste.
- `tests/replay.py <SavedVariables>` rejoue les décisions sur les vraies données (aucune écriture) : à lancer après chaque changement de règle.
- Les données d'avant la 0.9 restent surestimées (« disparitions/j, retraits compris ») : les décisions s'améliorent avec les nouveaux scans (12 h de scans 0.9 pour le débit et l'écoulement fiables).


## 0.10 : la décision avant la donnée (session locale du 25/11/2026)
- Demande du joueur : une UX tournée vers l'aide à la décision ; suivre ce qui marche et ce qui ne marche pas ; stratégie de placement à l'HV, de farm, d'artisanat et de montée de métier.
- Onglets : Conseils (défaut) · Mes objets · Mes enchères · Bilan (Ce qui marche / Achat-revente / Journal) · Artisanat (Rentabilité / Montée) · Farm (Que farmer / Mes sessions) · Opportunités (Flip HV / Mes flips / Achat PNJ / Revente PNJ) · Marché. `UI.SetMode(mode)` accepte toujours les anciens modes (`flip`, `ledger`, `level`, …) : ce sont des vues.
- `Advisor.Actions` est mis en cache par `ns.dataVersion` et `ns.bagVersion` (incrémenté à chaque lecture des sacs ou de la banque). Rang = `TIER[kind] × 1e12 + gain`.
- Cohérence : le Bilan ne dit « arrête » que si `Decide.Sells` dit « ne se vend pas » ; « Que farmer » exclut les objets vendus par un marchand (`db.vendor`) et ceux qu'une recette fabrique (OneForAll + tes recettes, hors transmutations), sauf dépeçage ou loot de tes sessions.
- Le rapport (`Export.Advice`) commence par « À faire maintenant » (15 conseils) et la liste « À arrêter ».
- Testé hors jeu (`tests/run_test.py`, cas 0.10) et rejoué sur les vraies SavedVariables : aucune erreur, verdicts cohérents.

## 1.0 phase 1 : un seul calcul par chiffre (session locale du 26/11/2026, version 0.11.0)
- Plan complet de la refonte : `REFONTE.md` (6 phases). Phases 1, 2, 3 et 5 (en partie) faites ; phases 4 et 6 attendent le feu vert du joueur.
- Formules uniques, à réutiliser, jamais à recopier :
  - prix net : `Analysis.NetAt(post, s, vendor, p)` ;
  - prix de valorisation : `Decide.FairPost(id, s)` (l'habituel si le prix du jour est douteux) ;
  - confiance : `Decide.Conf(sells, d)` (un prix douteux n'est jamais « prouvé ») ;
  - coût d'une recette : `Decide.RecipeCost(r)` et `Decide.ReagentCost(rid, k)` (ce que tu as ou récoltes = `Decide.RawValue`, source « toi ») ;
  - bilan : `Tracker.Compute` / `Headline` / `Holds` (onglet Bilan, Conseils, rapport, `/ahl bilan`, infobulle de la minicarte) ;
  - scan périmé : `Analysis.Stale()` (aucun achat conseillé au-delà de `Decide.STALE_HOURS`).
- Garde-fous :
  - scan partiel (35 à 60 % de la taille habituelle, ou plus de 2 % de lignes illisibles) : prix gardés, pas de ventes comptées, `db.partial`, et sa taille n'entre pas dans la référence (`db.partialRun`, adoptée après 3 de suite) ;
  - minuteurs du scan dans `guarded` (une erreur arrête le scan) ;
  - `ns.safe` garde aussi les erreurs datées dans `AHLedgerDB.errors` (20 au plus), visibles dans `/ahl diag`.
- Reste connu, pour les phases suivantes :
  - Positions garde son propre rapprochement achat → vente (MatchSales) ; `Ledger.Holds` est du code mort (à retirer en phase 6) ;
  - le cache de `Decide.For` ne suit que `dataVersion` : changer de sacs ne refait pas le coût « toi » avant le prochain scan ou courrier ;
  - « récolté » est large : toute la sous-classe 7 avec le minage, et tout ce qui a été looté une fois en `/ahl farm` ;
  - `Tracker.Compute` n'a pas de cache (phase 3 : `CostBasis` et `Holds` le gardent, par version des données et des sacs) ;
  - la colonne Gain des Conseils mélange gains par jour et gains ponctuels (phase 5) ;
  - un scan déclenché par Midas est lu passivement et étiqueté « Auctionator ».
- Test en jeu du 26/11 (19 h) : `/ahl diag` « Tout est en place », tous les onglets s'affichent, `/ahl bilan` donne les mêmes chiffres que l'onglet Bilan, `AHLedgerDB.errors` est vide. Correctif : le gain latent de Mes objets suit maintenant le stock du Bilan (`Decide.RawValue`, mention « au prix habituel » si le prix du jour est douteux). À faire plus tard :
  - `Tracker.CostBasis` pourrait renvoyer la valeur du stock, à afficher telle quelle dans Mes objets (source unique, même quand il n'y a pas de stats) ;
  - `RawValue` pourrait renvoyer sa source (PNJ, habituel, HV), pour que la mention soit exacte.

## 1.0 phase 2 : prix d'équilibre et projection (session locale du 26/11/2026, version 0.12.0)
- Formules uniques ajoutées, à réutiliser :
  - repère de prix : `Decide.Ref(id, s)` = prix d'équilibre (`Market.Equilibrium`), sinon plus bas habituel. Il sert à « bradé » (Attendre), « prix douteux », « prix haut », au « garder en banque » des objets fabriqués, à `FairPost` et au « Ne suis pas » de Mes enchères ;
  - chance de vente à un prix : `Decide.Odds(id, post, s, sells)`, dans l'ordre : tes courriers, le journal du marché à ce prix, l'écoulement mesuré, Midas, la valeur par défaut. Lue par compute, `RawValue`, `OutValue`, Mes enchères et la liste farm (`Advisor.FarmTargets`) (le prix net reste `Analysis.NetAt`) ;
  - projection : `d.proj = { odds, oddsSrc, oddsN, hours, hoursSrc, dur }`, affichée par `Decide.Why` (via `Market.Text`) juste après la raison.
- `Decide.PostPrice` rend un 4e retour `info = { eq, eqSrc, ahead, dump, bigDump, watch }` :
  - plancher sous l'équilibre −10 % et ces bradées partent en moins d'un jour de ventes sûres : juste sous le premier prix normal, sans dépasser l'équilibre ;
  - sinon (`bigDump`) 1c sous la moins chère, et compute dit Attendre ou PNJ sous 75 % du repère ;
  - objet « robot » ou « surveillé » (`Undercut.Stats`) avec un équilibre : l'équilibre, plus l'heure calme (`e.quiet`, tranches de 4 h où tu as posté sans sous-cote rapide).
- Scan :
  - chaque signature d'enchère garde `f`, sa date d'arrivée (gardée d'un scan à l'autre, milieu de l'écart pour une nouvelle, inconnue sinon) ;
  - `Scan.Diff(prev, sigs, gap, now)` met dans `b.ev` les enchères au sort sûr (vendues avec p <= 0, expirées avec p >= 1) ; `Finish` les verse dans `db.sales` puis les retire du diff.
- Taille : `f` ajoute ~0,4 Mo aux SavedVariables (7,3 Mo le 26/11) ; `db.sales` est borné à 14 jours et 40 enchères par objet.
- Rejeu des données réelles du 26/11 : 288 objets ont un équilibre sur 6 031 suivis (2 jours de scans 0.9 seulement). Le garde-fou 0,4 à 1,5 × le prix affiché a écarté un faux équilibre (Black Whelp Scale à 25c, le prix PNJ, quand le marché est à ~2s). Le journal du marché est vide tant qu'aucun scan n'a été fait avec la 0.12.
- À vérifier en jeu : la ligne « Midas : présent (…) » de `/ahl diag`, les projections dans Mes objets après deux scans à moins de 12 h d'écart, les durées et dépôts (voir Hypothèses).
- Approximations du temps en rayon : la date d'arrivée `f` est rangée par signature (objet, pile, prix), pas par enchère : une 2e enchère identique hérite de la date de la 1re (temps en rayon surestimé) ; après un scan partiel, une enchère qu'il a manquée repart avec une date au milieu de l'écart (sous-estimé). Midas donne la chance d'une mise en vente de 48 h, quelle que soit la durée conseillée : le texte le dit.
- `Decide.CraftCost` garde `sells.p` : son seuil « à perte » est calculé avant tout prix, `Decide.Odds` a besoin d'un prix.
- Reste connu : sans débit sûr (moins de 12 h de scans 0.9), un bradage est toujours traité comme gros (on ne sait pas s'il partira dans la journée) ; la durée conseillée ne change pas le dépôt compté par `NetAt`.

## 1.0 phase 3 : tes vrais coûts (session locale du 26/11/2026, version 0.13.0)
- Relevés, seulement à ton clic (rien à l'ouverture d'un marchand ou d'une fenêtre de métier) :
  - achat au marchand : accroche de `BuyMerchantItem` → `buying[id]` (prix /u du marchand, compte des sacs avant) ; à chaque `BAG_UPDATE_DELAYED`, ce qui est arrivé est noté par `Tracker.LogBuy(id, qté, total, nil, "PNJ")` (`db.buys[i].w = "PNJ"`). La quantité est celle reçue (une pile de 5 = 5) ; payé en jetons, ignoré ; rien reçu en 10 s, oublié (`Vendor.BUY_WAIT`) ;
  - fabrication : accroche de `DoTradeSkill` (ou `C_TradeSkillUI.CraftRecipe`) → `crafting[objet]` ; une fabrication = les composants de la recette consommés **et** l'objet reçu (pas de relevé tant que l'objet n'est pas arrivé), notée par `Tracker.LogCraft(id, reçus, use, val)` dans `db.crafts` (`u` = composants consommés, `v` = leur `Decide.RawValue` à ce moment). Série finie après 15 s sans fabrication (`Prof.CRAFT_WAIT`) ; 400 relevés et 60 j au plus.
- Prix de revient (`Tracker.Compute`) : chaque unité entre dans un lot, sorti le plus ancien d'abord. Achat (HV ou marchand) = prix payé ; fabrication = les lots de ses composants (leur propre prix de revient) et, pour ce qui ne vient d'aucun lot, leur valeur brute du moment. Un lot fabriqué garde à part l'or vraiment payé (`paid`). À la vente : `craftGain` = net − prix de revient (valeur ajoutée par la fabrication), et la valeur brute de tes propres composants compte en farm. Donc farm + revente + fabrication = net − or payé.
  - `tot.craft` / `it.craftGain` : nouvelle part du bilan réel (bandeau « Revente et artisanat ») ; `it.bought` / `tot.spent` ne comptent que l'HV (`boughtPNJ`, `spentPNJ` à part) ;
  - les achats au marchand sont des fournitures : prix de revient oui, stock latent non ; un objet acheté au marchand n'entre dans Achat-revente que s'il est revendu à l'HV (ou fabriqué en autre chose) ;
  - un courrier d'achat n'est plus dédoublonné contre un achat au marchand ;
  - `db.buys` : 60 j et 1 500 achats au plus (`T.BUY_KEEP`), puisque ceux du marchand se font clic par clic ;
  - « Ce qui marche » (Advisor) juge l'achat-revente sans la valeur ajoutée des fabrications, au prix moyen payé à l'HV ;
  - `Tracker.CostBasis()` = 5e retour de `Compute` : `[id] = { units, cost, paid, bought, boughtCost, crafted, craftCost }` (totaux), en cache par `dataVersion` et `bagVersion`.
- `/ahl diag` : groupe « Relevés (achats PNJ, fabrications) » (API présentes) et deux lignes OK/MANQUE « Achats chez le marchand relevés à ton clic », « Fabrications relevées à ton clic » (accroches posées).
- Artisanat : la colonne Conseil se trie sur `e.okRank` (3 Fabriquer, 2 marge faible, 1 brut, 0 prix manquant), jamais sur un booléen.
- `Decide.UnitCost(id, n)` : prix de revient /u de n unités = les achetées et fabriquées relevées (les plus récentes), le reste à `Decide.RawValue` (farmé, looté, d'avant les relevés). `Decide.UnitCostText` le dit. Lu par compute (`d.basis`, avertissement « tu vends sous son prix de revient » pour HV et Tester ; la décision ne change pas), Mes objets (préfixe « prix de revient … : +gain ») et l'infobulle (« Prix de revient »).
- Matière brute ou fabriqué : `Decide.RawOrCraft(outId, r, fixId, fixValue)`, **le** verdict d'une recette. `raw` = composants à `RawValue` ; `cost` = `RecipeCost` ; `craft` = `OutValue` × fabriqués ; `base` = max(raw, cost) ; `gain` = craft − base ; `ok` = gain ≥ base × `CRAFT_MARGIN` et l'objet se vend. Lu par Artisanat (`Analysis.Crafts` : colonnes Brut, Coût, Fabriqué, Bénéfice, Conseil ; Or/j à 0 si pas ok), le Conseiller (via `e.daily`), Mes objets (`craftUp` exige `ok`, l'objet de tes sacs compté à sa valeur décidée via `fixId`) et l'infobulle. `RecipeCost(r, fixId, fixValue)` accepte la même substitution.
- Rejeu des données réelles du 26/11 : bilan identique à l'ancien code au centime (aucun achat PNJ ni fabrication encore relevés) ; 12 recettes « Fabriquer » sur 117 (16 avant la règle « base = max(brut, coût) » : Simple Poultice était conseillé alors que ses composants valent plus bruts) ; aucune erreur d'interface ni de rapport.
- Approximations : le prix de revient des unités restantes suppose que les plus récentes sont celles que tu as encore ; un loot du même objet pendant les 10 s d'un achat (ou les 15 s d'une série de fabrications) serait compté dedans ; la fabrication d'objets qui ne passent pas par les sacs (enchantements) n'est pas relevée ; `Decide.For` est en cache par `dataVersion` seulement, donc `d.basis` suit les sacs au prochain changement de données.

## 1.0 phase 5 : interface, 5 onglets et panneau de détail (session du 27/11/2026, version 0.14.0)
- Demande du joueur : « beaucoup de texte coupé dans les tableaux ». Faite avant la phase 4, sans ce qui en dépend.
- **5 onglets** (`UI.TABS`) : Aujourd'hui (`advice`), Mon stock (`bags`, `auctions`), Opérations (`review`, `ledger`, `journal`, `farm`), Artisanat (`craft`, `level`), Marché (`market`, `flip`, `positions`, `vendor`, `snipe`, `farmwhat`). Libellés dans `TAB_TITLE`, vues dans `VIEWS`. Le bouton Vue se range à gauche des filtres dans la vue Signaux du Marché. Bouton Période : Achat-revente et Journal seulement.
- **Au plus 7 colonnes par vue** ; les colonnes retirées sont dans `MODES[m].more` (`{ titre, fonction }`) et s'affichent dans le détail. Colonnes de nom élargies (180 à 210 px).
- **Panneau de détail** (`UI.detail`, `DETAIL_H` = 80 px, 5 lignes au plus, au-dessus du pied de page ; au-delà, l'infobulle de la ligne ajoute la colonne de texte entière) : `UI.DetailText(mode, e)` = 1re colonne en blanc, colonnes courtes et `more` « titre valeur », puis la colonne de texte (dernière colonne alignée à gauche) en entier, plus `MODES[m].detail(e)` si défini. Suit la ligne survolée (`UI.detailKey`, mémorisée au survol seulement, retrouvée à chaque rafraîchissement par objet + type + `seq`/`t`), sinon la première ligne affichée (elle suit la molette) ; oublié au changement de vue. L'infobulle des lignes ne recopie plus les cellules coupées.
- Pas encore fait (dépend de la phase 4 ou de l'API de vente) : boutons [Vendre] / [Passer] dans Aujourd'hui, liste unique sacs + banque + enchères dans Mon stock, tableau continuer / lâcher et courbe du bilan dans Opérations, courbe de prix 7 j dans Marché.
- À vérifier en jeu : le panneau tient sur 5 lignes (`SetMaxLines`) dans la fenêtre et dans l'onglet de l'HV de Daylight UI ; le nombre de lignes du tableau dans l'onglet de l'HV ; les 5 boutons d'onglet (120 px) ; le bouton Vue et les filtres du Marché ne se chevauchent pas.
