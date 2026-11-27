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
- Tests : `pip install lupa luaparser`, puis `python tests/check_globals.py`, `python tests/run_test.py`, `python tests/test_sell.py` et `python tests/test_watch.py`. Tous passent. `tests/harness.lua` simule l'API du jeu (Classic, sauf indication) et 14 jours de marché.
- Workflow GitHub `.github/workflows/tests.yml` : jamais vu tourner (aucune exécution sur la branche au dernier contrôle). Les Actions sont peut-être désactivées sur le dépôt.

## Architecture (ordre de chargement du .toc)
| Fichier | Rôle |
|---|---|
| `Core.lua` | Base `AHLedgerDB`, bus d'événements `ns.on` (les événements inconnus du client sont ignorés et notés), `/ahl …`, `ns.safe` (garde les erreurs dans `ns.errors`) |
| `History.lua` | Historique journalier compact par objet : prix, stock, vendus, ambigus, valeur vendue, expirés ; série 48 h |
| `Analysis.lua` | Stats par objet : prix réel, vendus/j, tendances, écoulement, net de commission et de dépôt, concurrence, signaux, score. Aussi Flips HV, achat PNJ → HV, artisanat, zones de farm |
| `Rebound.lua` | Creux de prix et rebonds par objet (taux, délai médian, meilleur jour de la semaine), appris chaque jour et gardés sans purge ; servent aux flips « à stocker » |
| `Timing.lua` | Meilleur jour / heure pour vendre : enchères vendues réparties en 28 cases (jour × tranche de 6 h) et divisées par le temps observé dans chaque case (corrige le biais « je scanne surtout le dimanche soir »), stockées dans `db.timing` (chaînes compactes, sans purge) ; `Timing.Profile(db, id)` (id nil = tout l'HV) → meilleur jour, tranche, case, gain, fiabilité ; ligne d'infobulle si fiable, section du rapport, `/ahl moment [objet]` |
| `Scan.lua` | Scan complet (Auctionator, Retail ou Classic), comparaison avec le scan précédent, carnet d'ordres compact `db.book` |
| `Trust.lua` | Fiabilité d'un prix : ventes / expirations / annonces qui traînent au prix près (`db.outcomes`, date de 1re apparition `f` dans `lastSigs`), tes courriers ; plafond au plus haut prix vu vendu (`s.capped`), verdict `Trust.Check(s, prix)` → ok / test / bad |
| `Opportunities.lua` | Onglets « Rentables » (recettes rentables, apprises ou non, avec accès et amorti) et « Sous-coter » (enchère la moins chère au-dessus du prix habituel) |
| `Vendor.lua`, `Farm.lua`, `Snipe.lua` | Prix des marchands, sessions `/ahl farm`, enchères sous le prix PNJ |
| `Watch.lua` | Liste de surveillance : règles par objet (`AHLedgerDB.watch.items` : achat ≤, vente ≥, variation vs moy. 7 j, signal, stock <), évaluées à la fin de `Scan.Finish` (`Watch.OnScan`), alerte chat + son, anti-spam (`realmDB().watchState[id].on`) avec réarmement à marge (`Watch.REARM`, `REARM_PCT`). `/ahl surveiller …`, parseur `Watch.ParseMoney`. Vue « Surveillance » (bloc séparé de `UI.lua`, vue de l'onglet Revente PNJ), ligne « Surveillé » dans l'infobulle (hors cache). Aucun achat automatique |
| `Professions.lua` | Niveaux de métier, recettes relevées à l'ouverture des fenêtres de métier (Classic et Retail), table des cuirs pour le dépeçage |
| `Bags.lua` | Conseiller d'inventaire (sacs et banque) : vendre HV / garder / PNJ / attendre |
| `Ledger.lua` | Bilan réel lu dans les courriers d'HV ; calibre `AH_CUT` et `DEPOSIT_RATE` dès 5 ventes |
| `Track.lua` | Fiabilité des conseils : note les flips / achats PNJ conseillés à chaque scan (`db.track`), les vérifie sur les scans suivants (prix tenu, écoulé) et les rapproche de tes achats réels ; vue « fiabilité » de l'onglet Bilan, `/ahl fiabilite` |
| `RecipeDB.lua` | Fournisseurs de recettes (`RecipeDB.Register`) et planificateur de montée (`/ahl monter cuir 225`) |
| `Sell.lua` | Module Vente (v0.9) : règles de prix par défaut / catégorie / objet (`AHLedgerDB.sell`), prix proposé (`Sell.Quote` : carnet sans tes enchères, anti-troll, plancher, plafond, undercut, durée), file de mise en vente (`Sell.Queue`, une ligne = un clic ; lignes « banque » non postables), enchères battues et gain de repost (`Sell.Undercuts`), résumé à l'ouverture de l'HV, résumé de session « farmer ou acheter » (`Sell.SalesSummary`, `Sell.FarmCompare`, affiché dans l'onglet Farm), coût de farm dans le plancher (`Farm.UnitCost`, règle `farmCost`), `Sell.Post` / `Sell.CancelNext` (API `C_AuctionHouse`, un clic ou une touche = une action), `/ahl vendre …`. L'interface est dans `UI.lua` : vues « file de vente » et « undercuts » de l'onglet Mes objets. Raccourcis : `Bindings.xml` |
| `Today.lua` | Onglet « Aujourd'hui » : plan de séance (`Today.Plan(minutes, or)`) qui réunit file de vente, reposts, flips, achats PNJ, artisanat, vente PNJ et farm ; gain incrémental homogène (vente possédée : p × net − (1 − p) × dépôt − prix PNJ, p d'après vendus/j et durée ; repost déjà pondéré ; flips, achats PNJ, crafts : marge nette), classement glouton par gain × fiabilité ÷ (minutes/T + or/G), une action par objet, vente PNJ jamais écartée, dépôts dans l'or immobilisé, sous contrainte de temps et d'or ; temps par action en constantes en tête du fichier ; `/ahl aujourdhui [minutes]`. Interface dans un bloc à part en fin de `UI.lua` (enveloppes de `UI.Build` / `UI.SetMode`) |
| `Export.lua` | Rapport texte pour Claude (`/ahl claude`), aussi sauvé dans `AHLedgerDB.brief` ; 2e ligne = renvoi à `METHODE.md` et sa version (`Export.METHODE`) |
| `METHODE.md` | Méthode d'analyse du rapport pour Claude : lecture de chaque section, ordre de décision, seuils du code, pièges, gabarit de réponse. Copiée à côté de `rapport.md` par `sync`. Une constante change → mets à jour son § 5 ; la forme du rapport change → incrémente `Export.METHODE` |
| `Diag.lua` | `/ahl diag` : API présentes, variante utilisée, événements refusés, erreurs |
| `Bridge.lua`, `Tooltip.lua`, `UI.lua` | Auctionator, tooltips, fenêtre à 11 onglets (aussi en onglet de l'HV via LibAHTab) |
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
Moment de vente (`Timing.lua`), à vérifier en jeu : l'heure vient de `date()` (heure du PC, pas du serveur) ; regarder `/ahl moment` après une ou deux semaines de scans, et la taille de `timing` dans les SavedVariables. La durée de mise en vente de `Sell.lua` ne s'en sert pas encore (idée : préférer 24/48 h si le meilleur moment tombe après 12 h).

## Onglet « Aujourd'hui » : à vérifier en jeu (testé seulement sur le marché simulé)
1. Les temps supposés (`Today.POST_MIN`, `FLIP_MIN`, `VENDOR_TRAVEL_MIN`, `CRAFT_*`, `BANK_MIN`) : chronomètre une vraie séance et ajuste les constantes en tête de `Today.lua`.
2. L'interface n'a pas été vue : 11 onglets dans 820 px (~72 px chacun, « Aujourd'hui » et « Sous-coter » tiennent-ils ?), les 4 boutons 15/30/60/120 min en haut à droite, la colonne « Action » (330 px, le texte entier au survol).
3. L'onglet s'ouvre par défaut (enveloppe de `UI.Build`). Si c'est lent avec beaucoup d'objets (le plan relance Flips, Crafts, Sell.Queue… à chaque rafraîchissement), ajouter un cache sur `ns.dataVersion`.
4. Le gain d'une mise en vente est le net attendu au prix de la file, pas pondéré par la chance de vendre ; le farm est valorisé par `Analysis.FarmZones` (or brut ramassé compris, qui inclut tes achats/ventes PNJ pendant la session).
Limites connues : les recettes non apprises (onglet Rentables) ne sont pas proposées (pas une action de séance) ; une seule zone de farm ; pas de trajet entre actions (marchand, banque, métier comptés chacun à part).

## Surveillance : à vérifier en jeu (`Watch.lua`, branche `feat/watch`, rien testé en jeu)
1. `/ahl surveiller <Maj-clic sur un objet> achat 1g20s` : le lien collé est-il bien reconnu (format `|Hitem:…|h[…]|h|r`) ? Un nom partiel, un nom français ?
2. Après un scan (le tien ou celui d'Auctionator), l'alerte arrive-t-elle une seule fois, avec un lien cliquable ? Le son `SOUNDKIT.RAID_WARNING` existe-t-il sur Forever (sinon `MONEY_FRAME_OPEN`) ?
3. Vue « Surveillance » (bouton « Vue : surveillance » de l'onglet Revente PNJ) : largeur des colonnes, texte coupé de « Règles » et « Dernière alerte » (le survol l'affiche en entier).
4. « Variation » compare le moins cher du scan à la moyenne des 7 jours (prix médian par scan) : le moins cher est souvent sous la moyenne, une règle ±10 % peut donc sonner souvent. Ajuste le seuil, ou passe la référence à la médiane du scan si c'est trop bavard.
Limites : une alerte n'arrive qu'après un scan complet (pas pendant la navigation, l'API Classic n'existe pas sur Forever) ; pas de règles par catégorie ; rien dans le rapport Claude pour l'instant.

## Prochaines étapes, dans l'ordre
1. **Premier test en jeu.** Installe ou mets à jour l'addon, `/reload`, puis `/ahl diag`. Corrige chaque ligne MANQUE et chaque erreur. Avec une session locale, lis directement :
   - le fichier `World of Warcraft\_forever_\WTF\Account\<COMPTE>\SavedVariables\AHLedger.lua`, écrit à `/reload` ou à la déconnexion. `AHLedgerDB.diag.lines` contient le diagnostic, `AHLedgerDB.brief.text` le rapport ;
   - le code d'Auctionator dans `Interface\AddOns\Auctionator`, pour vérifier les noms internes utilisés par `Bridge.lua` (`Auctionator.State.FullScanFrameRef`, `FullScan.Events.ScanComplete`, `Database.db`, `Constants.SCAN_DAY_0`, `API.v1.MultiSearch`).
2. **Faire tourner chaque fonction une fois** : ouvrir les fenêtres de métier, la boîte aux lettres, la banque ; faire un scan ; parcourir les 11 onglets ; `/ahl monter cuir` ; `/ahl claude`.
3. **Brancher un addon de recettes Forever.** Le joueur en choisit un (proposition : LibProfessionDB, fait pour être lu par d'autres addons ; autres pistes : Forever Recipes, Fabrikao!! Forever, My Forever Recipe Book). Lis sa structure de données dans `Interface\AddOns\<addon>` et écris un adaptateur `RecipeDB.Register(...)` au format décrit en tête de `RecipeDB.lua`. Seuils jaune/vert/gris → plan de montée complet ; source et prix des recettes → « recettes à apprendre ». Ajoute l'addon en `## OptionalDeps` du `.toc`.
4. **Synchro Google Drive** : `tools\sync_drive.bat` (Python 3 et Google Drive pour ordinateur requis). Il écrit `Mon Drive/AHLedger/rapport.md` et y copie `METHODE.md` (à lire avant de conseiller). Le dossier Drive `AHLedger` existe déjà, créé par la session cloud. Le connecteur Drive de Claude sert à lire ce rapport pour conseiller le joueur.
5. **Idées validées, pas encore faites** :
   - résumé quotidien envoyé par Gmail à partir du rapport Drive.
   (Faits : méthode d'analyse `METHODE.md`, meilleur moment de vente `Timing.lua`, onglet « Aujourd'hui » `Today.lua`, surveillance `Watch.lua`.)

## Conventions
- Toute fonction du jeu est détectée avant d'être appelée (variantes Classic et Retail) ; les gestionnaires passent par `ns.safe`.
- Les données lourdes sont stockées en chaînes compactes (`History`, `db.book`, snapshots de scan).
- Toute nouvelle fonction du jeu utilisée doit être ajoutée à `.luacheckrc` (`read_globals`), sinon `check_globals.py` échoue. Ajoute un cas dans `tests/run_test.py` et le mock correspondant dans `tests/harness.lua` ou dans le test.
- Mets le README à jour avec chaque fonctionnalité. Pousse sur `ccr-b6ab2be1-rg4weg`.
