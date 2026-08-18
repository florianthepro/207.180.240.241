<#
    gitea-setup.ps1  -  Native, gehaertete Gitea-Installation als Windows-Dienst

    Warum Gitea statt GitLab?
      GitLab-Server gibt es nur fuer Linux. Auf diesem KVM-VPS ohne nested
      virtualization laufen weder Docker Desktop noch WSL2 noch eine Linux-VM
      (Log-Beweis: SLAT=False, hasNoVirtualization=true). Gitea ist ein
      GitLab-aehnlicher Git-Server (Repos, Issues, Pull/Merge Requests, Web-UI,
      Registry, CI via Actions), der als einzelne .exe NATIV auf Windows laeuft.

    Ergebnis:
      - Gitea laeuft als Windows-Dienst "Gitea" (Autostart + Auto-Restart)
      - lauscht NUR auf 127.0.0.1:9200 (nicht von aussen erreichbar)
      - laeuft unter dem niedrig-privilegierten Konto NT AUTHORITY\LocalService
      - Datenordner C:\gitea mit restriktiven ACLs (nur SYSTEM/Admins/Dienst)
      - keine offene Registrierung, Login-Pflicht, Secrets gesetzt, offline

    Bedienung (als Administrator):
      powershell -ExecutionPolicy Bypass -File .\gitea-setup.ps1
    oder einfach die beiliegende  gitea-setup.bat  starten (fordert UAC an).

    Optionale Parameter:
      -Domain git.example.com   ROOT_URL/HTTPS-Cookies fuer Betrieb hinter Apache
      -Version 1.24.3           feste Gitea-Version statt "neueste"
      -Force                    gitea.exe neu laden (Upgrade) + Migration
#>

[CmdletBinding()]
param(
    [string]$Dir        = 'C:\gitea',
    [int]   $Port       = 9200,
    [string]$Version    = '',                # leer = neueste stabile ermitteln
    [string]$Domain     = '',                # leer = nur lokal (http://127.0.0.1:PORT)
    [string]$AdminUser  = 'gitadmin',
    [string]$AdminEmail = 'admin@localhost',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'

function Info($m){ Write-Host "[i] $m" -ForegroundColor Cyan }
function Ok  ($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }

# ---- Admin-Check ----
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    throw "Bitte als Administrator ausfuehren (z.B. ueber gitea-setup.bat)."
}

# Verzeichnisse
$conf   = Join-Path $Dir 'custom\conf'
$cfg    = Join-Path $conf 'app.ini'
$exe    = Join-Path $Dir 'gitea.exe'
$fdir   = ($Dir -replace '\\','/').TrimEnd('/')       # Forward-Slashes fuer app.ini

