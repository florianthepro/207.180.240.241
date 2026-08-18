@echo off
setlocal
REM ============================================================
REM  setup_docker-wsl.bat  -  Teil 1: WSL2-Plattform + Docker Desktop
REM  Als Administrator ausfuehren. Nach jedem Neustart-Hinweis
REM  das Skript erneut starten - Phasen sind idempotent.
REM  Danach: setup_gitlab.bat ausfuehren.
REM ============================================================

REM ---- Admin-Check ----
net session >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] Bitte als Administrator ausfuehren.
    exit /b 1
)

REM ---- Phase 1: WSL2-Plattform ----
wsl --status >nul 2>&1
if errorlevel 1 (
    echo [1/2] Installiere WSL2-Plattform ohne Distribution ...
    wsl --install --no-distribution
    echo [INFO] Neustart erforderlich. Danach setup_docker-wsl.bat erneut ausfuehren.
    pause
    exit /b 0
)
echo [1/2] WSL vorhanden - aktualisiere Kernel ...
wsl --update
wsl --set-default-version 2 >nul

REM ---- Phase 2: Docker Desktop ----
where docker >nul 2>&1
if errorlevel 1 (
    echo [2/2] Installiere Docker Desktop via winget ...
    winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
    echo [INFO] Ab- und wieder anmelden, Docker Desktop einmal manuell starten,
    echo        Engine-Start abwarten. Danach setup_gitlab.bat ausfuehren.
    pause
    exit /b 0
)
echo [2/2] Docker CLI gefunden.

docker info >nul 2>&1
if errorlevel 1 (
    echo [INFO] Docker-Engine laeuft noch nicht. Docker Desktop starten und warten.
    echo        Danach direkt setup_gitlab.bat ausfuehren.
    exit /b 0
)

echo [OK] WSL2 und Docker sind einsatzbereit. Weiter mit setup_gitlab.bat.
endlocal
exit /b 0
