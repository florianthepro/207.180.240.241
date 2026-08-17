@echo off
setlocal
REM ============================================================
REM  setup.bat  -  WSL2 + Docker Desktop + GitLab CE in Docker
REM  GitLab bindet NUR 127.0.0.1:9200 -> kein Konflikt mit dem
REM  extern erreichbaren Apache (80/443 bleiben unberuehrt).
REM  Als Administrator ausfuehren. Nach jedem Neustart-Hinweis
REM  das Skript einfach erneut starten (Phasen sind idempotent).
REM  Voraussetzung: compose.yaml liegt im selben Ordner.
REM ============================================================

set "GL_DIR=C:\docker\gitlab_9200"
set "GL_COMPOSE=%GL_DIR%\compose.yaml"

REM ---- Admin-Check ----
net session >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] Bitte als Administrator ausfuehren.
    exit /b 1
)

REM ---- Phase 1: WSL2-Plattform ----
wsl --status >nul 2>&1
if errorlevel 1 (
    echo [1/5] Installiere WSL2-Plattform ohne Distribution ...
    wsl --install --no-distribution
    echo [INFO] Neustart erforderlich. Danach setup.bat erneut ausfuehren.
    pause
    exit /b 0
)
echo [1/5] WSL vorhanden - aktualisiere Kernel ...
wsl --update
wsl --set-default-version 2 >nul

REM ---- Phase 2: Docker Desktop ----
where docker >nul 2>&1
if errorlevel 1 (
    echo [2/5] Installiere Docker Desktop via winget ...
    winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
    echo [INFO] Ab- und wieder anmelden, Docker Desktop einmal manuell starten,
    echo        Engine-Start abwarten. Danach setup.bat erneut ausfuehren.
    pause
    exit /b 0
)
echo [2/5] Docker CLI gefunden.

docker info >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] Docker-Engine laeuft nicht. Docker Desktop starten, warten, erneut ausfuehren.
    exit /b 1
)

REM ---- Phase 3: Projektordner + compose.yaml ----
echo [3/5] Lege %GL_DIR% an ...
if not exist "%GL_DIR%" mkdir "%GL_DIR%"
if not exist "%~dp0compose.yaml" (
    echo [FEHLER] compose.yaml nicht neben setup.bat gefunden.
    exit /b 1
)
copy /Y "%~dp0compose.yaml" "%GL_COMPOSE%" >nul

REM ---- Phase 4: Firewall-Haertung, Defense in Depth ----
echo [4/5] Blockiere eingehend TCP 9200 von aussen ...
netsh advfirewall firewall show rule name="GitLab_9200_Block_Inbound" >nul 2>&1
if errorlevel 1 (
    netsh advfirewall firewall add rule name="GitLab_9200_Block_Inbound" dir=in action=block protocol=TCP localport=9200 >nul
)

REM ---- Phase 5: GitLab starten ----
echo [5/5] Starte GitLab CE ...
docker compose -f "%GL_COMPOSE%" up -d
if errorlevel 1 (
    echo [FEHLER] docker compose up fehlgeschlagen.
    exit /b 1
)
docker compose -f "%GL_COMPOSE%" ps

echo.
echo [OK] GitLab initialisiert sich - dauert einige Minuten.
echo      URL:           http://localhost:9200
echo      root-Passwort: docker exec -it gitlab_9200 grep Password: /etc/gitlab/initial_root_password
echo      Hinweis:       Passwort-Datei wird 24 h nach Erststart geloescht - sofort aendern.
endlocal
exit /b 0
