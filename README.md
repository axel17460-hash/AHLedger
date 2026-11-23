# AHLedger (v0.8)

Addon pour WoW: Forever. Il repère les objets les plus rentables à vendre à l'hôtel des ventes et suit les hausses et baisses de prix, pour savoir quoi farmer avant tout le monde. L'analyse se fait entièrement en jeu.

## Installation
1. Copier le dossier `AHLedger/` dans `World of Warcraft/_forever_/Interface/AddOns/`. Le nom exact du dossier client est à vérifier ; les sous-dossiers `tools/` et `tests/` peuvent rester, le jeu les ignore.
2. Le `.toc` est réglé sur l'Interface 16001 (Forever 1.60, même valeur qu'Auctionator).

## Utilisation
- À l'HV, deux boutons s'ajoutent à droite de la fenêtre : **AHLedger : scan** et **AHLedger : analyse**. Lance un scan toutes les 15 à 60 min pendant que tu joues : plus il y a de scans rapprochés, meilleures sont les estimations de volume.
- `/ahl` ouvre la fenêtre d'analyse :
  - **Marché** : classement par score « à farmer », avec prix, tendance/jour, vendus/jour, stock, or/jour et signaux. Filtres par catégorie et option pour n'afficher que les marchés liquides. Clique sur un en-tête pour trier.
  - **Flip HV** : enchères affichées sous le prix réel de vente. Pour chaque objet : jusqu'à quel prix unitaire acheter, combien (au plus 2 jours de ventes), à quel prix revendre (juste sous la prochaine enchère restante, sans dépasser le prix réel de vente) et le bénéfice attendu, net de la commission et des dépôts perdus sur les invendus. Seuils : ROI ≥ 15 % et bénéfice ≥ 20 pa. Clic = rechercher l'objet.
  - **Artisanat** : tes recettes, relevées quand tu ouvres une fenêtre de métier (ouvre chacun de tes métiers une fois). Coût des composants au moins cher entre PNJ (marchands déjà visités) et HV, valeur à l'HV ou au PNJ, bénéfice, et couleur de la recette (orange/jaune = gain de compétence).
  - **Mes objets** : chaque objet de tes sacs et de ta banque (relue à chaque visite), avec un conseil :
    - **Vendre HV** : au prix indiqué, juste sous l'enchère la moins chère, et en quantité limitée à environ une journée de ventes pour ne pas inonder le marché.
    - **Garder** : le prix monte d'au moins 3 %/jour et le marché n'est pas saturé.
    - **PNJ** : le marchand paie plus que l'HV, net des frais.
    - **Attendre** : quelqu'un brade sous 85 % du prix habituel.
  - **Bilan** : tes ventes, achats et expirations des 30 derniers jours, lus dans tes courriers d'HV (il suffit d'ouvrir la boîte aux lettres). Pour chaque objet : solde, prix moyen obtenu et écart avec le prix prévu par l'addon. Dès 5 ventes, la commission et le dépôt réels de Forever sont mesurés sur tes factures et remplacent les valeurs supposées dans tous les calculs. `/ahl bilan` résume le tout dans le chat.
  - **Achat PNJ** : objets achetés chez des marchands que tu as déjà ouverts et revendables à profit (commission déduite).
  - **Farm** : tes sessions `/ahl farm start` / `/ahl farm stop`, regroupées par zone et valorisées en or/h aux prix actuels.
  - **Revente PNJ** : les enchères affichées moins cher que ce que le marchand en donne, repérées au dernier scan. Il y a deux types : achat immédiat, et enchère qui se termine dans moins de 2 h. Clique sur une ligne pour lancer la recherche de l'objet dans l'onglet « Parcourir » ; l'achat reste manuel.
- Pendant que tu navigues normalement à l'HV, une alerte apparaît dans le chat dès qu'une page affichée contient une affaire à revendre au PNJ.
- Le prix de rachat PNJ vient du client lui-même : c'est le 11e retour de `GetItemInfo` (sellPrice), la même source qu'Auctionator. Si un objet n'est pas encore dans le cache du client, l'addon le complète à la réception de `GET_ITEM_INFO_RECEIVED`. Les prix d'achat chez les PNJ, eux, ne sont relevés que quand tu ouvres un marchand.
- Les tooltips d'objets affichent le prix, la tendance, les ventes par jour et les signaux.

