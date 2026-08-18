@echo off
setlocal EnableExtensions
REM ============================================================
REM  gitea-ssh-setup.bat  -  ALLES-IN-EINEM
REM  Aktiviert Giteas eingebauten SSH-Server auf Windows sauber:
REM   1. app.ini anpassen (Backup wird angelegt, idempotent)
REM   2. Windows-Firewall fuer den SSH-Port oeffnen
REM   3. Gitea neu starten (Dienst oder Prozess)
REM   4. Pruefen, dass SSH-Port und Web-Port wieder antworten
REM  Danach: Public Key in Gitea hinterlegen und per
REM  ssh://git@<SSH_DOMAIN>:<SSH_PORT>/owner/repo.git arbeiten.
REM
REM  WICHTIG: SSH_DOMAIN muss den Server DIREKT erreichen.
REM  gitea.getitsec.com laeuft ueber Cloudflare - Cloudflare
REM  leitet kein SSH weiter! Deshalb hier IP (oder einen
REM  DNS-Eintrag ohne Cloudflare-Proxy) verwenden.
REM
REM  Bedienung: Rechtsklick -> Als Administrator ausfuehren
REM             oder doppelklicken (fragt UAC ab).
REM ============================================================

REM ===== Konfiguration (bei Bedarf anpassen) =====
set "GITEA_DIR=C:\gitea"
set "SSH_PORT=2222"
set "SSH_DOMAIN=207.180.240.241"
set "SSH_USER=git"
set "WEB_PORT=3000"
REM ================================================

