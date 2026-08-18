@echo off
setlocal EnableExtensions
REM ============================================================
REM  gitea-setup.bat  -  ALLES-IN-EINEM
REM  Native, gehaertete Gitea-Installation als Windows-Dienst.
REM  Bindet auf 127.0.0.1:9200. Kein Docker/WSL/Virtualisierung.
REM  Der PowerShell-Teil ist unten in dieser Datei eingebettet
REM  (nach dem Marker) und wird beim Start selbst ausgefuehrt.
REM
REM  Bedienung: Rechtsklick -> Als Administrator ausfuehren
REM             oder einfach doppelklicken (fragt UAC ab).
REM ============================================================

REM ===== Konfiguration (bei Bedarf anpassen) =====
set "GITEA_DIR=C:\gitea"
set "GITEA_PORT=9200"
set "GITEA_DOMAIN="
set "GITEA_ADMIN=gitadmin"
set "GITEA_EMAIL=admin@localhost"
set "GITEA_VERSION="
set "GITEA_FORCE=0"
REM ================================================

REM ---- Admin-Rechte sicherstellen (UAC) ----
net session >nul 2>&1
if errorlevel 1 (
    echo [i] Fordere Administrator-Rechte an - bitte UAC bestaetigen ...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo [i] Administrator-Rechte OK. Starte Gitea-Setup ...

REM ---- eingebetteten PowerShell-Teil in Temp-Datei entpacken ----
set "PS1=%TEMP%\gitea-setup-%RANDOM%%RANDOM%.ps1"
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
echo [i] Fertig (Exit-Code %rc%).
pause
exit /b %rc%

#@@@GITEA_PS_PAYLOAD@@@
<#  Eingebetteter PowerShell-Teil - wird von der .bat oben ausgefuehrt.  #>

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'

# ---- Konfiguration aus Umgebungsvariablen (von der .bat gesetzt) ----
$Dir        = if ($env:GITEA_DIR)     { $env:GITEA_DIR }        else { 'C:\gitea' }
$Port       = if ($env:GITEA_PORT)    { [int]$env:GITEA_PORT }  else { 9200 }
$Version    = if ($env:GITEA_VERSION) { $env:GITEA_VERSION }    else { '' }
$Domain     = if ($env:GITEA_DOMAIN)  { $env:GITEA_DOMAIN }     else { '' }
$AdminUser  = if ($env:GITEA_ADMIN)   { $env:GITEA_ADMIN }      else { 'gitadmin' }
$AdminEmail = if ($env:GITEA_EMAIL)   { $env:GITEA_EMAIL }      else { 'admin@localhost' }
$Force      = ($env:GITEA_FORCE -eq '1')

function Info($m){ Write-Host "[i] $m"  -ForegroundColor Cyan }
function Ok  ($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m"  -ForegroundColor Yellow }

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) { throw "Bitte als Administrator ausfuehren." }

if ($Dir -match '\s') { throw "GITEA_DIR darf keine Leerzeichen enthalten (aktuell: '$Dir'). Bitte z.B. C:\gitea." }

$conf = Join-Path $Dir 'custom\conf'
$cfg  = Join-Path $conf 'app.ini'
$exe  = Join-Path $Dir 'gitea.exe'
$fdir = ($Dir -replace '\\','/').TrimEnd('/')
foreach($d in @($Dir,$conf,(Join-Path $Dir 'data'),(Join-Path $Dir 'repos'),(Join-Path $Dir 'log'))){
    if(-not (Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$null = Start-Transcript -Path (Join-Path $Dir 'setup-log.txt') -Append -Force -ErrorAction SilentlyContinue
try {
    Info "Zielordner : $Dir"
    Info "Bindung    : 127.0.0.1:$Port  (nur lokal)"
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # 1) Git for Windows sicherstellen
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Ok "Git gefunden: $((git --version) 2>$null)"
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

    # 2) Version bestimmen
    if ([string]::IsNullOrWhiteSpace($Version)) {
        Info "Ermittle neueste stabile Gitea-Version ..."
        try {
            $rel = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent'='gitea-setup' } `
                    -Uri 'https://api.github.com/repos/go-gitea/gitea/releases/latest'
            $Version = ($rel.tag_name -replace '^v','')
        } catch { throw "Konnte Version nicht ermitteln ($($_.Exception.Message)). Bitte GITEA_VERSION in der .bat setzen." }
    }
    Ok "Gitea-Version: $Version"

    # 3) Download + SHA256-Pruefung
    $svc = Get-Service -Name 'Gitea' -ErrorAction SilentlyContinue
    if ((Test-Path $exe) -and $Force -and $svc -and $svc.Status -eq 'Running') {
        Info "Stoppe Dienst fuer Upgrade ..."; Stop-Service Gitea; Start-Sleep 2
    }
    if ((-not (Test-Path $exe)) -or $Force) {
        $asset = "gitea-$Version-windows-4.0-amd64.exe"
        $url   = "https://dl.gitea.com/gitea/$Version/$asset"
        Info "Lade $asset ..."
        Invoke-WebRequest -UseBasicParsing -Uri $url          -OutFile $exe
        Invoke-WebRequest -UseBasicParsing -Uri "$url.sha256" -OutFile "$exe.sha256"
        $expected = (((Get-Content "$exe.sha256" -Raw) -split '\s+') | Where-Object { $_ } | Select-Object -First 1).ToLower()
        $actual   = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) { Remove-Item $exe -Force -EA SilentlyContinue; throw "SHA256-Pruefung fehlgeschlagen! erwartet=$expected erhalten=$actual" }
        Ok "Download verifiziert (SHA256 stimmt)."
    } else {
        Ok "gitea.exe vorhanden - Download uebersprungen (GITEA_FORCE=1 erzwingt Upgrade)."
    }

    # 4) app.ini erzeugen (nur beim ersten Mal -> Secrets bleiben stabil)
    if (-not (Test-Path $cfg)) {
        Info "Erzeuge Secrets ..."
        $secretKey     = (& $exe generate secret SECRET_KEY).Trim()
        $internalToken = (& $exe generate secret INTERNAL_TOKEN).Trim()
        $jwtSecret     = (& $exe generate secret JWT_SECRET).Trim()

        if ($Domain) { $rootUrl = "https://$Domain/"; $cookieSecure = 'true';  $domainVal = $Domain }
        else         { $rootUrl = "http://127.0.0.1:$Port/"; $cookieSecure = 'false'; $domainVal = '127.0.0.1' }

        Info "Schreibe $cfg ..."
        $appIni = @"
APP_NAME = Gitea
RUN_MODE = prod
WORK_PATH = $fdir
; RUN_USER bewusst NICHT gesetzt -> Gitea nutzt das Dienstkonto, kein Mismatch

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

    # 5) ACLs haerten (SIDs -> sprachunabhaengig): SYSTEM / Admins / LocalService
    Info "Setze restriktive Berechtigungen auf $Dir ..."
    & icacls $Dir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-19:(OI)(CI)M" /T /C | Out-Null
    Ok "ACLs gesetzt."

    # 6) DB migrieren + Admin anlegen (nur beim ersten Mal)
    Info "Initialisiere Datenbank (migrate) ..."
    & $exe migrate --config $cfg --work-path $Dir | Out-Null

    $adminCreated = $false; $adminInfo = $null
    $userList = (& $exe admin user list --config $cfg --work-path $Dir) 2>$null
    if (($userList | Measure-Object -Line).Lines -le 1) {
        Info "Lege Administrator '$AdminUser' mit Zufallspasswort an ..."
        $adminInfo = (& $exe admin user create --username $AdminUser --email $AdminEmail --admin --random-password --must-change-password=true --config $cfg --work-path $Dir) 2>&1 | Out-String
        $adminCreated = $true
        Ok "Administrator angelegt."
    } else {
        Ok "Benutzer existieren bereits - Admin-Anlage uebersprungen."
    }

    # 7) Windows-Dienst (LocalService, Autostart, Auto-Restart)
    $bin = "$exe web --config $cfg --work-path $Dir"
    if (-not (Get-Service -Name 'Gitea' -ErrorAction SilentlyContinue)) {
        Info "Erstelle Dienst 'Gitea' ..."
        & sc.exe create Gitea binPath= "$bin" start= auto obj= "NT AUTHORITY\LocalService" DisplayName= "Gitea" | Out-Null
    } else {
        Info "Dienst 'Gitea' existiert - aktualisiere Konfiguration ..."
        & sc.exe config Gitea binPath= "$bin" start= auto obj= "NT AUTHORITY\LocalService" | Out-Null
    }
    & sc.exe failure Gitea reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    & sc.exe description Gitea "Gitea Git-Server - nur lokal 127.0.0.1:$Port" | Out-Null

    # 8) Firewall: eingehend blocken (Defense-in-Depth)
    if (-not (Get-NetFirewallRule -DisplayName 'Gitea_9200_Block_Inbound' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'Gitea_9200_Block_Inbound' -Direction Inbound -Action Block -Protocol TCP -LocalPort $Port | Out-Null
        Ok "Firewall-Regel gesetzt (eingehend TCP $Port blockiert)."
    }

    # 9) Start + Health-Check
    Info "Starte Dienst ..."
    Restart-Service Gitea -ErrorAction SilentlyContinue
    if ((Get-Service Gitea).Status -ne 'Running') { Start-Service Gitea }

    $up = $false
    for ($i=0; $i -lt 30; $i++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -TimeoutSec 3
            if ($r.StatusCode -ge 200) { $up = $true; break }
        } catch { if ($_.Exception.Response) { $up = $true; break } }
        Start-Sleep -Seconds 2
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    if ($up) { Ok "Gitea laeuft:  http://127.0.0.1:$Port/" }
    else     { Warn "Dienst gestartet, aber noch keine HTTP-Antwort. Logs: $Dir\log  /  $Dir\setup-log.txt" }
    Write-Host "============================================================" -ForegroundColor Green

    if ($adminCreated) {
        Write-Host ""
        Write-Host ">>> ADMIN-ZUGANG (einmalig, bitte notieren) <<<" -ForegroundColor Yellow
        Write-Host "    Benutzer: $AdminUser"
        Write-Host $adminInfo
        Write-Host "    Passwort muss beim ersten Login geaendert werden." -ForegroundColor Yellow
    }

    Write-Host ""
    Info "Naechste Schritte:"
    Write-Host "  * Lokal testen:  http://127.0.0.1:$Port/  im Browser des Servers."
    Write-Host "  * Von aussen mit TLS (optional):  gitea/apache-gitea.conf,"
    Write-Host "    dann in $cfg  ROOT_URL + COOKIE_SECURE anpassen und  Restart-Service Gitea."
    Write-Host "  * Upgrade:  in der .bat  GITEA_FORCE=1  setzen und erneut starten."
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