## Conseils de Claude
Un addon ne peut pas communiquer avec l'extérieur. AHLedger prépare donc un rapport texte de tout ce qu'il sait : marché, tendances, flips, artisanat, sacs, bilan réel, métiers et zones de farm.
- **En jeu** : `/ahl claude`, ou le bouton **Rapport Claude** de la fenêtre. Le texte est déjà sélectionné : Ctrl+C, puis colle-le dans une conversation avec Claude.
- **Hors jeu** : le rapport est enregistré dans les SavedVariables après chaque scan et à la déconnexion. `python tools/ahledger.py brief ".../SavedVariables/AHLedger.lua" --out rapport.md` le ressort dans un fichier.

### Synchro Google Drive (Claude lit le rapport tout seul)
1. Installe **Google Drive pour ordinateur** sur le PC de jeu et connecte-toi avec le compte Google relié à Claude. Il crée le lecteur `G:\Mon Drive` (ou `My Drive`).
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
- **Score « à farmer »** : or/jour × (1 + 3 × tendance, borné entre 0,5 et 1,5) × signaux (pénurie ×1,2, demande ×1,1, afflux ×0,8, stock lourd ×0,75, dominé ×0,85).

## Métiers
- **Montée de niveau** : dans l'onglet Artisanat, le bouton **Vue : montée de niveau** classe tes recettes par coût d'un point de compétence : (composants − revente) ÷ chance de gain. Un coût négatif veut dire que tu montes en gagnant de l'or.
- `/ahl monter cuir 225` donne le plan complet : quelles recettes fabriquer, combien de fois, les composants à réunir et le coût net. Tant qu'aucun addon de recettes n'est branché, seule la couleur actuelle de tes recettes est connue : le plan s'arrête après quelques points et le signale.
- **Brancher un addon de recettes** : `ns.RecipeDB.Register(nom, { Recipes = function(métier) … end })` dans `RecipeDB.lua`. Le format attendu (seuils jaune/vert/gris, source et prix de la recette) est décrit en tête du fichier. Le planificateur et l'onglet Montée s'en servent aussitôt.
- `/ahl metiers` affiche tes niveaux, le niveau maximal des monstres que tu peux dépecer, et les métiers dont les recettes ne sont pas encore relevées.
- La catégorie **Mes métiers** de l'onglet Marché ne montre que ce qui te concerne : ce que tu peux dépecer, ce que tu fabriques et leurs composants.
- Les seuils de dépeçage des cuirs et écailles (`Professions.lua`) sont approximatifs.

## Commandes
`/ahl` · `/ahl scan` · `/ahl status` · `/ahl metiers` · `/ahl bilan` · `/ahl claude` · `/ahl diag` · `/ahl monter <métier> [niveau]` · `/ahl farm start|stop` · `/ahl raw on|off` (snapshots bruts pour l'export Python) · `/ahl prune <n>`

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
- Tant qu'AHLedger a moins de 3 jours de scans, les tendances viennent de l'historique de prix d'Auctionator (`Auctionator.Database`, jusqu'à ~21 jours).
- Sans Auctionator, AHLedger fait son propre scan via `C_AuctionHouse.ReplicateItems`.
- L'alerte en direct pendant la navigation ne marche qu'avec l'API Classic ; sur Forever, la détection passe par les scans complets. Cliquer sur une ligne de l'onglet Revente PNJ lance la recherche via l'API publique d'Auctionator (`MultiSearch`).
- Reste à vérifier : le taux de la commission HV (`Analysis.AH_CUT`).

## Règles Blizzard (résumé, sans valeur juridique)
- L'addon reste gratuit, avec un code lisible, et ne fait aucune publicité ni appel aux dons.
- Il ne doit pas nuire aux royaumes : on se limite au scan complet autorisé par le serveur, lancé par un clic du joueur.
- Aucune automatisation hors de l'environnement des addons : pas de bot, pas de scan sans action de ta part.
