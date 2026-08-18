@echo off
setlocal
REM ============================================================
REM  gitea-setup.bat  -  Starter fuer gitea-setup.ps1
REM  Fordert automatisch Administrator-Rechte an (UAC) und
REM  fuehrt das PowerShell-Setup mit ExecutionPolicy Bypass aus.
REM ============================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [i] Starte neu mit Administrator-Rechten - bitte UAC bestaetigen ...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo [i] Administrator-Rechte OK. Starte Gitea-Setup ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gitea-setup.ps1" %*
echo.
pause
endlocal
