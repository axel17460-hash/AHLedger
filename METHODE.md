# AHLedger — méthode d'analyse du rapport (v1)

Ce document dit à une session Claude **comment lire `rapport.md`** (produit par `/ahl claude` ou par `tools/ahledger.py sync`, dans `Mon Drive/AHLedger/`) et **comment en tirer des conseils cohérents** d'une séance à l'autre. Il est copié à côté du rapport par `sync` ; la 2e ligne du rapport donne la version de la méthode attendue (`Export.METHODE` dans `Export.lua`). Si elle diffère de la version ci-dessus, signale-le au joueur en une ligne et applique quand même ce document.

Réponds dans la langue du joueur (français ou anglais). Tous les chiffres viennent du rapport : n'en invente aucun ; un calcul fait par toi (somme, part, estimation de temps) est annoncé comme tel.

---

## 1. Règles absolues

1. **Aucune automatisation.** Ne propose jamais de macro d'achat ou de vente, de « tout poster », de bot, de scan sans clic, d'outil qui lit ou pilote le jeu. AHLedger lui-même exige un clic ou une touche par mise en vente / annulation (`Sell.Post`, `Sell.CancelNext`) et n'achète jamais seul. Règles Blizzard : voir README, « Règles Blizzard ».
2. **Ne jamais immobiliser plus d'or que le joueur n'en a.** L'en-tête donne `Or : …` et `Budget d'un conseil d'achat : …` (`Analysis.BUDGET_SHARE` = 50 % de l'or). Chaque conseil d'achat est plafonné **séparément** au budget : deux flips à 50 % chacun = 100 % de l'or. Additionne le coût de tous tes achats conseillés (flips, achats PNJ, composants, recettes à apprendre, « à avancer » des montées) et reste **sous l'or disponible**, idéalement sous le budget. Si `Or : 0c` ou or inconnu, ne conseille aucun achat chiffré avant que le joueur donne son or.
3. **Pas de conseil sur un prix non prouvé** sans le dire : un prix « à tester » se teste en 1 unité (5 sur un marché à 100 ventes/j ou plus), comme le fait l'addon (`Bags.Advise`).
4. **Absent du rapport ≠ inexistant.** Chaque section est tronquée (`Export.TOP` : 25 objets de marché, 12 flips, 25 objets des sacs…). Ne conclus pas « rien d'autre à faire ».

---

## 2. Avant tout : l'en-tête (confiance globale)

