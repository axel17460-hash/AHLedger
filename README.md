# AHLedger (v0.2)

Addon pour WoW: Forever. Il repère les objets les plus rentables à vendre à l'hôtel des ventes et suit les hausses et baisses de prix, pour savoir quoi farmer avant tout le monde. L'analyse se fait entièrement en jeu.

## Installation
1. Copier le dossier `AHLedger/` dans `World of Warcraft/_forever_/Interface/AddOns/`. Le nom exact du dossier client est à vérifier ; les sous-dossiers `tools/` et `tests/` peuvent rester, le jeu les ignore.
2. Le `.toc` est réglé sur l'Interface 16001 (Forever 1.60, même valeur qu'Auctionator).

## Utilisation
- À l'HV, deux boutons s'ajoutent à droite de la fenêtre : **AHLedger : scan** et **AHLedger : analyse**. Lance un scan toutes les 15 à 60 min pendant que tu joues : plus il y a de scans rapprochés, meilleures sont les estimations de volume.
- `/ahl` ouvre la fenêtre d'analyse :
  - **Marché** : classement par score « à farmer », avec prix, tendance/jour, vendus/jour, stock, or/jour et signaux. Filtres par catégorie et option pour n'afficher que les marchés liquides. Clique sur un en-tête pour trier.
  - **Achat PNJ** : objets achetés chez des marchands que tu as déjà ouverts et revendables à profit (commission déduite).
  - **Farm** : tes sessions `/ahl farm start` / `/ahl farm stop`, regroupées par zone et valorisées en or/h aux prix actuels.
  - **Revente PNJ** : les enchères affichées moins cher que ce que le marchand en donne, repérées au dernier scan. Il y a deux types : achat immédiat, et enchère qui se termine dans moins de 2 h. Clique sur une ligne pour lancer la recherche de l'objet dans l'onglet « Parcourir » ; l'achat reste manuel.
- Pendant que tu navigues normalement à l'HV, une alerte apparaît dans le chat dès qu'une page affichée contient une affaire à revendre au PNJ.
- Le prix de rachat PNJ vient du client lui-même : c'est le 11e retour de `GetItemInfo` (sellPrice), la même source qu'Auctionator. Si un objet n'est pas encore dans le cache du client, l'addon le complète à la réception de `GET_ITEM_INFO_RECEIVED`. Les prix d'achat chez les PNJ, eux, ne sont relevés que quand tu ouvres un marchand.
- Les tooltips d'objets affichent le prix, la tendance, les ventes par jour et les signaux.

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
- **Score « à farmer »** : or/jour × (1 + 3 × tendance, borné entre 0,5 et 1,5) × bonus de signaux (pénurie ×1,2, demande ×1,1, afflux ×0,8).

## Commandes
`/ahl` · `/ahl scan` · `/ahl status` · `/ahl farm start|stop` · `/ahl raw on|off` (snapshots bruts pour l'export Python) · `/ahl prune <n>`

## Export Python (optionnel)
```
python tools/ahledger.py import ".../WTF/Account/<COMPTE>/SavedVariables/AHLedger.lua"
python tools/ahledger.py report --days 7
```

## Tests hors jeu
`pip install lupa` puis `python tests/run_test.py`. Le test simule 14 jours de marché, 6 scans par soir, et vérifie que la hausse, la baisse, la pénurie et l'afflux sont bien détectés.

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
