# AHLedger (v0.8.1)

Addon pour WoW: Forever. Il repère les objets les plus rentables à vendre à l'hôtel des ventes et suit les hausses et baisses de prix, pour savoir quoi farmer avant tout le monde. L'analyse se fait entièrement en jeu.

## Installation
1. Copier le dossier `AHLedger/` dans `World of Warcraft/_forever_/Interface/AddOns/`. Le nom exact du dossier client est à vérifier ; les sous-dossiers `tools/` et `tests/` peuvent rester, le jeu les ignore.
2. Le `.toc` est réglé sur l'Interface 16001 (Forever 1.60, même valeur qu'Auctionator).

## Utilisation
- À l'HV, deux boutons s'ajoutent à droite de la fenêtre : **AHLedger : scan** et **AHLedger : analyse**. Lance un scan toutes les 15 à 60 min pendant que tu joues : plus il y a de scans rapprochés, meilleures sont les estimations de volume.
- `/ahl` ouvre la fenêtre d'analyse :
  - **Marché** : classement par score « à farmer », avec prix, tendance/jour, vendus/jour, stock, or/jour et signaux. Filtres par catégorie et option pour n'afficher que les marchés liquides. Clique sur un en-tête pour trier.
  - **Flip HV** : enchères affichées sous le prix réel de vente. Pour chaque objet : jusqu'à quel prix unitaire acheter, combien (au plus 2 jours de ventes), à quel prix revendre (juste sous la prochaine enchère restante, sans dépasser le prix réel de vente) et le bénéfice attendu, net de la commission et des dépôts perdus sur les invendus. Seuils : ROI ≥ 15 % et bénéfice ≥ 20 pa. La colonne « Revendre » dit quoi faire ensuite :
    - **tout de suite** : un vendeur brade mais le reste du marché est au prix habituel, tu remets en vente aussitôt ;
    - **stocker ~N j (X %)** : tout le marché est bas. Tu achètes, tu gardes, et tu revends au prix d'avant le creux quand il remonte. N = délai médian des rebonds passés de l'objet, X = part de ses creux qui sont remontés. Le bénéfice affiché (« ~ ») est espéré : chance de remonter × revente au prix habituel + chance contraire × revente au prix d'aujourd'hui. Seuil plus strict : ROI ≥ 25 %. Pas de stockage sur un marché en baisse régulière, sauf si l'objet a déjà prouvé qu'il remonte ;
    - **stocker ? (à tester)** : moins de 3 creux observés, on compte une chance sur deux et on n'achète qu'une demi-journée de ventes, pour apprendre.

    Les creux (prix 15 % sous la médiane des 7 jours précédents) et leurs rebonds (retour à 5 % près) sont relevés une fois par jour dans l'historique d'AHLedger complété par celui d'Auctionator, et comptés dans `rebound`, qui n'est pas purgé : la prédiction s'améliore au fil des mois. L'infobulle donne aussi le meilleur jour de la semaine pour vendre (dès 3 semaines de prix) et tes propres reventes : objets achetés puis revendus d'après les courriers d'HV, durée de stockage réelle et bénéfice par unité. Clic = rechercher l'objet.
  - **Artisanat** : tes recettes, relevées quand tu ouvres une fenêtre de métier (ouvre chacun de tes métiers une fois). Coût des composants au moins cher entre PNJ (marchands déjà visités) et HV, valeur à l'HV ou au PNJ, bénéfice, or/jour possible, et couleur de la recette (orange/jaune = gain de compétence). Le classement suit l'or/jour : bénéfice × ta part des ventes du marché (25 %), ou 20 fabrications par jour revendues au PNJ. Une recette rentable que personne n'achète tombe donc en bas.
  - **Mes objets** : chaque objet de tes sacs et de ta banque (relue à chaque visite), avec un conseil :
    - **Vendre HV** : au prix indiqué, juste sous l'enchère la moins chère, et en quantité limitée à environ une journée de ventes pour ne pas inonder le marché.
    - **Garder** : le prix monte d'au moins 3 %/jour et le marché n'est pas saturé.
    - **PNJ** : le marchand paie plus que l'HV, net des frais.
    - **Attendre** : quelqu'un brade sous 85 % du prix habituel.
    - Un objet qui se vend moins d'une fois tous les 2 jours n'est jamais conseillé à l'HV, car chaque expiration coûte le dépôt. Il va au PNJ si le marchand paie au moins la moitié du net HV, sinon il est à garder (ou à tester en 1 seul exemplaire).
  - **Bilan** : tes ventes, achats et expirations des 30 derniers jours, lus dans tes courriers d'HV (il suffit d'ouvrir la boîte aux lettres). Pour chaque objet : solde, prix moyen obtenu et écart avec le prix prévu par l'addon. Dès 5 ventes, la commission et le dépôt réels de Forever sont mesurés sur tes factures et remplacent les valeurs supposées dans tous les calculs. `/ahl bilan` résume le tout dans le chat.
  - **Achat PNJ** : objets achetés chez des marchands que tu as déjà ouverts et revendables à profit (commission déduite).
  - **Farm** : tes sessions `/ahl farm start` / `/ahl farm stop`, regroupées par zone et valorisées en or/h aux prix actuels.
  - **Revente PNJ** : les enchères affichées moins cher que ce que le marchand en donne, repérées au dernier scan. Il y a deux types : achat immédiat, et enchère qui se termine dans moins de 2 h. Clique sur une ligne pour lancer la recherche de l'objet dans l'onglet « Parcourir » ; l'achat reste manuel.
