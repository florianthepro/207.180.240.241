@echo off
setlocal enableextensions
chcp 65001 >nul 2>&1
REM ============================================================
REM  log.bat  -  Sammelt alle Logs/Statusinfos, um zu klaeren,
REM  warum die Docker-Engine (Docker Desktop / WSL2) nicht startet.
REM  Schreibt EINEN Report nach docker-diag.txt (neben dieser .bat)
REM  und zeigt ihn im Terminal an.
REM  Am besten ALS ADMINISTRATOR ausfuehren.
REM ============================================================

REM WSL soll UTF-8 statt UTF-16 ausgeben (sonst Muell im Report)
set "WSL_UTF8=1"
set "OUT=%~dp0docker-diag.txt"
set "LOGDIR=%LOCALAPPDATA%\Docker\log"
set "DIAG=C:\Program Files\Docker\Docker\resources\com.docker.diagnose.exe"

echo Sammle Diagnosedaten ... (kann 1-2 Minuten dauern)
echo.

> "%OUT%" echo ============================================================
>>"%OUT%" echo  Docker Desktop / WSL2 - Diagnose-Report
>>"%OUT%" echo  Erstellt : %DATE% %TIME%
>>"%OUT%" echo  Host     : %COMPUTERNAME%    User: %USERNAME%
>>"%OUT%" echo ============================================================

REM ---- Admin-Check ----
net session >nul 2>&1
if errorlevel 1 (
    >>"%OUT%" echo [WARN] NICHT als Administrator gestartet - einige Werte koennen fehlen.
    echo [WARN] Tipp: Fuer vollstaendige Ausgabe als Administrator ausfuehren.
) else (
    >>"%OUT%" echo [OK] Administrator-Rechte vorhanden.
)

call :SEC "SYSTEMINFO (OS + Hyper-V-Anforderungen / Virtualisierung)"
systeminfo >>"%OUT%" 2>&1

call :SEC "VIRTUALISIERUNG sichtbar? (CIM)"
powershell -NoProfile -Command "$cs=Get-CimInstance Win32_ComputerSystem; $cpu=@(Get-CimInstance Win32_Processor)[0]; [pscustomobject]@{HypervisorPresent=$cs.HypervisorPresent;Manufacturer=$cs.Manufacturer;Model=$cs.Model;VirtualizationFirmwareEnabled=$cpu.VirtualizationFirmwareEnabled;SLAT=$cpu.SecondLevelAddressTranslationExtensions;VMMonitorModeExtensions=$cpu.VMMonitorModeExtensions} | Format-List | Out-String" >>"%OUT%" 2>&1

call :SEC "BCD - hypervisorlaunchtype"
bcdedit /enum {current} >>"%OUT%" 2>&1

call :SEC "WINDOWS-FEATURES (WSL / VM-Platform / Hyper-V)"
powershell -NoProfile -Command "Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux,VirtualMachinePlatform,Microsoft-Hyper-V-All,HypervisorPlatform,Containers | Select-Object FeatureName,State | Format-Table -AutoSize | Out-String -Width 200" >>"%OUT%" 2>&1

call :SEC "WSL --version"
wsl --version >>"%OUT%" 2>&1
call :SEC "WSL --status"
wsl --status >>"%OUT%" 2>&1
call :SEC "WSL -l -v  (installierte Distributionen)"
wsl -l -v >>"%OUT%" 2>&1

call :SEC "DIENSTE"
sc query com.docker.service >>"%OUT%" 2>&1
sc query LxssManager >>"%OUT%" 2>&1
sc query vmcompute >>"%OUT%" 2>&1
sc query hns >>"%OUT%" 2>&1

call :SEC "DOCKER CLI / KONTEXT / STATUS"
where docker >>"%OUT%" 2>&1
docker version >>"%OUT%" 2>&1
docker context ls >>"%OUT%" 2>&1
docker desktop status >>"%OUT%" 2>&1