# Der Windows-Dienst-Pfad vertraegt keine Leerzeichen -> frueh und klar abbrechen
if ($Dir -match '\s') {
    throw "-Dir darf keine Leerzeichen enthalten (aktuell: '$Dir'). Bitte z.B. C:\gitea verwenden."
}
foreach($d in @($Dir, $conf, (Join-Path $Dir 'data'), (Join-Path $Dir 'repos'), (Join-Path $Dir 'log'))){
    if(-not (Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$null = Start-Transcript -Path (Join-Path $Dir 'setup-log.txt') -Append -Force -ErrorAction SilentlyContinue
try {
    Info "Zielordner : $Dir"
    Info "Bindung    : 127.0.0.1:$Port  (nur lokal)"
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # ---------------------------------------------------------------
    # 1) Git for Windows sicherstellen (Gitea braucht git auf dem Host)
    # ---------------------------------------------------------------
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Ok "Git gefunden: $((git --version) 2>$null)"
    } else {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Info "Git nicht gefunden - installiere via winget ..."
            winget install --id Git.Git -e --source winget `
                --accept-source-agreements --accept-package-agreements | Out-Null
        } else {
            throw "Git fehlt und winget ist nicht verfuegbar. Bitte Git for Windows installieren: https://git-scm.com/download/win"
        }
        $env:Path += ';C:\Program Files\Git\cmd'
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw "Git-Installation fehlgeschlagen. Bitte manuell installieren und Skript erneut starten."
        }
        Ok "Git installiert."
    }

    # ---------------------------------------------------------------
    # 2) Gitea-Version bestimmen
    # ---------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($Version)) {
        Info "Ermittle neueste stabile Gitea-Version ..."
        try {
            $rel = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent'='gitea-setup' } `
                    -Uri 'https://api.github.com/repos/go-gitea/gitea/releases/latest'
            $Version = ($rel.tag_name -replace '^v','')
        } catch {
            throw "Konnte neueste Version nicht ermitteln ($($_.Exception.Message)). Bitte mit -Version <x.y.z> starten."
        }
    }
    Ok "Gitea-Version: $Version"

    # ---------------------------------------------------------------
    # 3) Download + SHA256-Integritaetspruefung
    # ---------------------------------------------------------------
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
        if ($expected -ne $actual) {
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
            throw "SHA256-Pruefung fehlgeschlagen! erwartet=$expected  erhalten=$actual"
        }
        Ok "Download verifiziert (SHA256 stimmt)."
    } else {
        Ok "gitea.exe vorhanden - ueberspringe Download (mit -Force erzwingen/aktualisieren)."
    }

    # ---------------------------------------------------------------
    # 4) app.ini erzeugen (nur wenn noch nicht vorhanden -> Secrets bleiben stabil)
    # ---------------------------------------------------------------
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
        Ok "app.ini vorhanden - bleibt unveraendert (Secrets/Config erhalten)."
    }

    # ---------------------------------------------------------------
    # 5) ACLs haerten: nur SYSTEM / Administratoren / LocalService
    #    (SIDs statt Namen -> sprachunabhaengig)
    # ---------------------------------------------------------------
    Info "Setze restriktive Berechtigungen auf $Dir ..."
    & icacls $Dir /inheritance:r /grant:r `
        "*S-1-5-18:(OI)(CI)F" `
        "*S-1-5-32-544:(OI)(CI)F" `
        "*S-1-5-19:(OI)(CI)M" /T /C | Out-Null
    Ok "ACLs gesetzt (SYSTEM/Admins = Vollzugriff, LocalService = Aendern)."

    # ---------------------------------------------------------------
    # 6) DB migrieren + Admin anlegen (nur beim ersten Mal)
    # ---------------------------------------------------------------
    $dbFile = Join-Path $Dir 'data\gitea.db'
    Info "Initialisiere Datenbank (migrate) ..."
    & $exe migrate --config $cfg --work-path $Dir | Out-Null

    $adminCreated = $false
    $adminInfo    = $null
    $userList = (& $exe admin user list --config $cfg --work-path $Dir) 2>$null
    if (($userList | Measure-Object -Line).Lines -le 1) {
        Info "Lege Administrator '$AdminUser' mit Zufallspasswort an ..."
        $adminInfo = (& $exe admin user create --username $AdminUser --email $AdminEmail `
                        --admin --random-password --must-change-password=true `
                        --config $cfg --work-path $Dir) 2>&1 | Out-String
        $adminCreated = $true
        Ok "Administrator angelegt."
    } else {
        Ok "Es existieren bereits Benutzer - Admin-Anlage uebersprungen."
    }

    # ---------------------------------------------------------------
    # 7) Windows-Dienst anlegen/konfigurieren (LocalService, Autostart, Auto-Restart)
    # ---------------------------------------------------------------
    $bin = "$exe web --config $cfg --work-path $Dir"
    if (-not (Get-Service -Name 'Gitea' -ErrorAction SilentlyContinue)) {
        Info "Erstelle Dienst 'Gitea' ..."
        & sc.exe create Gitea binPath= "$bin" start= auto obj= "NT AUTHORITY\LocalService" DisplayName= "Gitea" | Out-Null
    } else {
        Info "Dienst 'Gitea' existiert - aktualisiere Konfiguration ..."
        & sc.exe config Gitea binPath= "$bin" start= auto obj= "NT AUTHORITY\LocalService" | Out-Null
    }
    # Automatischer Neustart bei Absturz (Stabilitaet)
    & sc.exe failure Gitea reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    & sc.exe description Gitea "Gitea Git-Server - nur lokal 127.0.0.1:$Port" | Out-Null

    # ---------------------------------------------------------------
    # 8) Firewall: eingehend 9200 blocken (Defense-in-Depth; lauscht ohnehin nur lokal)
    # ---------------------------------------------------------------
    if (-not (Get-NetFirewallRule -DisplayName 'Gitea_9200_Block_Inbound' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'Gitea_9200_Block_Inbound' -Direction Inbound `
            -Action Block -Protocol TCP -LocalPort $Port | Out-Null
        Ok "Firewall-Regel gesetzt (eingehend TCP $Port blockiert)."
    }

    # ---------------------------------------------------------------
    # 9) Dienst starten + Health-Check
    # ---------------------------------------------------------------
    Info "Starte Dienst ..."
    Restart-Service Gitea -ErrorAction SilentlyContinue
    if ((Get-Service Gitea).Status -ne 'Running') { Start-Service Gitea }

    $up = $false
    for ($i=0; $i -lt 30; $i++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -TimeoutSec 3
            if ($r.StatusCode -ge 200) { $up = $true; break }
        } catch {
            if ($_.Exception.Response) { $up = $true; break }   # HTTP-Antwort (z.B. 302) = laeuft
        }
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
    Write-Host "  * Lokal testen:  im Browser des Servers http://127.0.0.1:$Port/ oeffnen."
    Write-Host "  * Von aussen erreichbar (optional, mit TLS) -> gitea/apache-gitea.conf"
    Write-Host "    Danach in $cfg  ROOT_URL=https://DEINE.DOMAIN/  und COOKIE_SECURE=true setzen,"
    Write-Host "    dann:  Restart-Service Gitea"
    Write-Host "  * Upgrade spaeter:  dieses Skript mit  -Force  erneut starten."
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
