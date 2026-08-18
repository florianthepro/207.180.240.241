@echo off
setlocal
REM ============================================================
REM  setup_gitlab.bat  -  Teil 2: GitLab CE Deployment in Docker
REM  GitLab bindet NUR 127.0.0.1:9200 -> kein Konflikt mit dem
REM  extern erreichbaren Apache, 80/443 bleiben unberuehrt.
REM  Voraussetzungen: setup_docker-wsl.bat abgeschlossen,
REM  compose.yaml liegt im selben Ordner wie dieses Skript.
REM  Als Administrator ausfuehren - Firewall-Regel.
REM ============================================================

set "GL_DIR=C:\docker\gitlab_9200"
set "GL_COMPOSE=%GL_DIR%\compose.yaml"

REM ---- Admin-Check ----
net session >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] Bitte als Administrator ausfuehren.
    exit /b 1
)

REM ---- Voraussetzungen pruefen ----
where docker >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] Docker nicht gefunden. Zuerst setup_docker-wsl.bat ausfuehren.
    exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] Docker-Engine laeuft nicht. Docker Desktop starten, warten, erneut ausfuehren.
    exit /b 1
)

REM ---- Phase 1: Projektordner + compose.yaml ----
echo [1/3] Lege %GL_DIR% an ...
if not exist "%GL_DIR%" mkdir "%GL_DIR%"
if not exist "%~dp0compose.yaml" (
    echo [FEHLER] compose.yaml nicht neben setup_gitlab.bat gefunden.
    exit /b 1
)
copy /Y "%~dp0compose.yaml" "%GL_COMPOSE%" >nul

REM ---- Phase 2: Firewall-Haertung, Defense in Depth ----
echo [2/3] Blockiere eingehend TCP 9200 von aussen ...
netsh advfirewall firewall show rule name="GitLab_9200_Block_Inbound" >nul 2>&1
if errorlevel 1 (
    netsh advfirewall firewall add rule name="GitLab_9200_Block_Inbound" dir=in action=block protocol=TCP localport=9200 >nul
)

REM ---- Phase 3: GitLab starten ----
echo [3/3] Starte GitLab CE ...
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
