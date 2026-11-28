# AHLedger 1.0 : plan de refonte (26/11/2026)

But du joueur : être accompagné au maximum. Ouvrir l'HV, lire « vends ceci à ce prix », cliquer **Vendre**. Des signaux façon bourse (Acheter, Vendre, Garder, Lâcher), avec une projection chiffrée, et vérifiés après coup. Suivre ses vrais coûts (HV et marchand) et savoir quelles opérations continuer ou lâcher.

Règle Blizzard qui encadre tout : **un clic = une enchère**. Aucune mise en vente, aucun achat ni aucune annulation sans clic, et jamais plusieurs enchères pour un seul clic.

Sauvegarde d'avant la refonte (code + SavedVariables) : `_forever_\AHLedger_backup_2026-11-26_refonte`.

## Ce que l'audit du superviseur a trouvé (état 0.10)
- **Les chiffres sont calculés plusieurs fois, de façons différentes** : 6 formules de prix net, 5 façons de fixer un prix de mise en vente, 4 coûts de fabrication, 5 définitions du « bilan », 3 rapprochements achat → vente. C'est la cause des contradictions qu'on voit en jeu.
  - Long Elegant Feather : « Remettre, prouvé » dans Conseils, mais « prix douteux » dans Mes objets.
  - Tanning Rack : « trop cher » d'un côté, « vends à 24s 79c » de l'autre.
  - Ventes de farm comptées dans un bilan et pas dans l'autre.
  - La colonne « Gain » change de sens d'une ligne à l'autre.
- **Barres fondues avec ton propre minerai** : elles sont jugées « à perte », parce que le minerai est compté au prix de l'HV. En plus, le coût est calculé sur une seule enchère, quel que soit le nombre d'unités nécessaires.
- **Interface** : 8 onglets et 15 vues. Les colonnes « Pourquoi » et « Conseil » sont toujours coupées, et « Ce qui marche » est plus large que la fenêtre.
- **Données fragiles qui peuvent encore produire un conseil faux** :
  - un scan à 40-60 % passe le garde-fou, et ses enchères manquantes comptent comme des ventes ;
  - le « plus bas habituel » d'Auctionator n'est jamais recoupé ;
  - les flips utilisent un scan vieux de plusieurs heures ;
  - la commission et le dépôt mesurés n'ont pas de bornes.

## Phases (chacune : tests, rejeu sur tes vraies données, superviseur, puis **ton test en jeu** avant la suivante)

### Phase 1. Fondations : un seul calcul par chiffre (rien de visible, mais tout devient cohérent)
- Prix net, prix de mise en vente, coût, confiance : une seule fonction pour chacun, dans `Decide`. Advisor, Auctions, Positions, Tracker, Tooltip, RecipeDB et UI ne font plus que la lire.
- Une seule définition du bilan (celle de `Tracker` : farm + reventes − dépôts perdus), partout, y compris dans `/ahl bilan` et le rapport.
- Garde-fous :
  - un scan incomplet, ou dont des lignes ne se sont pas chargées, ne compte plus de ventes ;
  - le prix d'Auctionator est recoupé avec les ventes vues ;
  - coût des composants calculé en parcourant les enchères pour la quantité voulue ;
  - au-delà de 6 h, un scan est « périmé » partout ;
  - commission et dépôt bornés.
- Corrige les contradictions de la plume et du Tanning Rack, ainsi que le PNJ « rentable » sans marge.

### Phase 2. Prix d'équilibre et sous-cotes
- **Prix d'équilibre** = le prix auquel l'objet part vraiment : la médiane des enchères vendues ces 7 derniers jours, tirée des scans. Plus de « 1c sous la moins chère » par réflexe.
- **Projection de chaque mise en vente** : « part en ~6 h, 80 % de chances, +2g 18s ». Elle vient des ventes vues à ce niveau de prix.
- **Quel prix poser** :
  - la moins chère est proche de l'équilibre : 1c dessous ;
  - quelqu'un brade loin sous l'équilibre : attendre, garder ou PNJ, selon ce qui rapporte le plus ;
  - l'objet est surveillé par un robot (sous-cotes en moins de 10 min, à toute heure) : on ne suit pas la course. On propose l'heure creuse mesurée, ou le PNJ, ou garder.
- **Durée conseillée** de l'enchère, selon la vitesse de vente et le dépôt.

### Phase 3. Tes vrais coûts
- **Achats chez le marchand** : relevés quand tu achètes (objet, quantité, prix payé), dans le même journal que les achats HV, qui sont déjà relevés.
- **Prix de revient de chaque unité** :
  - achetée : le prix payé (le plus ancien achat d'abord) ;
  - fabriquée : ses composants à leur propre prix de revient ;
  - farmée : ce qu'elle vaudrait vendue brute. Ça règle le cas des barres.
- **Matière brute ou fabriqué** : pour chaque recette, « vendre les composants bruts rapporte X, fabriquer puis vendre rapporte Y ». On ne conseille de fabriquer que si Y bat X et que l'objet fabriqué se vend.

### Phase 4. Signaux et vérification (« la bourse »)
- Chaque signal (Vendre, Acheter, Garder, Lâcher, Fabriquer) enregistre sa projection.
- Les scans et courriers suivants disent s'il avait raison : vendu au prix prévu, dans le délai prévu ?
- **Taux de réussite par type de signal**. Un type qui se trompe souvent perd sa confiance, puis n'est plus proposé.
- **Opérations à continuer ou à lâcher** : un tableau par activité (farm, revente, flip, achat PNJ, craft), objet par objet. On y voit le bilan réel sur 30 j, l'or par jour, la part vendue et la tendance, puis le verdict **Continuer / Ajuster le prix / Lâcher**, tiré des résultats mesurés.

### Phase 5. Interface : 5 onglets, la décision d'abord
1. **Aujourd'hui** : la file « À vendre ». Pour chaque ligne : objet, quantité, prix, durée, projection, puis **[Vendre]** ou **[Passer]**. Viennent ensuite les autres gestes (courrier, enchères à reprendre, PNJ, fabriquer), dans l'ordre.
2. **Mon stock** : sacs, banque et enchères en cours dans une seule liste, avec le prix de revient et la décision.
3. **Opérations** : continuer ou lâcher, le bilan unique en tête, une courbe du bilan jour par jour.
4. **Artisanat** : matière brute ou fabriqué, prix rentable, montée de métier.
5. **Marché** : signaux Acheter / Vendre, flips, achats PNJ, courbe de prix sur 7 j de l'objet choisi.
- **Panneau de détail** sous le tableau : la ligne choisie s'y affiche en entier (raison, projection, preuves et leur source). Fini les colonnes coupées. Au plus 7 colonnes par vue, chacune avec sa définition au survol.
- **Le bouton Vendre** poste l'enchère par l'API du jeu, une enchère par clic. Si l'API manque sur Forever, il prépare l'onglet de vente de l'HV : tu n'as plus qu'à valider.

### Phase 6. Finitions
- Infobulle et rapport `/ahl claude` alignés sur les mêmes chiffres.
- Ancien code mort retiré, README, HANDOVER.
- Migration des SavedVariables : l'historique et les achats sont gardés.

## À vérifier en jeu (hypothèses)
- `C_AuctionHouse.PostItem` / `PostCommodity` : présents et utilisables depuis un clic sur Forever ? `/ahl diag` le dira.
- Relevé des achats chez le marchand (`BuyMerchantItem`), et quantité exacte pour les piles.
