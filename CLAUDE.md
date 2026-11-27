# AHLedger : règles pour Claude Code

Lis `HANDOVER.md` en début de session : architecture, conventions, hypothèses à vérifier en jeu.

## Supervision obligatoire
- Après toute modification d'un `.lua`, du `.toc`, de `.luacheckrc` ou des tests, et **avant d'annoncer que c'est fini**, lance le sous-agent `supervisor`. Donne-lui la liste des fichiers modifiés et le but du changement.
- Si le verdict est « À corriger », corrige les points bloquants puis relance `supervisor`, jusqu'à obtenir « OK ». Ne présente jamais un travail comme terminé avec un verdict « À corriger ». Si un point ne peut pas être corrigé, dis-le clairement au joueur.
- Transmets au joueur la section « À vérifier en jeu » du rapport.

## Avant un gros changement
Fais une copie du dossier dans `_forever_` : `AHLedger_backup_<AAAA-MM-JJ>_<sujet>`, sans les dossiers `.tmp.*`. C'est le seul moyen de revenir en arrière, puisque le dossier local n'est pas un dépôt git.

## Rappels
- Règles Blizzard : pas d'achat, de vente ou d'enchère automatisés, pas de scan sans clic du joueur, pas de publicité.
- Ne lis pas le code d'Auctionator : son AGENTS.md l'interdit. Vérifie `Bridge.lua` en jeu avec `/ahl diag`.
- Code, commentaires et interface en français.