- Pendant que tu navigues normalement à l'HV, une alerte apparaît dans le chat dès qu'une page affichée contient une affaire à revendre au PNJ.
- Le prix de rachat PNJ vient du client lui-même : c'est le 11e retour de `GetItemInfo` (sellPrice), la même source qu'Auctionator. Si un objet n'est pas encore dans le cache du client, l'addon le complète à la réception de `GET_ITEM_INFO_RECEIVED`. Les prix d'achat chez les PNJ, eux, ne sont relevés que quand tu ouvres un marchand.
- Les tooltips d'objets affichent le prix, la tendance, les ventes par jour et les signaux. Hors de l'HV, l'infobulle est courte par défaut (HV ou PNJ, prix et tendance) ; Maj (Shift) enfoncée affiche le détail complet.
- **Options** : `/ahl options`, le bouton **Options** de la fenêtre, ou la page « AHLedger » des options d'interface du jeu. Infobulle hors HV (courte / complète / rien), à l'HV (complète / courte), Maj pour le détail, pastilles des sacs, scans bruts. Enregistrées dans `AHLedgerDB.opt`.
- **HV ou PNJ ?** En tête du tooltip, et en pastille sur les cases des sacs et de la banque de Daylight UI tant que l'HV est ouverte : vert = l'HV rapporte plus de 10 % de plus que le marchand (net de commission et de dépôts, d'après le dernier scan), jaune = à ±10 % près (le PNJ est plus simple), rouge = au PNJ. Rien sur les objets liés ni sans marché HV observé. Colonne « HV/PNJ » dans l'onglet Mes objets. Seuil : `ns.Bags.SAME_BAND`.
- **Clic sur une ligne, HV ouverte** : l'objet s'affiche à l'achat. Avec Daylight UI, c'est son onglet Acheter (AHLedger remplit la case de recherche du jeu, que Daylight UI surveille comme pour un Maj-clic sur un objet des sacs) ; sinon la recherche d'Auctionator, sinon l'onglet Acheter du jeu. Maj-clic met le lien dans le chat. AHLedger n'achète rien lui-même : tu choisis l'enchère et tu confirmes dans l'écran d'achat (règles Blizzard, et pas d'achat par erreur depuis une liste d'analyse).

## Daylight UI
- Avec Daylight UI, les fenêtres d'AHLedger (analyse et rapport) prennent son allure : coque de fenêtre, police, couleurs, accent et boutons choisis par le joueur. Tout passe par son API publique `DaylightUI.API` (`Look.lua`) ; sans Daylight UI, ce sont les modèles du jeu.
- DaylightUI_AuctionHouse remplace la fenêtre HV du jeu, qui reste ouverte mais invisible. AHLedger ajoute donc un onglet **AHLedger** à côté d'Acheter / Vendre / Mes enchères, dans la fenêtre HV de Daylight UI : pas besoin de repasser par la fenêtre du jeu. Daylight UI n'a pas d'appel public pour ajouter un onglet à son HV : AHLedger passe par `me.Wrap` / `me.Hook` sur les fonctions de son module, la voie que son API.md prévoit, mais sans garantie d'une version à l'autre.
- Si une mise à jour de Daylight UI casse cet onglet, AHLedger affiche à la place un bouton **AHLedger** tant que l'HV est ouverte. Place-le avec `/dui unlock` (« AHLedger (HV) »).
- `/ahl` ressort le contenu dans la fenêtre d'AHLedger ; il revient dans l'onglet au prochain clic dessus.
- Un scan complet lancé depuis l'HV de Daylight UI est lu par AHLedger, comme ceux d'Auctionator.

## Conseils de Claude
Un addon ne peut pas communiquer avec l'extérieur. AHLedger prépare donc un rapport texte de tout ce qu'il sait : marché, tendances, flips, artisanat, sacs, enchères en cours, bilan réel, métiers et zones de farm.
- **Mes enchères en cours** : ta liste d'enchères est relue chaque fois que le jeu l'envoie (ouverture de l'HV, mise en vente, vente, annulation ; si aucun addon ne l'a demandée 4 s après l'ouverture de l'HV, AHLedger la demande une fois, comme la fenêtre du jeu). Le rapport donne pour chaque lot ton prix, le temps restant, le moins cher et le prix réel du dernier scan, le verdict (sous-coté, trop cher, ok) et le temps estimé pour tout vendre à 25 % du marché, ainsi que l'or des ventes à récupérer au courrier.
- **En jeu** : `/ahl claude`, ou le bouton **Rapport Claude** de la fenêtre. Le texte est déjà sélectionné : Ctrl+C, puis colle-le dans une conversation avec Claude.
- **Hors jeu** : le rapport est enregistré dans les SavedVariables après chaque scan et à la déconnexion. `python tools/ahledger.py brief ".../SavedVariables/AHLedger.lua" --out rapport.md` le ressort dans un fichier.

### Synchro Google Drive (Claude lit le rapport tout seul)
1. Installe **Google Drive pour ordinateur** sur le PC de jeu et connecte-toi avec le compte Google relié à Claude. Il crée le lecteur `G:\Mon Drive` (ou `My Drive`), ou une autre lettre si G: est déjà pris. Avec plusieurs comptes Google (un lecteur chacun), le script choisit celui qui contient déjà un dossier `AHLedger` : crée-le dans le bon compte si besoin.
2. Installe Python 3 (cocher « Add to PATH »).
3. Lance `tools/sync_drive.bat` et laisse la fenêtre ouverte pendant que tu joues. Pour qu'il démarre tout seul, mets-en un raccourci dans le dossier Démarrage (`Win+R` puis `shell:startup`). Il trouve tout seul le fichier de l'addon et le dossier Drive ; sinon, ajoute `--sv "<...>\AHLedger.lua"` et/ou `--to "G:\Mon Drive\AHLedger"`.
4. En jeu : un scan, puis `/reload` (ou déconnexion). Le jeu n'écrit ses fichiers qu'à ce moment-là. Le script copie alors le rapport dans `Mon Drive/AHLedger/rapport.md`, et garde les 30 derniers dans `historique/`.
5. Dans Claude : « regarde mon HV ». Claude lit `rapport.md` dans ton Drive.

## Comment c'est calculé
- **Prix** : le prix réel de vente, c'est-à-dire le prix des enchères disparues comme vendues, dès qu'au moins 5 unités ont été vues partir sur 7 jours. Avant ça, la médiane des prix affichés.
- **Vendus/jour** : les unités disparues entre deux scans rapprochés, ramenées à 24 h. Une enchère compte comme vendue s'il lui restait plus de temps que l'écart entre les scans. Si elle était en « court », elle compte comme expirée. Les cas incertains comptent pour moitié.
- **Tendance/j** : régression du prix sur les 7 derniers jours. Il faut au moins 3 jours de scans pour qu'elle s'affiche.
- **Signaux** :
  - `hausse` / `baisse` : le prix varie de plus de 3 % par jour.
  - `pénurie` : le stock a baissé de plus de 30 % (sur 3 jours, par rapport aux 7 jours précédents) alors que la demande tient. Le prix devrait monter : c'est le moment de farmer.
  - `demande+` : les ventes sont en hausse de plus de 30 %.
  - `afflux` : le stock a augmenté de plus de 50 %. Le marché risque de saturer.
  - `PNJ>HV` : l'objet rapporte plus vendu au PNJ qu'à l'HV.
  - `peu de données` : moins de 6 h de marché observées.
  - `stock lourd` : plus de 7 jours de ventes déjà en rayon. Ta pile attendra derrière les autres.
  - `dominé` : un seul vendeur détient au moins 60 % du stock. Attends-toi à te faire sous-coter.
  - `invendus` : moins de 40 % des enchères partent avant d'expirer.
  - `dépeçage` : ton niveau de dépeçage suffit pour récolter cet objet toi-même.
- **Écoulé** : part des enchères vendues avant d'expirer sur 7 jours (avec un a priori de 2 sur 3 tant qu'il y a peu de données).
- **Or/jour** : (prix − commission − dépôts perdus sur les remises en vente) × vendus/jour. Le dépôt est estimé à 15 % du prix PNJ par mise en vente (`Analysis.DEPOSIT_RATE`, à vérifier sur Forever).
- **Score « à farmer »** : or/jour × (1 + 3 × tendance, borné entre 0,5 et 1,5) × signaux (pénurie ×1,2, demande ×1,1, afflux ×0,8, stock lourd ×0,75, dominé ×0,85). Le tout est pondéré par la confiance dans le volume, v / (v + 3) où v = unités vues vendues : une seule vente observée ne place plus un objet en tête.

