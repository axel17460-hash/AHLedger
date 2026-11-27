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
| `Rebound.lua` | Creux de prix et rebonds par objet (taux, délai médian, meilleur jour de la semaine), appris chaque jour et gardés sans purge ; servent aux flips « à stocker » |
| `Scan.lua` | Scan complet (Auctionator, Retail ou Classic), comparaison avec le scan précédent, carnet d'ordres compact `db.book` |
| `Trust.lua` | Fiabilité d'un prix : ventes / expirations / annonces qui traînent au prix près (`db.outcomes`, date de 1re apparition `f` dans `lastSigs`), tes courriers ; plafond au plus haut prix vu vendu (`s.capped`), verdict `Trust.Check(s, prix)` → ok / test / bad |
| `Opportunities.lua` | Onglets « Rentables » (recettes rentables, apprises ou non, avec accès et amorti) et « Sous-coter » (enchère la moins chère au-dessus du prix habituel) |
| `Vendor.lua`, `Farm.lua`, `Snipe.lua` | Prix des marchands, sessions `/ahl farm`, enchères sous le prix PNJ |
| `Professions.lua` | Niveaux de métier, recettes relevées à l'ouverture des fenêtres de métier (Classic et Retail), table des cuirs pour le dépeçage |
| `Bags.lua` | Conseiller d'inventaire (sacs et banque) : vendre HV / garder / PNJ / attendre |
| `Ledger.lua` | Bilan réel lu dans les courriers d'HV ; calibre `AH_CUT` et `DEPOSIT_RATE` dès 5 ventes |
| `Track.lua` | Fiabilité des conseils : note les flips / achats PNJ conseillés à chaque scan (`db.track`), les vérifie sur les scans suivants (prix tenu, écoulé) et les rapproche de tes achats réels ; vue « fiabilité » de l'onglet Bilan, `/ahl fiabilite` |
| `RecipeDB.lua` | Fournisseurs de recettes (`RecipeDB.Register`) et planificateur de montée (`/ahl monter cuir 225`) |
| `Sell.lua` | Module Vente (v0.9) : règles de prix par défaut / catégorie / objet (`AHLedgerDB.sell`), prix proposé (`Sell.Quote` : carnet sans tes enchères, anti-troll, plancher, plafond, undercut, durée), file de mise en vente (`Sell.Queue`, une ligne = un clic ; lignes « banque » non postables), enchères battues et gain de repost (`Sell.Undercuts`), résumé à l'ouverture de l'HV, résumé de session « farmer ou acheter » (`Sell.SalesSummary`, `Sell.FarmCompare`, affiché dans l'onglet Farm), coût de farm dans le plancher (`Farm.UnitCost`, règle `farmCost`), `Sell.Post` / `Sell.CancelNext` (API `C_AuctionHouse`, un clic ou une touche = une action), `/ahl vendre …`. L'interface est dans `UI.lua` : vues « file de vente » et « undercuts » de l'onglet Mes objets. Raccourcis : `Bindings.xml` |
| `Export.lua` | Rapport texte pour Claude (`/ahl claude`), aussi sauvé dans `AHLedgerDB.brief` |
| `Diag.lua` | `/ahl diag` : API présentes, variante utilisée, événements refusés, erreurs |
| `Bridge.lua`, `Tooltip.lua`, `UI.lua` | Auctionator, tooltips, fenêtre à 10 onglets (aussi en onglet de l'HV via LibAHTab) |
| `tools/ahledger.py` | `import`, `report`, `brief`, `sync` (rapport vers Google Drive) ; `tools/sync_drive.bat` sous Windows |

## Hypothèses non vérifiées (à confirmer en jeu)
- Le dossier de l'addon s'appelle bien `AHLedger` dans `Interface/AddOns` (le ZIP GitHub crée `AHLedger-ccr-b6ab2be1-rg4weg`, à renommer).
- API réellement présentes sur Forever : sacs (`C_Container` ou anciennes fonctions), courrier (`GetInboxInvoiceInfo` : ordre des retours, champ quantité), métiers (`GetSkillLineInfo` ou `GetProfessions`), recettes (`GetTradeSkill*` ou `C_TradeSkillUI`), tooltips. `/ahl diag` les liste.
- Commission HV (5 % supposés) et dépôt (15 % du prix PNJ supposés) : calibrés automatiquement par `Ledger.lua` après 5 ventes.
- Seuils de dépeçage par cuir (`Professions.lua`, `Prof.SKINNING`) : approximatifs.
- Fenêtre de copie de `/ahl claude` (EditBox multiligne) : jamais affichée en vrai.

## Module Vente : à vérifier en jeu (rien n'y a été testé, l'API est simulée dans `tests/test_sell.py`)
1. `PostCommodity` / `PostItem` / `CancelAuction` : un clic ou une touche suffit-il (événement matériel) ? Le bouton « Poster suivant » et la touche de `Bindings.xml` doivent chacun poster une enchère. Si une erreur d'action bloquée apparaît, regarde `/ahl diag` et le message de `Sell.Post`.
2. `PostCommodity(loc, durée, quantité, prix/u)` : durée 1/2/3 = 12/24/48 h ; `PostItem(loc, durée, 1, nil, rachat)` pour les objets uniques (équipement). La quantité postée est plafonnée par `GetAvailablePostCount` s'il existe. Vérifie le prix et la durée réellement affichés dans « Mes enchères ».
3. Annuler : où revient l'objet (sacs ou courrier) ? Le dépôt est-il perdu (le calcul du repost le suppose) ?
4. `Analysis.AH_CUT` (5 %) et plafond d'enchères actives par compte (non géré : à ajouter dans `Sell.Plan` s'il existe).
5. Le numéro d'enchère (`auctionID` de `GetOwnedAuctionInfo`) est stocké dans `Auctions` (champ `aid`) : sans lui, « Annuler suivante » ne fait rien. Rouvre l'HV pour relire tes enchères après une mise à jour de l'addon.
6. L'interface n'a pas été vue : colonnes, grisé des lignes bloquées, bouton « Poster suivant » (largeur 120 px), pied de page de la file.
7. Le carnet vient du dernier scan : une enchère postée après lui n'est pas retirée du carnet (`Sell.WithoutMine` n'enlève que ce qu'il y retrouve). Rescanne après une série de mises en vente.
8. Résumé de session (onglet Farm, pied de page et aide ; `Sell.SalesSummary`, `Sell.FarmCompare`) : les ventes et expirations comptent à la **lecture** du courrier (`e.t` du Ledger), pas à l'heure de la vente. Vérifie qu'une enchère annulée revient par un courrier qui n'est **pas** reconnu comme « expirée » (sinon son dépôt serait compté deux fois : annulation + expiration). La session de jeu repart à zéro à chaque `/reload`. L'or ramassé d'une session `/ahl farm` (`GetMoney()` − départ) inclut l'or des ventes retiré au courrier pendant le farm.
9. Dépôt perdu estimé = quantité × `s.deposit` (part du prix PNJ, sans tenir compte de la durée 12/24/48 h). Compare à un vrai dépôt perdu (courrier d'expiration, annulation) ; si la durée multiplie le dépôt sur Forever, corrige `Sell.DepositPerUnit` (et `Analysis`).
10. Coût de farm (`Farm.CostTable`, règle `farmCost`) : regarde la colonne « Plancher/u » de la file pour un objet farmé (cuir, tissu) ; le plancher ne devrait mordre que si le marché s'effondre. Si un plancher « coût de farm » bloque des ventes normales, baisse le coefficient (`/ahl vendre regle farm 0.5`) ou revois la répartition du temps (prorata quantité × prix PNJ).
11. File de la banque : ouvre la banque une fois, puis la file à l'HV : les lignes « (banque) » doivent être grisées en nom, action « Retirer », jamais postées par « Poster suivant » ni la touche.

## Prochaines étapes, dans l'ordre
1. **Premier test en jeu.** Installe ou mets à jour l'addon, `/reload`, puis `/ahl diag`. Corrige chaque ligne MANQUE et chaque erreur. Avec une session locale, lis directement :
   - le fichier `World of Warcraft\_forever_\WTF\Account\<COMPTE>\SavedVariables\AHLedger.lua`, écrit à `/reload` ou à la déconnexion. `AHLedgerDB.diag.lines` contient le diagnostic, `AHLedgerDB.brief.text` le rapport ;
   - le code d'Auctionator dans `Interface\AddOns\Auctionator`, pour vérifier les noms internes utilisés par `Bridge.lua` (`Auctionator.State.FullScanFrameRef`, `FullScan.Events.ScanComplete`, `Database.db`, `Constants.SCAN_DAY_0`, `API.v1.MultiSearch`).
2. **Faire tourner chaque fonction une fois** : ouvrir les fenêtres de métier, la boîte aux lettres, la banque ; faire un scan ; parcourir les 10 onglets ; `/ahl monter cuir` ; `/ahl claude`.
3. **Brancher un addon de recettes Forever.** Le joueur en choisit un (proposition : LibProfessionDB, fait pour être lu par d'autres addons ; autres pistes : Forever Recipes, Fabrikao!! Forever, My Forever Recipe Book). Lis sa structure de données dans `Interface\AddOns\<addon>` et écris un adaptateur `RecipeDB.Register(...)` au format décrit en tête de `RecipeDB.lua`. Seuils jaune/vert/gris → plan de montée complet ; source et prix des recettes → « recettes à apprendre ». Ajoute l'addon en `## OptionalDeps` du `.toc`.
4. **Synchro Google Drive** : `tools\sync_drive.bat` (Python 3 et Google Drive pour ordinateur requis). Il écrit `Mon Drive/AHLedger/rapport.md`. Le dossier Drive `AHLedger` existe déjà, créé par la session cloud. Le connecteur Drive de Claude sert à lire ce rapport pour conseiller le joueur.
5. **Idées validées, pas encore faites** :
   - onglet « Aujourd'hui » : plan de séance qui combine flip, artisanat, farm et ventes ;
   - meilleur jour et meilleure heure pour vendre (motifs dans `db.recent` et `db.days`) ;
   - liste de surveillance avec alertes de prix ;
   - résumé quotidien envoyé par Gmail à partir du rapport Drive ;
   - méthode d'analyse écrite pour que les conseils de Claude restent cohérents.

## Conventions
- Toute fonction du jeu est détectée avant d'être appelée (variantes Classic et Retail) ; les gestionnaires passent par `ns.safe`.
- Les données lourdes sont stockées en chaînes compactes (`History`, `db.book`, snapshots de scan).
- Toute nouvelle fonction du jeu utilisée doit être ajoutée à `.luacheckrc` (`read_globals`), sinon `check_globals.py` échoue. Ajoute un cas dans `tests/run_test.py` et le mock correspondant dans `tests/harness.lua` ou dans le test.
- Mets le README à jour avec chaque fonctionnalité. Pousse sur `ccr-b6ab2be1-rg4weg`.
