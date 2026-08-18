@echo off
setlocal EnableExtensions
REM ============================================================
REM  gitea-setup-v2.bat  -  CLEAN + INSTALL, alles in einer Datei
REM
REM  v2-Aenderungen gegenueber v1:
REM   * PHASE 1 raeumt eine alte/kaputte Installation KOMPLETT auf
REM     (Dienst, Prozesse, defekte ACLs reparieren, C:\gitea loeschen)
REM   * Der ACL-Haertungs-Schritt (Ursache des v1-Fehlers
REM     "Access is denied" bei gitea migrate) laeuft jetzt GANZ AM
REM     ENDE, ohne /T-Vererbungs-Reset, mit Selbsttest und
REM     automatischem Rollback, falls etwas nicht mehr startet.
REM   * Jeder kritische Schritt prueft den Exit-Code und zeigt
REM     Fehler AN statt sie zu verschlucken.
REM   * Download wird per SHA256 verifiziert und entsperrt
REM     (Unblock-File / Mark-of-the-Web).
REM
REM  Ergebnis: Gitea als Windows-Dienst, NUR 127.0.0.1:9200,
REM  LocalService-Konto, Autostart + Auto-Restart, gehaertete Config.
REM
REM  Bedienung: Doppelklick (fragt UAC ab) oder als Admin starten.
REM  Protokoll: gitea-setup-v2.log neben dieser Datei.
REM ============================================================

REM ===== Konfiguration (bei Bedarf anpassen) =====
set "GITEA_DIR=C:\gitea"
set "GITEA_PORT=9200"
set "GITEA_DOMAIN="
set "GITEA_ADMIN=gitadmin"
set "GITEA_EMAIL=admin@localhost"
set "GITEA_VERSION="
REM  GITEA_WIPE=1  -> alte Installation vollstaendig loeschen (fragt nach,
REM                   wenn eine Datenbank mit Daten gefunden wird)
REM  GITEA_WIPE=0  -> vorhandene Daten/Config behalten (Upgrade-Modus)
set "GITEA_WIPE=1"
set "GITEA_LOGFILE=%~dp0gitea-setup-v2.log"
REM ================================================