## Métiers
- **Montée de niveau** : dans l'onglet Artisanat, le bouton **Vue : montée de niveau** classe tes recettes par coût d'un point de compétence : (composants − revente) ÷ chance de gain. Un coût négatif veut dire que tu montes en gagnant de l'or, à condition de tout revendre. Le plan ne compte à l'HV que ta part (25 %) de 2 jours de ventes de chaque objet fabriqué ; le reste est valorisé au prix PNJ. Un bénéfice ne compte qu'une fois par point de compétence, pour ne pas préférer une recette presque grise qui demande des dizaines de fabrications. Le plan affiche aussi l'or **à avancer** (composants et recettes à acheter avant de revendre).
- `/ahl monter cuir 225` donne le plan complet : quelles recettes fabriquer, combien de fois, les composants à réunir et le coût net. Sans addon de recettes (OneForAll absent), seule la couleur actuelle de tes recettes est connue : le plan s'arrête après quelques points et le signale.
- **OneForAll** (addon compagnon de Forever) est lu s'il est installé : toutes les recettes du client Forever avec leurs seuils jaune/vert/gris, le niveau pour les apprendre et leur source (maître et son prix, marchand de ta faction et son prix, butin, quête). Une recette de butin ou payée en faveur marchande prend le prix de son objet-recette à l'HV s'il y est vu. Le plan `/ahl monter` va alors jusqu'au bout et propose les recettes à acheter. L'adaptateur (`RecipesOneForAll.lua`) lit sa table globale `OneForAll` au moment du calcul, sans rien recopier. `/ahl diag` indique combien de recettes il a lues.
- **Brancher un autre addon de recettes** : `ns.RecipeDB.Register(nom, { Recipes = function(métier) … end })` dans `RecipeDB.lua`. Le format attendu (seuils jaune/vert/gris, source et prix de la recette) est décrit en tête du fichier. Le planificateur et l'onglet Montée s'en servent aussitôt.
- `/ahl metiers` affiche tes niveaux, le niveau maximal des monstres que tu peux dépecer, et les métiers dont les recettes ne sont pas encore relevées.
- La catégorie **Mes métiers** de l'onglet Marché ne montre que ce qui te concerne : ce que tu peux dépecer, ce que tu fabriques et leurs composants.
- Les seuils de dépeçage des cuirs et écailles (`Professions.lua`) sont approximatifs.