call :SEC "DOCKER INFO  (Engine-Erreichbarkeit - Fehler erwartet, wenn Engine steht)"
docker info >>"%OUT%" 2>&1

call :SEC "DOCKER DESKTOP SETTINGS (welches Backend ist konfiguriert)"
if exist "%APPDATA%\Docker\settings-store.json" (
    type "%APPDATA%\Docker\settings-store.json" >>"%OUT%" 2>&1
) else if exist "%APPDATA%\Docker\settings.json" (
    type "%APPDATA%\Docker\settings.json" >>"%OUT%" 2>&1
) else (
    >>"%OUT%" echo   keine settings-store.json / settings.json gefunden
)

call :SEC ".wslconfig (falls vorhanden)"
if exist "%USERPROFILE%\.wslconfig" (
    type "%USERPROFILE%\.wslconfig" >>"%OUT%" 2>&1
) else (
    >>"%OUT%" echo   keine .wslconfig vorhanden
)

call :SEC "DIAGNOSE  (com.docker.diagnose check)"
if exist "%DIAG%" (
    "%DIAG%" check >>"%OUT%" 2>&1
) else (
    >>"%OUT%" echo   com.docker.diagnose.exe nicht gefunden unter %DIAG%
)

call :SEC "LOG-VERZEICHNIS (Dateien mit Zeitstempeln)"
powershell -NoProfile -Command "$p=Join-Path $env:LOCALAPPDATA 'Docker\log'; if(Test-Path -LiteralPath $p){ Get-ChildItem -LiteralPath $p -Recurse -File | Sort-Object LastWriteTime | Select-Object LastWriteTime,Length,FullName | Format-Table -AutoSize | Out-String -Width 300 } else { 'Log-Ordner nicht gefunden' }" >>"%OUT%" 2>&1

call :SEC "LOG-INHALTE (jeweils letzte Zeilen)"
powershell -NoProfile -Command "$base=Join-Path $env:LOCALAPPDATA 'Docker\log'; $files=@('vm\init.log','host\com.docker.backend.exe.log','host\Docker Desktop.exe.stderr.log','host\Docker Desktop.exe.log','host\com.docker.build.log'); foreach($f in $files){ $p=Join-Path $base $f; Write-Output ''; Write-Output ('----- '+$f+'  (letzte 150 Zeilen) -----'); if(Test-Path -LiteralPath $p){ try{ Get-Content -LiteralPath $p -Tail 150 }catch{ Write-Output ('Fehler beim Lesen: '+$_.Exception.Message) } } else { Write-Output '(nicht vorhanden)' } }" >>"%OUT%" 2>&1

call :SEC "NEUESTES ROTIERTES BACKEND-LOG"
powershell -NoProfile -Command "$d=Join-Path $env:LOCALAPPDATA 'Docker\log\host'; if(Test-Path -LiteralPath $d){ $n=Get-ChildItem -LiteralPath $d -Filter 'com.docker.backend.exe.log*' -File | Sort-Object LastWriteTime | Select-Object -Last 1; if($n){ Write-Output ('----- '+$n.Name+'  (letzte 200 Zeilen) -----'); Get-Content -LiteralPath $n.FullName -Tail 200 } else { Write-Output '(kein backend-log gefunden)' } }" >>"%OUT%" 2>&1

>>"%OUT%" echo.
>>"%OUT%" echo ============================================================
>>"%OUT%" echo  ENDE DES REPORTS
>>"%OUT%" echo ============================================================

REM ---- Ausgabe im Terminal ----
type "%OUT%"
echo.
echo ============================================================
echo  Report gespeichert unter:
echo    %OUT%
echo  Diese Datei senden ODER den Terminal-Text kopieren.
echo ============================================================
echo.
pause
endlocal
goto :eof

:SEC
echo   .. %~1
>>"%OUT%" echo.
>>"%OUT%" echo ============================================================
>>"%OUT%" echo == %~1
>>"%OUT%" echo ============================================================
goto :eof
