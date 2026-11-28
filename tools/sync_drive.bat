@echo off
REM AHLedger : copie le rapport pour Claude dans Google Drive à chaque /reload ou déconnexion.
REM Laisse cette fenêtre ouverte pendant que tu joues (ou mets un raccourci dans le dossier Démarrage).
REM Si le fichier de l'addon ou le dossier Drive ne sont pas trouvés tout seuls, ajoute par exemple :
REM   --sv "C:\Program Files (x86)\World of Warcraft\_forever_\WTF\Account\MONCOMPTE\SavedVariables\AHLedger.lua"
REM   --to "G:\Mon Drive\AHLedger"
title AHLedger - synchro Google Drive
python "%~dp0ahledger.py" sync %*
pause