REM ---- Admin-Rechte sicherstellen (UAC) ----
net session >nul 2>&1
if errorlevel 1 (
    echo [i] Fordere Administrator-Rechte an - bitte UAC bestaetigen ...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo [i] Administrator-Rechte OK. Starte Gitea-Setup v2 ...

REM ---- eingebetteten PowerShell-Teil in Temp-Datei entpacken ----
set "PS1=%TEMP%\gitea-setup-v2-%RANDOM%%RANDOM%.ps1"
set "start="
for /f "delims=:" %%a in ('findstr /n /b /c:"#@@@GITEA_PS_PAYLOAD@@@" "%~f0"') do set "start=%%a"
if not defined start (
    echo [FEHLER] PowerShell-Marker in der Datei nicht gefunden.
    pause & exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%~f0' | Select-Object -Skip %start% | Set-Content -LiteralPath '%PS1%' -Encoding UTF8"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "rc=%errorlevel%"
del "%PS1%" >nul 2>&1
echo.
if "%rc%"=="0" (echo [i] Setup erfolgreich abgeschlossen.) else (echo [FEHLER] Setup mit Fehler beendet ^(Exit-Code %rc%^). Details: "%GITEA_LOGFILE%")
pause
exit /b %rc%

#@@@GITEA_PS_PAYLOAD@@@
<#  Eingebetteter PowerShell-Teil (v2) - wird von der .bat oben ausgefuehrt.  #>

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'

# ---- Konfiguration aus Umgebungsvariablen (von der .bat gesetzt) ----
$Dir        = if ($env:GITEA_DIR)     { $env:GITEA_DIR }        else { 'C:\gitea' }
$Port       = if ($env:GITEA_PORT)    { [int]$env:GITEA_PORT }  else { 9200 }
$Version    = if ($env:GITEA_VERSION) { $env:GITEA_VERSION }    else { '' }
$Domain     = if ($env:GITEA_DOMAIN)  { $env:GITEA_DOMAIN }     else { '' }
$AdminUser  = if ($env:GITEA_ADMIN)   { $env:GITEA_ADMIN }      else { 'gitadmin' }
$AdminEmail = if ($env:GITEA_EMAIL)   { $env:GITEA_EMAIL }      else { 'admin@localhost' }
$Wipe       = ($env:GITEA_WIPE -ne '0')
$LogFile    = if ($env:GITEA_LOGFILE) { $env:GITEA_LOGFILE }    else { Join-Path $env:TEMP 'gitea-setup-v2.log' }

function Info($m){ Write-Host "[i] $m"  -ForegroundColor Cyan }
function Ok  ($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m"  -ForegroundColor Yellow }
function Phase($m){ Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Magenta }

# HTTP-Erreichbarkeit pruefen (jede HTTP-Antwort zaehlt, auch Redirect/4xx)
function Test-GiteaHttp([int]$p, [int]$tries = 30) {
    for ($i = 0; $i -lt $tries; $i++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$p/" -TimeoutSec 3
            if ($r.StatusCode -ge 200) { return $true }
        } catch {
            if ($_.Exception.Response) { return $true }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Natives Programm sauber ausfuehren: Exit-Code + gesamte Ausgabe zurueckgeben.
# WICHTIG: bewusst via Start-Process + Temp-Dateien statt "& exe 2>&1", weil
# PowerShell 5.1 bei ErrorActionPreference=Stop eine Exception wirft, sobald
# ein natives Programm bei umgeleitetem stderr dorthin schreibt (gitea loggt
# auf stderr!). Wirft nur dann, wenn der PROZESSSTART selbst scheitert.
function Invoke-Exe([string]$File, [string[]]$ArgList) {
    $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $File -ArgumentList $ArgList -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $so -RedirectStandardError $se
        $out = ((Get-Content $so -Raw -ErrorAction SilentlyContinue), (Get-Content $se -Raw -ErrorAction SilentlyContinue) -join "`r`n").Trim()
        return [pscustomobject]@{ Code = $p.ExitCode; Out = $out }
    } finally {
        Remove-Item $so,$se -Force -ErrorAction SilentlyContinue
    }
}

$exitCode = 0
$null = Start-Transcript -Path $LogFile -Append -Force -ErrorAction SilentlyContinue
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) { throw "Bitte als Administrator ausfuehren." }
    if ($Dir -match '\s') { throw "GITEA_DIR darf keine Leerzeichen enthalten (aktuell: '$Dir'). Bitte z.B. C:\gitea." }

    $conf = Join-Path $Dir 'custom\conf'
    $cfg  = Join-Path $conf 'app.ini'
    $exe  = Join-Path $Dir 'gitea.exe'
    $db   = Join-Path $Dir 'data\gitea.db'
    $fdir = ($Dir -replace '\\','/').TrimEnd('/')

    Info "Zielordner : $Dir"
    Info "Bindung    : 127.0.0.1:$Port  (nur lokal)"
    Info "Modus      : $(if ($Wipe) { 'CLEAN (alte Installation wird entfernt)' } else { 'UPGRADE (Daten bleiben)' })"
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # ================================================================
    Phase "PHASE 1/4: Aufraeumen"
    # ================================================================

    # 1a) Dienst stoppen + loeschen (falls vorhanden)
    if (Get-Service -Name 'Gitea' -ErrorAction SilentlyContinue) {
        Info "Stoppe und entferne vorhandenen Dienst 'Gitea' ..."
        Stop-Service -Name 'Gitea' -Force -ErrorAction SilentlyContinue
        & sc.exe delete Gitea | Out-Null
        for ($i = 0; $i -lt 10 -and (Get-Service -Name 'Gitea' -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
        if (Get-Service -Name 'Gitea' -ErrorAction SilentlyContinue) {
            Warn "Dienst ist noch als 'wird geloescht' markiert - mache trotzdem weiter."
        } else { Ok "Dienst entfernt." }
    } else { Ok "Kein vorhandener Dienst 'Gitea'." }

    # 1b) laufende gitea-Prozesse beenden
    $procs = Get-Process -Name 'gitea' -ErrorAction SilentlyContinue
    if ($procs) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue; Ok "Laufende gitea-Prozesse beendet." }

    # 1c) alte Firewall-Regel entfernen (wird spaeter neu angelegt)
    Get-NetFirewallRule -DisplayName 'Gitea_9200_Block_Inbound' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    # 1d) Datenverzeichnis behandeln
    if (Test-Path $Dir) {
        if ($Wipe) {
            if (Test-Path $db) {
                Warn "In $Dir liegt eine Gitea-DATENBANK (Repos/Benutzer!)."
                $ans = Read-Host "Wirklich ALLES unwiderruflich loeschen? (JA tippen zum Bestaetigen)"
                if ($ans -ne 'JA') { throw "Abbruch durch Benutzer - nichts geloescht. (GITEA_WIPE=0 fuer Upgrade-Modus)" }
            }
            Info "Repariere Berechtigungen (falls durch v1 beschaedigt) ..."
            $null = Invoke-Exe 'icacls.exe' @($Dir,'/reset','/T','/C','/Q')   # defekte/leere DACLs -> Standard
            Info "Loesche $Dir ..."
            $deleted = $false
            for ($i = 0; $i -lt 3 -and -not $deleted; $i++) {
                try { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop; $deleted = $true }
                catch {
                    Warn "Loeschen fehlgeschlagen (Versuch $($i+1)/3): $($_.Exception.Message)"
                    $null = Invoke-Exe 'takeown.exe' @('/F',$Dir,'/R','/A','/D','Y')
                    $null = Invoke-Exe 'icacls.exe' @($Dir,'/reset','/T','/C','/Q')
                    Start-Sleep 2
                }
            }
            if (-not $deleted -and (Test-Path $Dir)) { throw "Konnte $Dir nicht vollstaendig loeschen. Details im Log: $LogFile" }
            Ok "Alte Installation entfernt."
        } else {
            Ok "Upgrade-Modus: $Dir bleibt bestehen."
        }
    } else { Ok "Kein vorhandenes $Dir." }

    # 1e) Port muss frei sein
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        $owner = ($listener | Select-Object -First 1).OwningProcess
        $pname = (Get-Process -Id $owner -ErrorAction SilentlyContinue).ProcessName
        throw "Port $Port wird bereits von Prozess '$pname' (PID $owner) belegt. Bitte freigeben oder GITEA_PORT aendern."
    }
    Ok "Port $Port ist frei."

    # ================================================================
    Phase "PHASE 2/4: Installation"
    # ================================================================

    foreach($d in @($Dir,$conf,(Join-Path $Dir 'data'),(Join-Path $Dir 'repos'),(Join-Path $Dir 'log'))){
        if(-not (Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # 2a) Git for Windows sicherstellen
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Ok "Git gefunden: $(git --version)"
    } else {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Info "Git nicht gefunden - installiere via winget ..."
            winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements | Out-Null
        } else {
            throw "Git fehlt und winget nicht verfuegbar. Bitte Git for Windows installieren: https://git-scm.com/download/win"
        }
        $env:Path += ';C:\Program Files\Git\cmd'
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git-Installation fehlgeschlagen." }
        Ok "Git installiert."
    }

    # 2b) Version bestimmen
    if ([string]::IsNullOrWhiteSpace($Version)) {
        Info "Ermittle neueste stabile Gitea-Version ..."
        try {
            $rel = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent'='gitea-setup' } `
                    -Uri 'https://api.github.com/repos/go-gitea/gitea/releases/latest'
            $Version = ($rel.tag_name -replace '^v','')
        } catch { throw "Konnte Version nicht ermitteln ($($_.Exception.Message)). Bitte GITEA_VERSION in der .bat setzen." }
    }
    Ok "Gitea-Version: $Version"

    # 2c) Download + SHA256-Pruefung + Entsperren
    if (-not (Test-Path $exe)) {
        $asset = "gitea-$Version-windows-4.0-amd64.exe"
        $url   = "https://dl.gitea.com/gitea/$Version/$asset"
        Info "Lade $asset ..."
        Invoke-WebRequest -UseBasicParsing -Uri $url          -OutFile $exe
        Invoke-WebRequest -UseBasicParsing -Uri "$url.sha256" -OutFile "$exe.sha256"
        $expected = (((Get-Content "$exe.sha256" -Raw) -split '\s+') | Where-Object { $_ } | Select-Object -First 1).ToLower()
        $actual   = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) { Remove-Item $exe -Force -ErrorAction SilentlyContinue; throw "SHA256-Pruefung fehlgeschlagen! erwartet=$expected erhalten=$actual" }
        Unblock-File -LiteralPath $exe -ErrorAction SilentlyContinue    # Mark-of-the-Web entfernen
        Ok "Download verifiziert (SHA256 stimmt) und entsperrt."
    } else {
        Ok "gitea.exe vorhanden (Upgrade-Modus) - Download uebersprungen."
    }

    # 2d) Startbarkeits-Test SOFORT nach Download (v1-Fehler frueh erkennen)
    try {
        $v = Invoke-Exe $exe @('--version')
        if ($v.Code -ne 0) { throw "Exit-Code $($v.Code): $($v.Out)" }
        Ok "gitea.exe startet: $($v.Out)"
    } catch {
        throw "gitea.exe laesst sich nicht ausfuehren: $($_.Exception.Message)  (Virenscanner? Berechtigungen auf $Dir pruefen)"
    }

    # 2e) app.ini erzeugen (nur wenn nicht vorhanden -> Secrets bleiben stabil)
    if (-not (Test-Path $cfg)) {
        Info "Erzeuge Secrets ..."
        $secretKey     = (Invoke-Exe $exe @('generate','secret','SECRET_KEY')).Out.Trim()
        $internalToken = (Invoke-Exe $exe @('generate','secret','INTERNAL_TOKEN')).Out.Trim()
        $jwtSecret     = (Invoke-Exe $exe @('generate','secret','JWT_SECRET')).Out.Trim()
        if (-not $secretKey -or -not $internalToken -or -not $jwtSecret) { throw "Secret-Generierung fehlgeschlagen." }

        if ($Domain) { $rootUrl = "https://$Domain/"; $cookieSecure = 'true';  $domainVal = $Domain }
        else         { $rootUrl = "http://127.0.0.1:$Port/"; $cookieSecure = 'false'; $domainVal = '127.0.0.1' }

        Info "Schreibe $cfg ..."
        $appIni = @"
APP_NAME = Gitea
RUN_MODE = prod
WORK_PATH = $fdir

[server]
PROTOCOL = http
HTTP_ADDR = 127.0.0.1
HTTP_PORT = $Port
DOMAIN = $domainVal
ROOT_URL = $rootUrl
DISABLE_SSH = true
START_SSH_SERVER = false
OFFLINE_MODE = true
LANDING_PAGE = login
APP_DATA_PATH = $fdir/data
ENABLE_GZIP = true

[database]
DB_TYPE = sqlite3
PATH = $fdir/data/gitea.db
SQLITE_JOURNAL_MODE = WAL
LOG_SQL = false

[repository]
ROOT = $fdir/repos
DEFAULT_PRIVATE = true
DEFAULT_BRANCH = main

[security]
INSTALL_LOCK = true
SECRET_KEY = $secretKey
INTERNAL_TOKEN = $internalToken
MIN_PASSWORD_LENGTH = 12
PASSWORD_COMPLEXITY = lower,upper,digit,spec
PASSWORD_HASH_ALGO = pbkdf2_hi
DISABLE_GIT_HOOKS = true
LOGIN_REMEMBER_DAYS = 7
COOKIE_SECURE = $cookieSecure
REVERSE_PROXY_LIMIT = 1
REVERSE_PROXY_TRUSTED_PROXIES = 127.0.0.1/32,::1/128

[oauth2]
JWT_SECRET = $jwtSecret

[service]
DISABLE_REGISTRATION = true
SHOW_REGISTRATION_BUTTON = false
REQUIRE_SIGNIN_VIEW = true
DEFAULT_KEEP_EMAIL_PRIVATE = true
ENABLE_BASIC_AUTHENTICATION = true
ENABLE_NOTIFY_MAIL = false

[picture]
DISABLE_GRAVATAR = true
ENABLE_FEDERATED_AVATAR = false

[openid]
ENABLE_OPENID_SIGNIN = false
ENABLE_OPENID_SIGNUP = false

[mailer]
ENABLED = false

[session]
PROVIDER = file
COOKIE_SECURE = $cookieSecure

[log]
MODE = file
LEVEL = Info
ROOT_PATH = $fdir/log

[cron.update_checker]
ENABLED = false

[other]
SHOW_FOOTER_VERSION = false
"@
        Set-Content -Path $cfg -Value $appIni -Encoding UTF8
        Ok "app.ini erstellt (gehaertet: keine Registrierung, Login-Pflicht, offline)."
    } else {
        Ok "app.ini vorhanden - bleibt unveraendert."
    }

    # 2f) Datenbank migrieren - Fehler SICHTBAR machen
    Info "Initialisiere Datenbank (migrate) ..."
    $mig = Invoke-Exe $exe @('migrate','--config',$cfg,'--work-path',$Dir)
    if ($mig.Code -ne 0) {
        Write-Host $mig.Out
        throw "gitea migrate fehlgeschlagen (Exit-Code $($mig.Code)) - Ausgabe siehe oben."
    }
    Ok "Datenbank initialisiert."

    # 2g) Admin anlegen (nur wenn noch keine Benutzer existieren)
    $adminCreated = $false; $adminInfo = ''; $adminPw = $null
    $ul = Invoke-Exe $exe @('admin','user','list','--config',$cfg,'--work-path',$Dir)
    $userLines = @($ul.Out -split "\r?\n" | Where-Object { $_ -match '\S' }).Count
    if ($ul.Code -eq 0 -and $userLines -le 1) {
        Info "Lege Administrator '$AdminUser' mit Zufallspasswort an ..."
        $uc = Invoke-Exe $exe @('admin','user','create','--username',$AdminUser,'--email',$AdminEmail,'--admin','--random-password','--must-change-password=true','--config',$cfg,'--work-path',$Dir)
        $adminInfo = $uc.Out
        if ($uc.Code -ne 0) { Write-Host $adminInfo; throw "Admin-Anlage fehlgeschlagen (Exit-Code $($uc.Code))." }
        if ($adminInfo -match "random password is '([^']+)'") { $adminPw = $Matches[1] }
        $adminCreated = $true
        Ok "Administrator angelegt."
    } else {
        Ok "Benutzer existieren bereits - Admin-Anlage uebersprungen."
    }

    # ================================================================
    Phase "PHASE 3/4: Windows-Dienst + Start"
    # ================================================================

    $bin = "$exe web --config $cfg --work-path $Dir"
    Info "Erstelle Dienst 'Gitea' (LocalService, Autostart, Auto-Restart) ..."
    & sc.exe create Gitea binPath= "$bin" start= auto obj= "NT AUTHORITY\LocalService" DisplayName= "Gitea" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # evtl. Rest aus 'marked for deletion' -> config versuchen
        & sc.exe config Gitea binPath= "$bin" start= auto obj= "NT AUTHORITY\LocalService" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Dienst konnte nicht angelegt werden. Falls 'marked for deletion': Dienste-Manager/Konsolen schliessen, Server neu starten, Skript erneut ausfuehren."
        }
    }
    & sc.exe failure Gitea reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    & sc.exe description Gitea "Gitea Git-Server - nur lokal 127.0.0.1:$Port" | Out-Null

    if (-not (Get-NetFirewallRule -DisplayName 'Gitea_9200_Block_Inbound' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'Gitea_9200_Block_Inbound' -Direction Inbound -Action Block -Protocol TCP -LocalPort $Port | Out-Null
        Ok "Firewall: eingehend TCP $Port blockiert (Defense-in-Depth)."
    }

    Info "Starte Dienst ..."
    Start-Service -Name 'Gitea'
    if (-not (Test-GiteaHttp $Port)) {
        $glog = Get-ChildItem (Join-Path $Dir 'log') -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($glog) { Write-Host "--- letzte Zeilen $($glog.Name) ---"; Get-Content $glog.FullName -Tail 40 }
        throw "Dienst gestartet, aber keine HTTP-Antwort auf http://127.0.0.1:$Port/ - Logs siehe oben bzw. $Dir\log."
    }
    Ok "Gitea antwortet auf http://127.0.0.1:$Port/"

    # ================================================================
    Phase "PHASE 4/4: ACL-Haertung (mit Selbsttest + Rollback)"
    # ================================================================
    # Sicheres Verfahren (v1-Fehler behoben):
    #  1. /inheritance:d  -> Vererbung trennen, vorhandene ACEs werden KOPIERT
    #     (es gibt nie einen Zustand ohne gueltige Rechte)
    #  2. breite Gruppen entfernen (Users, Authenticated Users, Everyone,
    #     CREATOR OWNER) - nur an der Wurzel, Unterobjekte erben weiter
    #  3. LocalService bekommt Modify (Dienstkonto braucht Lese/Schreibzugriff)
    #  4. Selbsttest: gitea.exe muss weiterhin starten und der Dienst nach
    #     Neustart antworten - sonst automatischer Rollback per /reset.

    Info "Haerte Berechtigungen auf $Dir ..."
    $h1 = Invoke-Exe 'icacls.exe' @($Dir,'/inheritance:d','/C')
    $h2 = Invoke-Exe 'icacls.exe' @($Dir,'/remove:g','*S-1-5-32-545','*S-1-5-11','*S-1-1-0','*S-1-3-0','/C')
    $h3 = Invoke-Exe 'icacls.exe' @($Dir,'/grant','*S-1-5-19:(OI)(CI)M','/C')
    foreach($h in @($h1,$h2,$h3)){ if ($h.Code -ne 0) { Warn "icacls meldete: $($h.Out)" } }

    $hardened = $true
    try { $sm = Invoke-Exe $exe @('--version'); if ($sm.Code -ne 0) { $hardened = $false } } catch { $hardened = $false }
    if ($hardened) {
        Info "Selbsttest: Dienst-Neustart mit gehaerteten Rechten ..."
        Restart-Service -Name 'Gitea' -ErrorAction SilentlyContinue
        if (-not (Test-GiteaHttp $Port)) { $hardened = $false }
    }
    if ($hardened) {
        Ok "ACLs gehaertet (SYSTEM/Administratoren + LocalService, keine breiten Gruppen)."
    } else {
        Warn "Haertung verhindert den Start -> ROLLBACK auf Standard-Rechte ..."
        $null = Invoke-Exe 'icacls.exe' @($Dir,'/reset','/T','/C','/Q')
        Restart-Service -Name 'Gitea' -ErrorAction SilentlyContinue
        if (Test-GiteaHttp $Port) { Warn "Rollback OK - Gitea laeuft mit Standard-NTFS-Rechten (funktional, weniger strikt)." }
        else { throw "Auch nach Rollback keine Antwort - bitte $Dir\log und $LogFile pruefen." }
    }

    # ================================================================
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Ok "FERTIG - Gitea laeuft:  http://127.0.0.1:$Port/"
    Write-Host "============================================================" -ForegroundColor Green
    if ($adminCreated) {
        Write-Host ""
        Write-Host ">>> ADMIN-ZUGANG (einmalig, bitte JETZT notieren) <<<" -ForegroundColor Yellow
        Write-Host "    Benutzer: $AdminUser"
        if ($adminPw) { Write-Host "    Passwort: $adminPw" -ForegroundColor Yellow }
        else          { Write-Host $adminInfo }
        Write-Host "    (muss beim ersten Login geaendert werden)" -ForegroundColor Yellow
    }
    Write-Host ""
    Info "Verwaltung:  Get-Service Gitea | Restart-Service Gitea | Stop-Service Gitea"
    Info "Logs:        $Dir\log    Setup-Protokoll: $LogFile"
    Info "Upgrade:     GITEA_WIPE=0 setzen, gitea.exe loeschen, Skript erneut starten."
    Info "Von aussen mit TLS (optional): siehe gitea/apache-gitea.conf im Repo."
}
catch {
    Write-Host ""
    Write-Host "[FEHLER] $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    $exitCode = 1
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
exit $exitCode
