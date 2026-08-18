@echo off
setlocal EnableExtensions
REM ============================================================
REM  sync-github-pages-to-gitea.bat
REM  Laedt github.com/florianthepro/pages (Branch main) als ZIP,
REM  entpackt es und pusht den INHALT (ohne den Wrapper-Ordner
REM  "pages-main") als frischen Commit nach Gitea -> florianthepro/p2.
REM  Einweg-Spiegel GitHub -> Gitea: der Gitea-Branch wird bei jedem
REM  Lauf ersetzt (force push), Dateien landen exakt in der Repo-Root.
REM
REM  Voraussetzung: Repo florianthepro/p2 existiert in Gitea.
REM  GITEA_TOKEN leer lassen = Git fragt beim Push nach Login
REM  (Gitea-Benutzer + Passwort/Token, wird vom Credential Manager
REM  gespeichert). Token erstellen: Gitea -> Einstellungen ->
REM  Anwendungen -> Zugriffstoken (Scope: repository write).
REM ============================================================

REM ===== Konfiguration =====
set "ZIP_URL=https://github.com/florianthepro/pages/archive/refs/heads/main.zip"
set "GITEA_SCHEME=http"
set "GITEA_HOSTPATH=127.0.0.1:3000/florianthepro/p2.git"
set "GITEA_USER=florianthepro"
set "GITEA_TOKEN="
set "BRANCH=main"
set "COMMIT_NAME=github-sync"
set "COMMIT_MAIL=sync@gitea.getitsec.com"
REM =========================

where git  >nul 2>&1 || (echo [FEHLER] git nicht gefunden.  & exit /b 1)
where curl >nul 2>&1 || (echo [FEHLER] curl nicht gefunden. & exit /b 1)
where tar  >nul 2>&1 || (echo [FEHLER] tar nicht gefunden.  & exit /b 1)

set "WORK=%TEMP%\gh2gitea-%RANDOM%%RANDOM%"
mkdir "%WORK%"   || exit /b 1
mkdir "%WORK%\x" || goto :fail

echo [i] Lade %ZIP_URL% ...
curl.exe -fSL --retry 3 -o "%WORK%\src.zip" "%ZIP_URL%" || goto :fail

echo [i] Entpacke ...
tar -xf "%WORK%\src.zip" -C "%WORK%\x" || goto :fail

set "SRC="
for /d %%D in ("%WORK%\x\*") do set "SRC=%%~fD"
if not defined SRC (echo [FEHLER] Kein Ordner im ZIP gefunden. & goto :fail)
echo [i] Quellordner: %SRC%

pushd "%SRC%" || goto :fail
git init -q || goto :failpop
git add -A -f . || goto :failpop
git -c user.name="%COMMIT_NAME%" -c user.email="%COMMIT_MAIL%" commit -q -m "Sync von GitHub pages@main (%DATE% %TIME%)" || goto :failpop

set "PUSH_URL=%GITEA_SCHEME%://%GITEA_HOSTPATH%"
if defined GITEA_TOKEN set "PUSH_URL=%GITEA_SCHEME%://%GITEA_USER%:%GITEA_TOKEN%@%GITEA_HOSTPATH%"

echo [i] Pushe nach %GITEA_SCHEME%://%GITEA_HOSTPATH% (Branch %BRANCH%, force) ...
git push --force "%PUSH_URL%" HEAD:refs/heads/%BRANCH% || goto :failpop
popd

rmdir /s /q "%WORK%" >nul 2>&1
echo [OK] Fertig: https://gitea.getitsec.com/florianthepro/p2
exit /b 0

:failpop
popd
:fail
echo [FEHLER] Abbruch. Arbeitsordner bleibt zur Analyse liegen: %WORK%
exit /b 1