| Ligne | Ce qu'elle dit | Ce que tu en fais |
|---|---|---|
| `# AHLedger — rapport pour Claude (date)` | heure de génération | Rapport de plus de ~12 h : prix périmés, dis-le. |
| `Méthode de lecture : METHODE.md vN` | version attendue de ce document | voir plus haut |
| `Royaume · Perso · Or` | `A.Gold()` : or relevé à chaque `PLAYER_MONEY` | plafond absolu de tes achats |
| `Métiers` | niveaux / max | ce qu'il peut fabriquer, dépecer |
| `Données : N j d'historique, H h de marché observées, dernier scan …` | `db.days`, somme des écarts entre scans couverts | **Moins de 3 j : pas de tendance AHLedger** (`robustSlope(pts, 2)` exige 3 jours sur 2 jours d'écart ; repli sur Auctionator). **Dernier scan de plus de ~2 h** : carnet périmé, flips et undercuts à revérifier par un scan. |
| `commission X % (mesurée / supposée), dépôt Y % du prix PNJ` | `Analysis.AH_CUT`, `Analysis.DEPOSIT_RATE`, remplacés par `Ledger.Calibrate` dès `Ledger.MIN_CALIB` = 5 ventes au courrier | « supposée » : commission 5 % (probablement juste, mesurée sur l'équipement le 23/11/2026) mais **dépôt 15 % alors que ~43 % a été mesuré** sur Forever : les nets sont alors **surestimés** pour les objets à prix PNJ élevé et faible écoulement. Voir pièges. |
| `Tes ventes réelles vs prix prévu : −X % … corrigé ×F` | `Ledger.BiasTable` : prix obtenu / prix prévu, par courrier, borné entre `Ledger.BIAS_MIN` 0,4 et `BIAS_MAX` 1 | Déjà appliqué à tous les **nets** (or/jour, sacs, artisanat, achats PNJ, revente des flips), **pas** au prix de marché affiché. Ne l'applique pas une 2e fois. Un écart moyen de −10 % ou pire veut dire : le joueur vend sous le prix affiché, sois prudent sur les marges fines. |
| `Budget d'un conseil d'achat` | `Analysis.Budget()` = or × `BUDGET_SHARE` | plafond par opération |

**Verdict de séance** à poser d'abord (une ligne) : *données jeunes* (< 3 j ou < 24 h observées), *correctes* (3–7 j), *mûres* (≥ 7 j et commission mesurée). Avec des données jeunes, ne conseille que des actions sûres (vendre ce qui se vend, PNJ) et des tests.

---

## 3. Lecture section par section

Unités : prix **par unité** sauf mention ; `g/s/c` = or / argent / cuivre (1g = 100s = 10 000c). `tend` = variation de prix **par jour**.

### 3.1 `## Marché : meilleurs scores`
Seulement les objets à **au moins 1 vendu/j** (`s.perDay >= 1`), triés par `s.score`.

| Colonne | Sens | Origine (`Analysis.ItemStats`) | Fiabilité |
|---|---|---|---|
| prix | prix réel de vente si ≥ `MIN_SOLD_FOR_REAL` = 5 unités vues parties sur 7 j (et entre 0,4 et 1,5 × le prix affiché), sinon prix affiché moyen du dernier jour, **plafonné au plus haut prix vu vendu** (`s.capped`, `Trust.Evidence`) | `s.price` | bonne si prix réel ; sinon c'est un prix demandé |
| achat min | enchère la moins chère du dernier scan (peut être celle du joueur, ou un troll à 1 unité) | `db.lastMin` | instantané |
| moy 7j | moyenne des prix affichés par jour sur 7 j | `s.avg7` | — |
| tend 7j | pente robuste (Theil-Sen) du log-prix, 7 j | `s.trend` ; repli Auctionator (≥ 4 jours sur 3 j d'écart, prix **minimums**) | « - » = moins de 3 jours |
| tend 24h | régression sur les scans des 24 h (≥ 2 scans sur ≥ 2 h) | `Analysis.ShortTrend` | bruitée, indicative |
| vendus/j | unités disparues avant leur fin, ramenées à 24 h ; ambiguës pour moitié | `s.perDay` | **estimée** (voir biais de scan) |
| relistes/j | retraits repérés (pile partie alors qu'une moins chère reste), écartés des ventes | `s.relistPerDay` | si relistes/j ≥ vendus/j, le volume est suspect |
| stockJ | stock moyen des 3 derniers jours ÷ vendus/j | `s.stockDays` | > `HEAVY_STOCK_DAYS` = 7 : saturé |
| écoul | part des enchères vendues avant expiration, a priori 2/3 : (vendus + 2) / (vendus + expirés + 3) | `s.sellThrough` | < 40 % : signal `invendus` |
| vendeurs | toujours « - » sur Forever (pas de nom de vendeur) | — | inutilisable |
| or/jour | net par unité (commission, dépôts perdus sur relances, correction) × vendus/j ; au prix habituel pendant un pic | `s.gpd`, `Analysis.SafeNet` | potentiel du **marché entier**, pas du joueur : sa part réaliste est ~25 % (`Analysis.VENDOR_SHARE`) |
| signaux | voir § 5 | | |

Le **score** = or/jour × (1 + 3 × tend, borné 0,5–1,5) × signaux (pénurie ×1,2, demande+ ×1,1, afflux ×0,8, stock lourd ×0,75, dominé ×0,85, prix non tenu ×0,5) × confiance v/(v+3), v = ventes vues (ambiguës pour moitié). Le score sert à **choisir quoi farmer**, pas à vendre.

### 3.2 `## Plus fortes variations de prix`
Marchés à ≥ 1 vendu/j et confiance ≥ 0,5 (≥ 3 ventes vues), triés par |tend 7j|. Sert à la **tendance** (dernier critère de décision). Une tendance venue d'Auctionator repose sur des minimums : une enchère bradée suffit à la creuser.

### 3.3 `## Flips HV possibles`
`Analysis.FlipFor`, seulement si prix réel connu et ≥ 1 vendu/j.
- **[tout de suite]** : quelqu'un brade, le reste du marché est au prix. Quantité ≤ `FLIP_HOLD_DAYS` = 2 jours de ventes ; revente juste sous la prochaine enchère restante, sans dépasser le prix réel corrigé, ni `moy 7j`, ni le prix habituel en pic. Retenu si ROI ≥ `FLIP_MIN_ROI` 15 % **et** bénéfice ≥ `FLIP_MIN_PROFIT` 20s. Le plus fiable des flips.
- **[à stocker]** : tout le marché est bas (creux `Rebound.DIP` = 15 % sous la médiane des 7 j précédents). Bénéfice **espéré** = chance de rebond × revente au prix d'avant + chance contraire × revente au prix du jour. `ROI ≥ FLIP_STORE_MIN_ROI` 25 %, prix d'avant ≥ revente immédiate + `FLIP_STORE_GAP` 10 %. Pas de stockage si tendance ≤ −3 %/j, sauf rebond prouvé (≥ 3 creux connus et taux ≥ 60 %).
  - « X creux sur Y remontés, délai médian N j, lent M j » : `known` (≥ `Rebound.MIN_EVENTS` = 3 creux terminés). Chance = (remontés + 1) / (creux + 2). M = délai sous lequel 8 rebonds sur 10 ont eu lieu : **l'or est immobilisé jusqu'à M jours**.
  - « rebond inconnu, quantité de test » : moins de 3 creux, ½ journée de ventes (`FLIP_TEST_DAYS`), ≤ `FLIP_TEST_MAX_QTY` 20 u et ≤ `FLIP_TEST_MAX_COST` 20g. À traiter comme un **test**.
- « quantité limitée par ton budget », « N flips écartés : hors de ton budget » : informatif.
- « tes reventes : … » : le joueur l'a déjà fait (`Ledger.Holds`) : preuve forte, positive ou négative.

### 3.4 `## Artisanat (recettes connues)`
`Analysis.Crafts` + `Analysis.CraftSale`. « coût » = composants au moins cher PNJ/HV ; « valeur (HV|PNJ) » ; « ~fabrications/j » = ta part (25 %) des **ventes sûres** (le plus bas de 7 j et des dernières `RECENT_OBS` = 6 h), ou `CRAFT_VENDOR_PER_DAY` = 20/j au PNJ.
- « pic de prix … valeur comptée au prix habituel » : ne fabrique pas pour le pic.
- « HV écartée (…) : vends plutôt les composants » : l'objet fabriqué se vend à moins de `CRAFT_MIN_SURE_PER_DAY` = 0,5 vente sûre/j ou a plus de `CRAFT_MAX_BACKLOG_DAYS` = 3 j de stock en rayon. **Respecte-le** (cas réel des Pilferer's Gloves).
- Coût calculé à l'enchère la moins chère du dernier scan : acheter 20 composants peut coûter plus cher (carnet non parcouru).

### 3.5 `## Recettes rentables à poursuivre`
`Opp.BuildRecipes` : bénéfice ≥ `Opp.RECIPE_MIN_PROFIT` 1s et ROI ≥ `RECIPE_MIN_ROI` 15 %, prix non tenu écarté. Or/jour = bénéfice × 25 % des ventes **brutes** × confiance (moins prudent que l'Artisanat, qui prend les ventes sûres). « amortie en N j » : prix de la recette ÷ or/jour. Une recette à apprendre est un **achat** : elle compte dans l'or immobilisé.

### 3.6 `## Sous-coter`
`Opp.UndercutFor` : l'enchère la moins chère − 1c (`UNDERCUT_STEP`) dépasse le prix (`s.price`) d'au moins `UNDERCUT_MIN_PREMIUM` 10 %, gain en plus ≥ `UNDERCUT_MIN_GAIN` 2s, ≥ 1 vendu/j. Quantité = 1 jour de ventes (`UNDERCUT_POST_DAYS`). Prix non tenu écarté ; « à tester » signalé. Ne vaut que si le joueur **a** l'objet ou peut le fabriquer moins cher (« tu en as N », « fabricable »).

### 3.7 `## Montée <métier> A → B`
`ns.Plan.Level` : coût net (négatif = gain si tout se revend), **« à avancer »** = or à sortir avant de revendre (compte dans l'or immobilisé), « (tu n'as que …) » = impossible en l'état. « plan partiel » = seuils de recettes inconnus (pas d'addon de recettes) : ne promets pas le niveau final.

### 3.8 `## Mes objets (sacs + banque)`
`Bags.Advise`, une ligne par objet : action, prix et quantité, valeur nette, raison.
- **Vendre HV** à `post`/u, `postQty` à la fois (≈ 1 jour de ventes ; 1 si « à tester »). Prix = moins cher − 1c, ≤ 1,2 × prix, ≤ plus haut prix vu vendu.
- **PNJ** : le marchand paie plus que le net HV, ou l'objet se vend à moins de `Bags.SLOW_PER_DAY` 0,5/j et le PNJ paie ≥ la moitié du net HV, ou prix non tenu.
- **Garder** : tendance ≥ `Bags.HOLD_TREND` 3 %/j sans stock lourd, ou se vend peu sans bon rachat PNJ.
- **Attendre** : moins cher < `Bags.UNDERCUT_FLOOR` 85 % du prix. Attention : **sans anti-troll** (une seule unité bradée suffit) ; le module Vente, lui, ignore les bradeurs (`Sell.TROLL_SHARE`).
- **Fabriquer** : transformer rapporte ≥ `CRAFT_UP_MIN_GAIN` 10 % et ≥ `CRAFT_UP_MIN_PER_CRAFT` 20c de plus par fabrication.
La file de vente en jeu (`Sell.Queue`) refait ses propres calculs (plancher, plafond, durée) : pour poster, renvoie le joueur à la file, et ne recalcule pas un prix différent sans raison.

### 3.9 `## Mes enchères en cours`
`Auctions.Summary` : par lot, prix, temps restant, verdict **sous-coté** (moins cher du dernier scan < ton prix ; peut dater d'avant ton post), **trop cher** (> `Auctions.TOO_HIGH` 1,2 × le prix), **ok** ; « ~N j pour tout vendre à 25 % du marché ». « vendu en attente au courrier » = or à récupérer (pas encore dans `Or`). Liste « ancienne » (> 2 j) : à relire en ouvrant l'HV. Repost : seulement si la vue undercuts en jeu le propose (`Sell.REPOST_MIN_GAIN` 1s ; annuler perd le dépôt).

### 3.10 `## Fiabilité des conseils`
`Track.Lines` : par type de conseil, sur `Track.HORIZON` (3 j ; à stocker : selon les rebonds, `stock` = 14 j au plus). **Prix tenu** = revente atteinte à `Track.HELD` 97 % près ; **écoulé** = le marché a acheté la quantité à ≥ `Track.SOLD_AT` 95 % du prix (estimé : une annulation non repérée compte comme vente) ; réussi = les deux. « bénéfice prévu / constaté » ; « suivis par toi » = achats réels dans `Track.FOLLOW_SECS` 24 h.
C'est **la meilleure mesure de confiance par type de conseil**. Seuil de méthode (pas dans le code) : un type est *éprouvé* à ≥ 5 vérifiés et ≥ 60 % réussis, *douteux* sous 40 % ; entre les deux ou moins de 5 vérifiés : *non jugé*.

### 3.11 `## Bilan réel 30 j`
`Ledger.Summary` sur `Ledger.DAYS` = 30 j de courriers : recettes, achats, solde, vendus, expirés ; par objet, prix moyen obtenu et « vs prévu » (prix prévu **au moment de la vente**). Vérité terrain : prime sur tout le reste pour l'objet concerné. Des expirations sans vente = l'objet ne part pas à ce prix chez ce joueur.

### 3.12 `## Achat PNJ → revente HV`
`Analysis.VendorFlip` : marge nette/u, ventes/j **de tout l'HV**, « vise » = 25 % de ce volume (borné au stock du marchand et au budget). « fiable » seulement si prix réel vu, ≥ `VENDOR_MIN_DAYS` 3 j de données, écoulement ≥ 50 %, revente < `VENDOR_MARKUP_WARN` 5 × le prix PNJ — ou si les ventes du joueur le confirment (vendus ≥ 2 × expirés). Sinon « à tester : N u d'abord ». Tout acheteur peut aller au même PNJ : la marge est fragile.

### 3.13 `## Zones de farm`, `## Revente PNJ`, `## Diagnostic`
- Farm : or/h par zone (`Analysis.FarmZones`) aux prix **actuels**, net de commission mais pas des dépôts perdus ; ce qui dépasse ce que le marché absorbe est valorisé au prix PNJ. Peu de sessions = estimation grossière.
- Revente PNJ : nombre d'enchères sous le rachat du marchand au dernier scan, et bénéfice total. Action rapide et sûre si le scan est récent (l'achat reste manuel, dans l'onglet Revente PNJ).
- Diagnostic : `MANQUE` ou erreurs = une fonction de l'addon est peut-être muette ; signale-le si ça touche une section que tu utilises.

---

## 4. Ordre de décision

Classe chaque action possible selon ces quatre critères, **dans cet ordre**. Un critère supérieur l'emporte toujours : une action très rentable mais non fiable passe après une action modeste et prouvée, ou devient un test.

1. **Fiabilité** — le prix est-il prouvé ?
   - *Prouvé* : ventes du joueur au courrier à ce prix (Bilan, « tes reventes »), ou prix réel (≥ 5 ventes vues) sans signal `prix non tenu` / `invendus` / `peu de données` / `pic`, et type de conseil non *douteux* (§ 3.10).
   - *À tester* : « à tester », « stocker ? », « rebond inconnu », « plan partiel », prix plafonné, données jeunes → **1 unité** (5 si ≥ 100 ventes/j) ou quantité de test de l'addon, jamais plus.
   - *Écarté* : `prix non tenu`, « HV écartée », expirations du joueur sans vente, type de conseil *douteux*.
2. **Liquidité** — le marché absorbera-t-il la quantité ?
   - Quantité ≤ 1 jour de ventes (sacs, sous-coter) ou ≤ 2 jours (flips), et ≤ 25 % du volume si le joueur n'est pas seul à vendre.
   - Méfiance si `relistes/j` ≥ vendus/j, `stockJ` > 7, `écoul` < 40 %, `afflux`.
3. **Gain par minute** — or net ÷ temps de jeu.
   - Le rapport ne donne pas de temps (sauf le farm en or/h). Estime-le et dis-le : ~1 min par achat ou mise en vente, + trajet (PNJ, banque, boîte aux lettres), + temps de fabrication. Préfère les actions groupées au même endroit (HV + boîte aux lettres).
   - Compare au farm (`Zones de farm`) : une action HV qui rapporte moins à l'heure que son meilleur farm n'est utile que si elle se fait pendant une pause.
4. **Tendance** — départage seulement.
   - Hausse (≥ 3 %/j) : garder / farmer ; baisse (≤ −3 %/j) : vendre vite, ne pas stocker, ne pas fabriquer pour plus tard.
   - `pénurie` : farmer maintenant ; `demande+` : idem, plus faible.

Ensuite seulement : **budget**. Additionne les achats retenus dans cet ordre et arrête-toi avant de dépasser l'or (règle absolue n° 2).

---

## 5. Seuils (repris du code)

| Constante | Valeur | Rôle |
|---|---|---|
| `Analysis.MIN_SOLD_FOR_REAL` | 5 u / 7 j | prix réel de vente plutôt que prix affiché |
| `Analysis.TREND_DAYS` | 7 | fenêtre de tendance (≥ 3 jours sur ≥ 2 j d'écart) |
| signaux `hausse` / `baisse` | ≥ +3 % / ≤ −3 % par jour | `s.trend` |
| `pénurie` | stock −30 % (3 j vs 7 j d'avant), demande > −20 % | ×1,2 |
| `demande+` / `afflux` | ventes +30 % / stock +50 % | ×1,1 / ×0,8 |
| `Analysis.HEAVY_STOCK_DAYS` (`stock lourd`) | > 7 j de ventes en rayon | ×0,75 |
| `dominé` | un vendeur ≥ 60 % du stock | jamais sur Forever |
| `invendus` | écoulement < 40 % | |
| `peu de données` | < 6 h de marché observées sur 7 j | |
| `Analysis.SPIKE_RATIO` / `SPIKE_MIN_DAYS` / `SPIKE_SETTLE_DAYS` | 1,5 × médiane des 13 j précédents / ≥ 3 jours connus / 5 j | `pic` |
| `Analysis.AH_CUT` | 5 % (mesuré dès 5 ventes) | commission |
| `Analysis.DEPOSIT_RATE` | 15 % du prix PNJ (mesuré dès 5 ventes, ~43 % sur Forever) | dépôt |
| `Analysis.BUDGET_SHARE` | 50 % de l'or | plafond d'un conseil d'achat |
| `Analysis.VENDOR_SHARE` | 25 % | part du marché du joueur |
| `Analysis.FLIP_HOLD_DAYS` / `FLIP_MIN_ROI` / `FLIP_MIN_PROFIT` | 2 j / 15 % / 20s | flip tout de suite |
| `Analysis.FLIP_STORE_MIN_ROI` / `FLIP_STORE_GAP` | 25 % / 10 % | flip à stocker |
| `Analysis.FLIP_TEST_DAYS` / `FLIP_TEST_MAX_QTY` / `FLIP_TEST_MAX_COST` | ½ j / 20 u / 20g | stocker à tester |
| `Rebound.DIP` / `RECOVER` / `MAX_WAIT` | 15 % / 5 % / 14 j | creux, rebond, raté |
| `Rebound.MIN_EVENTS` / `SETTLE_DAYS` | 3 creux / 5 j | rebond connu / nouveau prix |
| `Rebound.WEEK_MIN_DAYS` / `WEEK_MIN_GAIN` | 21 j / +5 % | meilleur jour de la semaine |
| `Analysis.CRAFT_MIN_SURE_PER_DAY` / `CRAFT_MAX_BACKLOG_DAYS` / `RECENT_OBS` | 0,5 / 3 j / 6 h | l'objet fabriqué partira-t-il ? |
| `Analysis.CRAFT_UP_MIN_GAIN` / `CRAFT_UP_MIN_PER_CRAFT` | 10 % / 20c | « Fabrique-le plutôt » |
| `Analysis.CRAFT_VENDOR_PER_DAY` | 20 | fabrications/j comptées au PNJ |
| `Analysis.VENDOR_MIN_DAYS` / `VENDOR_MARKUP_WARN` | 3 j / 5 × | achat PNJ fiable |
| `Opp.RECIPE_MIN_PROFIT` / `RECIPE_MIN_ROI` | 1s / 15 % | recettes rentables |
| `Opp.UNDERCUT_MIN_PREMIUM` / `UNDERCUT_MIN_GAIN` / `UNDERCUT_POST_DAYS` | 10 % / 2s / 1 j | sous-coter |
| `Bags.HOLD_TREND` / `UNDERCUT_FLOOR` / `SLOW_PER_DAY` / `MIN_VALUE` / `SAME_BAND` | 3 %/j / 85 % / 0,5/j / 1s / ±10 % | conseil des sacs, HV ou PNJ |
| `Trust.OK_SALES` / `ABOVE_MAX` / `LINGER_SECS` / `KEEP_DAYS` | 3 ventes / +10 % / 12 h / 14 j | fiable / prix non tenu |
| `Analysis.SELLS_FAST` / `SELLS_SLOW` / `SELLS_MIN_OBS` / `SELLS_OWN_MIN` | 1/j / 0,3/j / 24 h / 3 | « Se vend ? » (en jeu, pas dans le rapport) |
| `Auctions.TOO_HIGH` | 1,2 × le prix | enchère trop chère |
| `Sell.TROLL_SHARE` / `REPOST_MIN_GAIN` | 10 % du stock / 1s | anti-troll, repost |
| `Sell.DEFAULT_RULES` | undercut 1c, plancher max(PNJ +10 %, achat +10 %, 70 % du prix), plafond ×1,2 (×1,4 en pénurie) | module Vente |
| `Ledger.MIN_CALIB` / `DAYS` / `BIAS_MIN`–`BIAS_MAX` | 5 ventes / 30 j / 0,4–1 | calibration, bilan, correction |
| `Track.HORIZON` / `HELD` / `SOLD_AT` / `FOLLOW_SECS` | 3 j (stock ≤ 14) / 97 % / 95 % / 24 h | fiabilité des conseils |

---

## 6. Pièges

- **Peu de données.** Moins de 6 h observées (`peu de données`), moins de 3 jours (pas de tendance), confiance v/(v+3) : 1 vente vue = 25 %. Un « 5 vendus/j » tiré d'une seule vente n'est rien. Les premiers jours, la tendance vient d'Auctionator (minimums) : instable.
- **Pics.** `pic` = prix du jour > 1,5 × l'habituel. Vendre ce qu'on a **au prix du jour** est bien ; fabriquer, acheter au PNJ ou stocker pour ce prix, non. Les « ventes » d'un pic sont souvent des relistes (Pilferer's Gloves : 1g66 affiché contre ~50s d'habitude).
- **Trolls et bradeurs.** Une enchère d'1 unité à prix cassé fausse `achat min`, déclenche « Attendre » dans les sacs et « sous-coté » dans tes enchères. Le module Vente l'ignore sous 10 % du stock ; toi aussi. À l'inverse, une poignée d'enchères très chères fait un prix affiché que personne ne paie : d'où le plafond au plus haut prix vu vendu.
- **Biais de scan.** Les ventes sont **déduites** des enchères disparues entre deux scans : une annulation non repérée compte comme vente, des scans espacés rendent les cas ambigus (comptés pour moitié). Relistes repérés seulement pour les objets en piles. Plus il y a de scans rapprochés (15–60 min), meilleur est le volume. Le carnet date du dernier scan : il ne voit pas les enchères postées depuis. Forever ne donne pas les vendeurs : « dominé » ne se déclenche jamais, et l'enchère la moins chère peut être celle du joueur.
- **Commission non calibrée.** « supposée » dans l'en-tête : dépôt compté à 15 % du prix PNJ alors que Forever en prend ~43 % (selon la durée). Les nets sont trop hauts pour les objets à fort prix PNJ qui expirent souvent : exige une marge plus large (au moins 2 dépôts) avant de conseiller l'HV. Le script `tools/ahledger.py report` garde toujours 5 % fixes et ignore les dépôts.
- **Correction par les ventes réelles** déjà incluse dans les nets : ne retranche pas encore l'écart moyen.
- **Budget par conseil, pas global** : voir règle absolue n° 2.
- **Stocker immobilise** l'or jusqu'au délai « lent » ; le bénéfice affiché est une espérance, pas une promesse.
- **Rapport tronqué** : un objet absent n'est pas forcément mauvais.
- **Deux sources pour la même chose** : la file de vente en jeu recalcule prix et durée au moment du clic, avec le dernier scan ; s'il diffère du rapport, c'est la file qui a raison (plus récente).

---

## 7. Gabarit de réponse (séance de conseil)

Court : 15 à 25 lignes. Pas de recopie du rapport. Chaque action est **chiffrée** (quantité, prix/u, où, gain attendu) et porte sa fiabilité.

Les objets et chiffres ci-dessous sont des exemples de forme, pas des données.

```
**Données** : N j, H h observées, dernier scan il y a X, commission mesurée|supposée → données jeunes|correctes|mûres.
(alerte éventuelle : rapport ancien, or inconnu, méthode vN ≠ v1, diagnostic)

**À faire maintenant** (dans l'ordre, 3 à 5 actions)
1. Vendre 20 Medium Leather à 1s 15c/u à l'HV (file de vente) — ~22s net, prouvé (prix réel, 40 vendus/j).
2. Acheter 12 Silk Cloth jusqu'à 18c/u (coût 2s 10c), revendre 30c/u tout de suite — ~1s 20c, prouvé (flips « tout de suite » 70 % réussis).
3. PNJ : Turtle Scale ×14 — l'HV ne tient pas le prix (3 expirés chez toi).

**À tester** (petites quantités, pour apprendre)
- 1 Pilferer's Gloves à 55s : prix non prouvé.

**À éviter**
- Fabriquer des Pilferer's Gloves : HV écartée (33 en rayon).

**Or** : achats conseillés X sur Y disponibles (budget par opération Z).
**Prochaine fois** : rescanner dans ~1 h ; ouvrir la boîte aux lettres (calibrer la commission) ; vérifier …
```

Interdits dans la réponse : toute forme d'automatisation (macro, bot, « tout poster », scan sans clic) ; un total d'achats supérieur à l'or disponible ; un chiffre absent du rapport présenté comme mesuré ; un achat de plus de 2 jours de ventes ; une quantité « à tester » au-delà de 1 unité (5 sur un marché très actif) ou de la quantité de test de l'addon.

---

## 8. Entretien de ce document

- Une constante change dans le code : mets à jour le § 5 (et le README).
- Le rapport change de forme ou de sens, ou ce document change de règle : incrémente `Export.METHODE` dans `Export.lua` **et** la version en titre ici.