net session >nul 2>&1
if errorlevel 1 (
    echo [i] Fordere Administrator-Rechte an - bitte UAC bestaetigen ...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo [i] Administrator-Rechte OK.

set "PS1=%TEMP%\gitea-ssh-setup-%RANDOM%%RANDOM%.ps1"
set "start="
for /f "delims=:" %%a in ('findstr /n /b /c:"#@@@SSH_PS_PAYLOAD@@@" "%~f0"') do set "start=%%a"
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

#@@@SSH_PS_PAYLOAD@@@
<#  Gitea SSH-Setup - wird von der .bat oben ausgefuehrt.  #>
$ErrorActionPreference = 'Stop'

$Dir       = if ($env:GITEA_DIR)  { $env:GITEA_DIR }       else { 'C:\gitea' }
$SshPort   = if ($env:SSH_PORT)   { [int]$env:SSH_PORT }   else { 2222 }
$SshDomain = if ($env:SSH_DOMAIN) { $env:SSH_DOMAIN }      else { '207.180.240.241' }
$SshUser   = if ($env:SSH_USER)   { $env:SSH_USER }        else { 'git' }
$WebPort   = if ($env:WEB_PORT)   { [int]$env:WEB_PORT }   else { 3000 }

$AppIni   = Join-Path $Dir 'custom\conf\app.ini'
$GiteaExe = Join-Path $Dir 'gitea.exe'

function Info($m){ Write-Host "[i] $m"  -ForegroundColor Cyan }
function Ok  ($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m"  -ForegroundColor Yellow }

function Test-Port([string]$TargetHost,[int]$Port,[int]$TimeoutMs){
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($TargetHost,$Port)
        if($t.Wait($TimeoutMs) -and $c.Connected){ return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}

function Set-IniKey([System.Collections.Generic.List[string]]$Lines,[string]$Section,[string]$Key,[string]$Value){
    $secRx = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
    $keyRx = '^\s*' + [regex]::Escape($Key) + '\s*='
    $secStart = -1
    for($i=0; $i -lt $Lines.Count; $i++){
        if($Lines[$i] -match $secRx){ $secStart = $i; break }
    }
    if($secStart -lt 0){
        $Lines.Add('')
        $Lines.Add('[' + $Section + ']')
        $Lines.Add($Key + ' = ' + $Value)
        return
    }
    $secEnd = $Lines.Count
    for($i=$secStart+1; $i -lt $Lines.Count; $i++){
        if($Lines[$i] -match '^\s*\[.+\]\s*$'){ $secEnd = $i; break }
    }
    for($i=$secStart+1; $i -lt $secEnd; $i++){
        if($Lines[$i] -match $keyRx){ $Lines[$i] = $Key + ' = ' + $Value; return }
    }
    $Lines.Insert($secStart+1, $Key + ' = ' + $Value)
}

# ---- 0) Vorbedingungen ----
if(-not (Test-Path -LiteralPath $AppIni)){ throw "app.ini nicht gefunden: $AppIni (GITEA_DIR in der .bat anpassen)" }
Info "app.ini    : $AppIni"
Info "SSH        : ${SshUser}@${SshDomain}:${SshPort} (eingebauter Gitea-SSH-Server)"

if(Test-Port '127.0.0.1' $SshPort 1000){
    Warn "Port $SshPort ist bereits belegt. Wenn das nicht Gitea ist, bitte SSH_PORT in der .bat aendern und neu starten."
}

# ---- 1) app.ini anpassen (mit Backup) ----
$backup = $AppIni + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $AppIni -Destination $backup
Ok "Backup: $backup"

$lines = [System.Collections.Generic.List[string]]::new()
foreach($l in [IO.File]::ReadAllLines($AppIni)){ $lines.Add($l) }

Set-IniKey $lines 'server' 'DISABLE_SSH'             'false'
Set-IniKey $lines 'server' 'START_SSH_SERVER'        'true'
Set-IniKey $lines 'server' 'BUILTIN_SSH_SERVER_USER' $SshUser
Set-IniKey $lines 'server' 'SSH_DOMAIN'              $SshDomain
Set-IniKey $lines 'server' 'SSH_PORT'                "$SshPort"
Set-IniKey $lines 'server' 'SSH_LISTEN_HOST'         '0.0.0.0'
Set-IniKey $lines 'server' 'SSH_LISTEN_PORT'         "$SshPort"

[IO.File]::WriteAllLines($AppIni, $lines)
Ok "app.ini aktualisiert (START_SSH_SERVER=true, Port $SshPort, SSH_DOMAIN=$SshDomain)."

# ---- 2) Firewall ----
$ruleName = "Gitea SSH $SshPort"
if(-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)){
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $SshPort -Action Allow | Out-Null
    Ok "Firewall-Regel '$ruleName' angelegt (eingehend TCP $SshPort)."
} else {
    Ok "Firewall-Regel '$ruleName' existiert bereits."
}

# ---- 3) Gitea neu starten ----
$svc = Get-Service -Name 'Gitea' -ErrorAction SilentlyContinue
if($svc){
    Info "Starte Dienst 'Gitea' neu ..."
    Restart-Service -Name 'Gitea' -Force
} else {
    $procs = @(Get-Process -Name 'gitea' -ErrorAction SilentlyContinue)
    if($procs.Count -gt 0){
        Info "Beende laufenden Gitea-Prozess (PID $($procs[0].Id)) ..."
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 2
    }
    if(Test-Path -LiteralPath $GiteaExe){
        Info "Starte $GiteaExe web ..."
        Start-Process -FilePath $GiteaExe -ArgumentList 'web' -WorkingDirectory $Dir -WindowStyle Minimized
        Warn "Gitea laeuft als Prozess dieser Sitzung - bei Abmeldung endet es."
        Warn "Dauerhaft sauber: als Dienst oder Aufgabenplanung (Start bei Systemstart) einrichten."
    } else {
        throw "gitea.exe nicht gefunden: $GiteaExe - bitte Gitea manuell neu starten."
    }
}

# ---- 4) Verifikation ----
Info "Warte auf Gitea (Web $WebPort + SSH $SshPort) ..."
$webOk = $false; $sshOk = $false
for($i=0; $i -lt 30; $i++){
    Start-Sleep -Seconds 2
    if(-not $webOk){ $webOk = Test-Port '127.0.0.1' $WebPort 1000 }
    if(-not $sshOk){ $sshOk = Test-Port '127.0.0.1' $SshPort 1000 }
    if($webOk -and $sshOk){ break }
}
if($webOk){ Ok "Web-Oberflaeche antwortet auf Port $WebPort." } else { Warn "Web-Port $WebPort antwortet nicht - Gitea-Log pruefen ($Dir\log)." }
if($sshOk){ Ok "SSH-Server lauscht auf Port $SshPort." }      else { Warn "SSH-Port $SshPort antwortet nicht - Gitea-Log pruefen ($Dir\log)." }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Ok 'SSH-Setup abgeschlossen. Naechste Schritte (auf deinem PC):'
Write-Host ''
Write-Host '  1. Key erzeugen (falls noch keiner existiert):'
Write-Host '       ssh-keygen -t ed25519'
Write-Host '  2. Public Key in Gitea hinterlegen:'
Write-Host '       https://gitea.getitsec.com/user/settings/keys'
Write-Host '       (Inhalt von %USERPROFILE%\.ssh\id_ed25519.pub einfuegen)'
Write-Host '  3. Verbindung testen:'
Write-Host ('       ssh -p {0} {1}@{2}' -f $SshPort,$SshUser,$SshDomain)
Write-Host '       (Erwartete Antwort: "Hi there ...! You have successfully authenticated...")'
Write-Host '  4. Klonen/Pushen:'
Write-Host ('       git clone ssh://{0}@{1}:{2}/florianthepro/p2.git' -f $SshUser,$SshDomain,$SshPort)
Write-Host '============================================================' -ForegroundColor Green
exit 0