## Commandes
`/ahl` · `/ahl options` · `/ahl scan` · `/ahl status` · `/ahl metiers` · `/ahl bilan` · `/ahl claude` · `/ahl diag` · `/ahl monter <métier> [niveau]` · `/ahl farm start|stop` · `/ahl raw on|off` (snapshots bruts pour l'export Python) · `/ahl prune <n>`

## Export Python (optionnel)
```
python tools/ahledger.py import ".../WTF/Account/<COMPTE>/SavedVariables/AHLedger.lua"
python tools/ahledger.py report --days 7
python tools/ahledger.py brief ".../SavedVariables/AHLedger.lua" --out rapport.md
```

## Diagnostic
`/ahl diag` vérifie, module par module, quelles fonctions du jeu sont présentes sur ton client et quelle variante (Classic ou Retail) l'addon utilise. Il affiche aussi les événements que le client refuse, les erreurs survenues depuis la connexion et ce qui a déjà été collecté. Le diagnostic est aussi ajouté au rapport pour Claude.

## Tests hors jeu
`pip install lupa luaparser`, puis `python tests/check_globals.py` (variables globales : fautes de frappe, `local` oublié) et `python tests/run_test.py`. GitHub les lance à chaque push (`.github/workflows/tests.yml`), avec en plus `luacheck`, pour l'instant à titre indicatif. Le test simule 14 jours de marché, 6 scans par soir, et vérifie que la hausse, la baisse, la pénurie et l'afflux sont bien détectés.

## Notes Forever (vérifiées en jeu le 22/11/2026)
- Forever n'a **pas** l'API d'HV Classic (`QueryAuctionItems` absent) : il utilise l'API Retail `C_AuctionHouse` (scan complet par `ReplicateItems`).
- **Intégration Auctionator** (Bridge.lua) : AHLedger s'abonne à l'événement interne `replicate_scan_complete` d'Auctionator, qui transmet toutes les enchères avec leur temps restant. Le bouton de scan d'AHLedger déclenche le scan d'Auctionator : un seul scan et un seul délai de 15 min pour les deux addons.
- Tant qu'AHLedger a moins de 3 jours de scans, les tendances viennent de l'historique de prix d'Auctionator (`Auctionator.Database`, jusqu'à ~21 jours). Il faut au moins 3 jours de prix sur 2 jours d'écart ; la pente est robuste (Theil-Sen, médiane des pentes entre paires de jours), pour qu'une enchère aberrante ne fasse pas exploser la tendance.
- Forever ne transmet pas le nom des vendeurs : la colonne « vendeurs » affiche « - » et le signal « dominé » ne se déclenche pas.
- Les noms d'objets manquants (pas encore dans le cache du client) sont redemandés au serveur à chaque connexion, 100 par seconde.
- Sans Auctionator, AHLedger fait son propre scan via `C_AuctionHouse.ReplicateItems`.
- L'alerte en direct pendant la navigation ne marche qu'avec l'API Classic ; sur Forever, la détection passe par les scans complets. Cliquer sur une ligne de l'onglet Revente PNJ lance la recherche via l'API publique d'Auctionator (`MultiSearch`).
- Commission HV de Forever : 5 % (mesurée sur les factures des ventes d'équipement, 23/11/2026).
- Factures d'HV (`GetInboxInvoiceInfo`) : la quantité est le 11e retour ; pour une pile vendue, le champ « rachat » contient la quantité, pas le prix. Le prix est lu dans le champ « enchère », et recalculé depuis l'or du courrier s'il paraît faux. Les lignes relevées par la 0.8.0 (quantité 0, doublons quand on récupère l'or) sont réparées au chargement.

## Règles Blizzard (résumé, sans valeur juridique)
- L'addon reste gratuit, avec un code lisible, et ne fait aucune publicité ni appel aux dons.
- Il ne doit pas nuire aux royaumes : on se limite au scan complet autorisé par le serveur, lancé par un clic du joueur.
- Aucune automatisation hors de l'environnement des addons : pas de bot, pas de scan sans action de ta part.
