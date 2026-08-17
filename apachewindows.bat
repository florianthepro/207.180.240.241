@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "AW_SELF=%~f0"
set "AW_DIR=%~dp0"

fltmc >nul 2>&1
if not errorlevel 1 goto run
if "%~1"=="--elevated" (
  echo Administrator rights are required.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { Start-Process -FilePath $env:AW_SELF -ArgumentList '--elevated' -WorkingDirectory $env:AW_DIR -Verb RunAs -ErrorAction Stop } catch { Write-Host ('Elevation cancelled: ' + $_.Exception.Message) -ForegroundColor Red; Start-Sleep -Seconds 4 }"
exit /b 0

:run
set "AW_TMP=%TEMP%\aw-%RANDOM%%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -Command "$ErrorActionPreference='Stop'; $a='#@AW_'+'MAIN_BEGIN@'; $b='#@AW_'+'MAIN_END@'; $c=[IO.File]::ReadAllText($env:AW_SELF); $s=$c.IndexOf($a); if($s -lt 0){exit 3}; $s=$s+$a.Length; $e=$c.IndexOf($b,$s); if($e -lt 0){exit 3}; [IO.File]::WriteAllText($env:AW_TMP,$c.Substring($s,$e-$s),(New-Object System.Text.UTF8Encoding $true)); exit 0"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto broken
if not exist "%AW_TMP%" goto broken

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AW_TMP%"
set "RC=%ERRORLEVEL%"
del /f /q "%AW_TMP%" >nul 2>&1
endlocal & exit /b %RC%

:broken
echo Could not unpack the embedded payload.
pause
endlocal & exit /b 1

#@AW_MAIN_BEGIN@
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Self      = [string]$env:AW_SELF
$ApacheDir = 'C:\Apache24'
$PhpDir    = 'C:\php'
$WacsDir   = 'C:\win-acme'
$AutoDir   = 'C:\apache-automation'
$SitesDir  = 'C:\htdocs'
$SvcName   = 'Apache2.4'
$Workers   = 4

$UrlApache = 'https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.68-260617-Win64-VS18.zip'
$UrlWacs   = 'https://github.com/win-acme/win-acme/releases/download/v2.2.9.1701/win-acme.v2.2.9.1701.x64.pluggable.zip'
$UrlVcRt   = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'

$Httpd     = Join-Path $ApacheDir 'bin\httpd.exe'
$Conf      = Join-Path $ApacheDir 'conf\httpd.conf'
$SiteConf  = Join-Path $ApacheDir 'conf\sites'
$AcmeRoot  = Join-Path $AutoDir 'acme'
$PemDir    = Join-Path $AutoDir 'pem'
$CertDir   = Join-Path $AutoDir 'certs'
$LogDir    = Join-Path $AutoDir 'logs'
$EmptyDir  = Join-Path $AutoDir 'empty'
$PhpTmp    = Join-Path $AutoDir 'php\tmp'
$PhpSess   = Join-Path $AutoDir 'php\sessions'
$ConfigJs  = Join-Path $AutoDir 'config.json'
$WorkerPs  = Join-Path $AutoDir 'Invoke-Provision.ps1'
$SyncPs    = Join-Path $AutoDir 'Sync-Certificates.ps1'
$HookBat   = Join-Path $AutoDir 'apply-certificates.bat'
$TaskName  = 'Apache-HTTPS-AutoProvision'

function Line { param([string]$t = '') Write-Host $t }
function Head { param([string]$t) Write-Host ('  ' + $t) -ForegroundColor White }
function Ok   { param([string]$t) Write-Host ('  ' + $t) -ForegroundColor Green }
function Bad  { param([string]$t) Write-Host ('  ' + $t) -ForegroundColor Red }
function Warn { param([string]$t) Write-Host ('  ' + $t) -ForegroundColor Yellow }
function Dim  { param([string]$t) Write-Host ('  ' + $t) -ForegroundColor DarkGray }
function Rule { Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray }

function Pause-Key {
    Line
    Write-Host '  press any key' -ForegroundColor DarkGray
    [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Ask {
    param([string]$Prompt, [string]$Default = '')
    $suffix = ''
    if ($Default) { $suffix = ' [' + $Default + ']' }
    $answer = Read-Host ('  ' + $Prompt + $suffix)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Ask-Yes {
    param([string]$Prompt)
    while ($true) {
        $a = (Read-Host ('  ' + $Prompt + ' [y/n]')).Trim().ToLowerInvariant()
        if ($a -eq 'y' -or $a -eq 'j') { return $true }
        if ($a -eq 'n') { return $false }
    }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $out = & $FilePath @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Lines = @($out | ForEach-Object { [string]$_ }) }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-ServiceRunning {
    param([string]$Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    return ($null -ne $s -and $s.Status -eq 'Running')
}

function Test-DomainName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 253) { return $false }
    if ($Name -notmatch '^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$') { return $false }
    $labels = $Name.Split('.')
    $tld = $labels[$labels.Count - 1]
    if ($tld -notmatch '^([a-z]{2,63}|xn--[a-z0-9-]{2,59})$') { return $false }
    return (@('local','localhost','localdomain','test','invalid','example','internal','intranet','home','lan','corp') -notcontains $tld)
}

function Get-Domains {
    return @(Get-ChildItem -LiteralPath $SitesDir -Directory -ErrorAction SilentlyContinue |
             ForEach-Object { $_.Name.ToLowerInvariant() } |
             Where-Object { Test-DomainName $_ } | Sort-Object)
}

function Get-CertInfo {
    param([string]$Domain)
    $crt = Join-Path $CertDir ($Domain + '.crt.pem')
    if (-not (Test-Path -LiteralPath $crt -PathType Leaf)) { return $null }
    try { $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($crt) } catch { return $null }
    $staging = ([string]$c.Issuer -match 'STAGING')
    return [pscustomobject]@{
        Days    = [int][math]::Floor(($c.NotAfter - (Get-Date)).TotalDays)
        Staging = $staging
        Issuer  = [string]$c.Issuer
    }
}

function Get-PhpVersion {
    $exe = Join-Path $PhpDir 'php.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return '' }
    $r = Invoke-Native -FilePath $exe -Arguments @('-r', 'echo PHP_VERSION;')
    if ($r.ExitCode -ne 0) { return '' }
    return ([string](@($r.Lines) | Select-Object -First 1)).Trim()
}

function Get-ApacheVersion {
    if (-not (Test-Path -LiteralPath $Httpd -PathType Leaf)) { return '' }
    $r = Invoke-Native -FilePath $Httpd -Arguments @('-v')
    $first = [string](@($r.Lines) | Select-Object -First 1)
    if ($first -match 'Apache/([0-9\.]+)') { return $Matches[1] }
    return ''
}

function Get-WorkersUp {
    $up = 0
    for ($i = 0; $i -lt $Workers; $i++) {
        $c = New-Object System.Net.Sockets.TcpClient
        try { $c.Connect('127.0.0.1', (9000 + $i)); $up++ } catch { } finally { $c.Close() }
    }
    return $up
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigJs -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $ConfigJs -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-Config {
    param($Config)
    [IO.File]::WriteAllText($ConfigJs, ($Config | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $true))
}

function Get-State {
    $apacheVer = Get-ApacheVersion
    $phpVer    = Get-PhpVersion
    $domains   = Get-Domains
    $withCert  = 0
    $anyStage  = $false
    foreach ($d in $domains) {
        $i = Get-CertInfo -Domain $d
        if ($i -and $i.Days -gt 0) { $withCert++; if ($i.Staging) { $anyStage = $true } }
    }
    $cfg = Get-Config
    $mail = ''
    if ($cfg) { try { $mail = [string]$cfg.Email } catch { } }
    return [pscustomobject]@{
        Apache      = $apacheVer
        Running     = (Test-ServiceRunning $SvcName)
        ServiceOk   = ($null -ne (Get-Service -Name $SvcName -ErrorAction SilentlyContinue))
        Php         = $phpVer
        PhpUp       = $(if ($phpVer) { Get-WorkersUp } else { 0 })
        Wacs        = (Test-Path -LiteralPath (Join-Path $WacsDir 'wacs.exe') -PathType Leaf)
        Domains     = $domains
        WithCert    = $withCert
        Staging     = $anyStage
        Email       = $mail
        Automation  = ($null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue))
    }
}

function Get-Download {
    param([string]$Url, [string]$OutFile, [string]$What)
    Dim ($What + ' ...')
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 900 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    } catch {
        throw ($What + ' failed: ' + $_.Exception.Message)
    }
    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) { throw ($What + ' produced no file') }
    $size = (Get-Item -LiteralPath $OutFile).Length
    if ($size -lt 100000) { throw ($What + ' returned only ' + $size + ' bytes') }
    Dim ('  ' + [math]::Round($size / 1MB, 1) + ' MB')
}

function Install-Zip {
    param([string]$Url, [string]$Target, [string]$TopLevel, [string]$Marker, [string]$What)
    $tmp = Join-Path $env:TEMP ('aw-' + [Guid]::NewGuid().ToString('N'))
    $zip = $tmp + '.zip'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Get-Download -Url $Url -OutFile $zip -What ('downloading ' + $What)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        $src = $tmp
        if ($TopLevel -and (Test-Path -LiteralPath (Join-Path $tmp $TopLevel) -PathType Container)) { $src = Join-Path $tmp $TopLevel }
        if (-not (Test-Path -LiteralPath (Join-Path $src $Marker))) {
            $found = @(Get-ChildItem -LiteralPath $tmp -Recurse -Filter (Split-Path -Leaf $Marker) -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($found.Count -eq 0) { throw ($What + ': ' + $Marker + ' not found in the archive') }
            $src = Split-Path -Parent $found[0].FullName
        }
        if (Test-Path -LiteralPath $Target) {
            Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $Target -Recurse -Force
        if (-not (Test-Path -LiteralPath (Join-Path $Target $Marker))) { throw ($What + ' did not extract correctly') }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-PhpUrl {
    $index = 'https://windows.php.net/downloads/releases/'
    $html = (Invoke-WebRequest -Uri $index -UseBasicParsing -TimeoutSec 180 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)').Content
    $best = $null
    foreach ($m in [regex]::Matches([string]$html, 'php-(\d+)\.(\d+)\.(\d+)-nts-Win32-vs(\d+)-x64\.zip')) {
        $v = New-Object System.Version ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[3].Value)
        if ($null -eq $best -or $v -gt $best.V) { $best = [pscustomobject]@{ V = $v; F = $m.Value } }
    }
    if ($null -eq $best) { throw 'no NTS x64 build found on windows.php.net' }
    return ($index + $best.F)
}

function Test-VcRuntime {
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($p.Installed -eq 1) { return $true }
        } catch { }
    }
    return $false
}

function Install-VcRuntime {
    $exe = Join-Path $env:TEMP ('vcredist-' + [Guid]::NewGuid().ToString('N') + '.exe')
    try {
        Get-Download -Url $UrlVcRt -OutFile $exe -What 'downloading Visual C++ runtime'
        $p = Start-Process -FilePath $exe -ArgumentList '/install', '/quiet', '/norestart' -PassThru -Wait
        return ($p.ExitCode -eq 0 -or $p.ExitCode -eq 1638 -or $p.ExitCode -eq 3010)
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    }
}

function Set-HardenedAcl {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $r = Invoke-Native -FilePath 'icacls.exe' -Arguments @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
    return ($r.ExitCode -eq 0)
}

function Grant-Access {
    param([string]$Path, [string]$Rights)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    [void](Invoke-Native -FilePath 'icacls.exe' -Arguments @($Path, '/grant', ('*S-1-5-19:(OI)(CI)' + $Rights)))
}

function Stop-Strays {
    foreach ($n in @('httpd', 'php-cgi')) {
        if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0) {
            [void](Invoke-Native -FilePath 'taskkill.exe' -Arguments @('/F', '/T', '/IM', ($n + '.exe')))
        }
    }
    Start-Sleep -Seconds 1
}

function Get-Payload {
    param([string]$Name)
    $raw = [IO.File]::ReadAllText($Self)
    $a = '#@AW_' + $Name + '_BEGIN@'
    $b = '#@AW_' + $Name + '_END@'
    $i = $raw.IndexOf($a)
    if ($i -lt 0) { throw ('payload ' + $Name + ' missing') }
    $i = $i + $a.Length
    $j = $raw.IndexOf($b, $i)
    if ($j -lt 0) { throw ('payload ' + $Name + ' unterminated') }
    return ($raw.Substring($i, $j - $i).Trim("`r", "`n") + "`r`n")
}

function New-Directories {
    foreach ($d in @($AutoDir, $AcmeRoot, (Join-Path $AcmeRoot '.well-known\acme-challenge'), $PemDir, $CertDir, $LogDir, $EmptyDir, $SiteConf, $SitesDir, (Join-Path $ApacheDir 'logs'))) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Set-AllAcls {
    param([bool]$WithPhp)
    $roots = @($AutoDir, $SitesDir, $ApacheDir, (Join-Path $env:ProgramData 'win-acme'))
    if (Test-Path -LiteralPath $WacsDir) { $roots += $WacsDir }
    if ($WithPhp -and (Test-Path -LiteralPath $PhpDir)) { $roots += $PhpDir }
    foreach ($r in ($roots | Select-Object -Unique)) {
        if (-not (Set-HardenedAcl -Path $r)) { throw ('could not lock down ' + $r) }
    }
    foreach ($g in @(@($ApacheDir, 'RX'), @((Join-Path $ApacheDir 'logs'), 'M'), @($CertDir, 'RX'), @($AcmeRoot, 'RX'),
                     @($EmptyDir, 'RX'), @($LogDir, 'M'), @($SitesDir, 'RX'))) {
        Grant-Access -Path $g[0] -Rights $g[1]
    }
    if ($WithPhp) {
        foreach ($g in @(@($PhpTmp, 'M'), @($PhpSess, 'M'), @($PhpDir, 'RX'))) { Grant-Access -Path $g[0] -Rights $g[1] }
    }
}

function Write-ApacheConfig {
    param([bool]$WithPhp)
    $slashAcme  = $AcmeRoot.Replace('\', '/')
    $slashCerts = $CertDir.Replace('\', '/')
    $slashLogs  = $LogDir.Replace('\', '/')
    $slashEmpty = $EmptyDir.Replace('\', '/')

    $php = ''
    if ($WithPhp) {
        $members = ((0..($Workers - 1)) | ForEach-Object { '    BalancerMember "fcgi://127.0.0.1:' + (9000 + $_) + '"' }) -join [Environment]::NewLine
        $php = @"
ProxyRequests Off
<IfModule proxy_fcgi_module>
    ProxyFCGIBackendType GENERIC
</IfModule>
<Proxy "balancer://phpfcgi">
$members
</Proxy>

"@
    }

    $hardening = @"
Listen 443

ServerTokens Prod
ServerSignature Off
TraceEnable Off
FileETag None
Timeout 30
KeepAliveTimeout 5
LimitRequestBody 67108864
LimitRequestFields 60
LimitRequestFieldSize 8190

<Directory />
    AllowOverride None
    Options None
    Require all denied
</Directory>

<FilesMatch "^\.">
    Require all denied
</FilesMatch>
<FilesMatch "\.(ini|log|bak|old|sql|sqlite|db|env|config|pem|key)$">
    Require all denied
</FilesMatch>

<IfModule headers_module>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always unset X-Powered-By
</IfModule>

<IfModule ssl_module>
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    SSLHonorCipherOrder off
    SSLSessionTickets off
    SSLOptions +StrictRequire
    SSLUseStapling On
    SSLStaplingCache "shmcb:logs/ssl_stapling(32768)"
    SSLSessionCache "shmcb:logs/ssl_scache(512000)"
    SSLSessionCacheTimeout 300
</IfModule>

$php
IncludeOptional conf/sites/*.conf
"@
    Set-Content -LiteralPath (Join-Path $ApacheDir 'conf\hardening.conf') -Value $hardening -Encoding ASCII

    $acme = @"
<VirtualHost *:80>
    ServerName acme-only.invalid
    DocumentRoot "$slashAcme"
    <Directory "$slashAcme">
        AllowOverride None
        Options -Indexes -Includes -ExecCGI -FollowSymLinks
        Require all granted
    </Directory>
    <IfModule rewrite_module>
        RewriteEngine On
        RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
        RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
    </IfModule>
    ErrorLog  "$slashLogs/acme-error.log"
    CustomLog "$slashLogs/acme-access.log" combined
</VirtualHost>
"@
    Set-Content -LiteralPath (Join-Path $SiteConf '00-acme-http.conf') -Value $acme -Encoding ASCII

    $openssl = Join-Path $ApacheDir 'bin\openssl.exe'
    $defCrt = Join-Path $CertDir '_default.crt.pem'
    $defKey = Join-Path $CertDir '_default.key.pem'
    $defOk = $false
    if ((Test-Path -LiteralPath $defCrt -PathType Leaf) -and (Test-Path -LiteralPath $defKey -PathType Leaf)) {
        try {
            $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($defCrt)
            $defOk = ($c.NotAfter -gt (Get-Date)) -and ([IO.File]::ReadAllText($defKey) -match 'PRIVATE KEY')
        } catch { $defOk = $false }
    }
    if (-not $defOk -and (Test-Path -LiteralPath $openssl -PathType Leaf)) {
        Remove-Item -LiteralPath $defCrt -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $defKey -Force -ErrorAction SilentlyContinue
        [void](Invoke-Native -FilePath $openssl -Arguments @('req','-x509','-newkey','rsa:2048','-nodes','-keyout',$defKey,'-out',$defCrt,'-days','3650','-subj','/CN=unknown-host.invalid'))
        $defOk = (Test-Path -LiteralPath $defCrt -PathType Leaf) -and (Test-Path -LiteralPath $defKey -PathType Leaf)
    }
    $defConf = Join-Path $SiteConf '00-default-https.conf'
    if ($defOk) {
        $dv = @"
<VirtualHost *:443>
    ServerName unknown-host.invalid
    DocumentRoot "$slashEmpty"
    SSLEngine on
    SSLCertificateFile    "$slashCerts/_default.crt.pem"
    SSLCertificateKeyFile "$slashCerts/_default.key.pem"
    <Location />
        Require all denied
    </Location>
    ErrorLog  "$slashLogs/default-error.log"
    CustomLog "$slashLogs/default-access.log" combined
</VirtualHost>
"@
        Set-Content -LiteralPath $defConf -Value $dv -Encoding ASCII
    } else {
        Remove-Item -LiteralPath $defConf -Force -ErrorAction SilentlyContinue
    }

    $lines = [System.Collections.ArrayList]@(Get-Content -LiteralPath $Conf)
    $enable = @('ssl_module','socache_shmcb_module','rewrite_module','headers_module','alias_module','dir_module','mime_module','log_config_module','setenvif_module','authz_core_module','authz_host_module','unixd_module')
    $disable = @('info_module','status_module','userdir_module','autoindex_module','cgi_module','include_module','dav_module','dav_fs_module','dav_lock_module','imagemap_module','speling_module','asis_module','actions_module','proxy_http_module','proxy_ftp_module','proxy_connect_module','proxy_ajp_module')
    if ($WithPhp) { $enable += @('proxy_module','proxy_fcgi_module','proxy_balancer_module','lbmethod_byrequests_module','slotmem_shm_module') }
    else { $disable += @('proxy_module','proxy_fcgi_module','proxy_balancer_module') }
    foreach ($m in $enable) {
        $rx = '^\s*#?\s*LoadModule\s+' + [regex]::Escape($m) + '\s'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $rx) { $lines[$i] = ($lines[$i] -replace '^\s*#\s*', ''); break }
        }
    }
    foreach ($m in $disable) {
        $rx = '^\s*#?\s*LoadModule\s+' + [regex]::Escape($m) + '\s'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $rx) { $lines[$i] = '#' + ($lines[$i] -replace '^\s*#\s*', ''); break }
        }
    }
    $slashRoot = $ApacheDir.Replace('\', '/')
    $hasDefine = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*Define\s+SRVROOT\s') { $lines[$i] = 'Define SRVROOT "' + $slashRoot + '"'; $hasDefine = $true }
        elseif ($lines[$i] -match '^\s*ServerRoot\s')    { $lines[$i] = 'ServerRoot "' + $slashRoot + '"' }
    }
    if (-not $hasDefine) { [void]$lines.Insert(0, ('Define SRVROOT "' + $slashRoot + '"')) }

    $text = ($lines -join [Environment]::NewLine)
    if ($text -notmatch '(?m)^\s*ServerName\s') { $text += [Environment]::NewLine + 'ServerName localhost:80' }
    $text = $text -replace '(?m)^\s*Include\s+conf/hardening\.conf\s*$', ''
    $text = $text.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + 'Include conf/hardening.conf' + [Environment]::NewLine
    Set-Content -LiteralPath $Conf -Value $text -Encoding ASCII
}

function Write-Automation {
    param([string]$Email, [bool]$WithPhp, [bool]$Staging)
    [IO.File]::WriteAllText($WorkerPs, (Get-Payload 'WORKER'), (New-Object System.Text.UTF8Encoding $true))
    [IO.File]::WriteAllText($SyncPs, (Get-Payload 'SYNC'), (New-Object System.Text.UTF8Encoding $true))
    Set-Content -LiteralPath $HookBat -Encoding ASCII -Value (
        '@echo off' + [Environment]::NewLine +
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $SyncPs + '" -Reload')
    $cfg = [ordered]@{
        SitesRoot   = $SitesDir
        ApacheRoot  = $ApacheDir
        ServiceName = $SvcName
        WacsPath    = (Join-Path $WacsDir 'wacs.exe')
        Email       = $Email
        Staging     = $Staging
        PhpEnabled  = $WithPhp
        AcmeWebRoot = $AcmeRoot
        PemPath     = $PemDir
        CertPath    = $CertDir
        SiteConf    = $SiteConf
        LogPath     = $LogDir
        RenewDays   = 2
        MaxPerRun   = 1
        Timeout     = 600
        Backoff     = @(15, 30, 60, 120, 240, 480, 1440)
        Retention   = 30
    }
    Save-Config -Config $cfg
}

function Register-Automation {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $WorkerPs + '"') -WorkingDirectory $AutoDir
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = $null
    try   { $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest }
    catch { $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM'   -LogonType ServiceAccount -RunLevel Highest }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
}

function Set-Firewall {
    if (Get-Command 'New-NetFirewallRule' -ErrorAction SilentlyContinue) {
        foreach ($p in @(80, 443)) {
            $n = 'Apache HTTP ' + $p
            Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            New-NetFirewallRule -DisplayName $n -Direction Inbound -Protocol TCP -LocalPort $p -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
        }
    } else {
        foreach ($p in @(80, 443)) {
            [void](Invoke-Native -FilePath 'netsh.exe' -Arguments @('advfirewall','firewall','add','rule',('name=Apache HTTP ' + $p),'dir=in','action=allow','protocol=TCP',('localport=' + $p)))
        }
    }
}

function Install-Service {
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($svc) {
        $bin = ''
        try { $bin = [string](Get-CimInstance Win32_Service -Filter ("Name='" + $SvcName + "'")).PathName } catch { }
        if ($bin -notlike ('*' + $Httpd + '*')) {
            [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('stop', $SvcName))
            Start-Sleep -Seconds 2
            Stop-Strays
            [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('delete', $SvcName))
            Start-Sleep -Seconds 2
            $svc = $null
        }
    }
    if (-not $svc) { [void](Invoke-Native -FilePath $Httpd -Arguments @('-k', 'install', '-n', $SvcName)) }
    Set-Service -Name $SvcName -StartupType Automatic -ErrorAction SilentlyContinue
    [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('config', $SvcName, 'obj=', 'NT AUTHORITY\LocalService'))
}

function Start-Apache {
    $t = Invoke-Native -FilePath $Httpd -Arguments @('-t')
    if ($t.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Lines = $t.Lines } }
    try {
        if (Test-ServiceRunning $SvcName) { Restart-Service -Name $SvcName -Force -ErrorAction Stop }
        else { Start-Service -Name $SvcName -ErrorAction Stop }
        Start-Sleep -Seconds 3
    } catch { }
    if (Test-ServiceRunning $SvcName) { return [pscustomobject]@{ Ok = $true; Lines = @() } }

    [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('config', $SvcName, 'obj=', 'LocalSystem'))
    try { Start-Service -Name $SvcName -ErrorAction Stop; Start-Sleep -Seconds 3 } catch { }
    if (Test-ServiceRunning $SvcName) { return [pscustomobject]@{ Ok = $true; Lines = @('running as LocalSystem') } }

    $out = Join-Path $env:TEMP ('aw-probe-' + [Guid]::NewGuid().ToString('N') + '.log')
    $lines = @()
    try {
        $p = Start-Process -FilePath $Httpd -WorkingDirectory (Join-Path $ApacheDir 'bin') -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
        if ($p.WaitForExit(6000)) {
            foreach ($f in @($out, ($out + '.err'))) {
                if (Test-Path -LiteralPath $f) { $lines += @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue) }
            }
        } else {
            try { $p.Kill() } catch { }
            $lines = @('httpd runs in console mode, the service registration is broken')
        }
    } catch { $lines = @($_.Exception.Message) }
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($out + '.err') -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Ok = $false; Lines = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
}

function Set-PhpIni {
    $ini = Join-Path $PhpDir 'php.ini'
    if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) {
        $tpl = Join-Path $PhpDir 'php.ini-production'
        if (Test-Path -LiteralPath $tpl -PathType Leaf) { Copy-Item -LiteralPath $tpl -Destination $ini }
        else { Set-Content -LiteralPath $ini -Value '' -Encoding ASCII }
    }
    $script:iniLines = [System.Collections.ArrayList]@(Get-Content -LiteralPath $ini)
    function Set-Ini {
        param([string]$K, [string]$V)
        $rx = '^\s*;?\s*' + [regex]::Escape($K) + '\s*='
        for ($i = 0; $i -lt $script:iniLines.Count; $i++) {
            if ($script:iniLines[$i] -match $rx) { $script:iniLines[$i] = $K + ' = ' + $V; return }
        }
        [void]$script:iniLines.Add($K + ' = ' + $V)
    }
    Set-Ini 'extension_dir'         ('"' + (Join-Path $PhpDir 'ext') + '"')
    Set-Ini 'cgi.fix_pathinfo'      '0'
    Set-Ini 'cgi.force_redirect'    '0'
    Set-Ini 'fastcgi.impersonate'   '0'
    Set-Ini 'expose_php'            'Off'
    Set-Ini 'display_errors'        'Off'
    Set-Ini 'display_startup_errors' 'Off'
    Set-Ini 'log_errors'            'On'
    Set-Ini 'error_log'             ('"' + (Join-Path $LogDir 'php-error.log') + '"')
    Set-Ini 'allow_url_fopen'       'Off'
    Set-Ini 'allow_url_include'     'Off'
    Set-Ini 'session.save_path'     ('"' + $PhpSess + '"')
    Set-Ini 'upload_tmp_dir'        ('"' + $PhpTmp + '"')
    Set-Ini 'sys_temp_dir'          ('"' + $PhpTmp + '"')
    Set-Ini 'open_basedir'          ('"' + $SitesDir + ';' + $PhpTmp + ';' + $PhpSess + '"')
    Set-Ini 'disable_functions'     'exec,shell_exec,system,passthru,popen,proc_open,proc_close,proc_nice,dl,show_source,highlight_file,php_uname'
    Set-Ini 'enable_dl'             'Off'
    foreach ($e in @('curl','fileinfo','gd','intl','mbstring','openssl','pdo_mysql','mysqli','zip')) {
        $rx = '^\s*;?\s*extension\s*=\s*' + [regex]::Escape($e) + '\s*$'
        $hit = $false
        for ($i = 0; $i -lt $script:iniLines.Count; $i++) {
            if ($script:iniLines[$i] -match $rx) { $script:iniLines[$i] = 'extension=' + $e; $hit = $true; break }
        }
        if (-not $hit) { [void]$script:iniLines.Add('extension=' + $e) }
    }
    Set-Content -LiteralPath $ini -Value $script:iniLines -Encoding ASCII
    [Environment]::SetEnvironmentVariable('PHP_FCGI_MAX_REQUESTS', '0', 'Machine')
}

function Register-PhpWorkers {
    foreach ($t in @(Get-ScheduledTask -TaskName 'PHP-FastCGI-*' -ErrorAction SilentlyContinue)) {
        Stop-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Stop-Strays
    $exe = Join-Path $PhpDir 'php-cgi.exe'
    $principal = $null
    try   { $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount }
    catch { $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount }
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $settings.ExecutionTimeLimit = 'PT0S'
    for ($i = 0; $i -lt $Workers; $i++) {
        $port = 9000 + $i
        $a = New-ScheduledTaskAction -Execute $exe -Argument ('-b 127.0.0.1:' + $port) -WorkingDirectory $PhpDir
        $tr = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName ('PHP-FastCGI-' + $port) -Action $a -Trigger $tr -Settings $settings -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName ('PHP-FastCGI-' + $port)
    }
    Start-Sleep -Seconds 3
}

function Unregister-PhpWorkers {
    foreach ($t in @(Get-ScheduledTask -TaskName 'PHP-FastCGI-*' -ErrorAction SilentlyContinue)) {
        Stop-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if (@(Get-Process -Name 'php-cgi' -ErrorAction SilentlyContinue).Count -gt 0) {
        [void](Invoke-Native -FilePath 'taskkill.exe' -Arguments @('/F', '/T', '/IM', 'php-cgi.exe'))
    }
}

function Invoke-Worker {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $WorkerPs }
    finally { $ErrorActionPreference = $prev }
}

function Get-ServedCertificate {
    param([string]$Domain)
    $client = $null
    $ssl = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(8000)) { throw 'timeout' }
        $client.EndConnect($iar)
        $cb = [System.Net.Security.RemoteCertificateValidationCallback] { param($a, $b, $c, $d) return $true }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $cb)
        $ssl.AuthenticateAsClient($Domain)
        return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
    } finally {
        if ($ssl) { try { $ssl.Dispose() } catch { } }
        if ($client) { try { $client.Close() } catch { } }
    }
}

function Show-Screen {
    param([string]$Title)
    Clear-Host
    Line
    Head 'APACHE FOR WINDOWS'
    if ($Title) { Dim $Title }
    Rule
}

function Show-Status {
    param($S)
    $col = 12
    if ($S.Apache) {
        $state = 'stopped'
        if ($S.Running) { $state = 'running' }
        $txt = 'Apache'.PadRight($col) + $S.Apache.PadRight($col) + $state
        if ($S.Running) { Ok $txt } else { Warn $txt }
    } else {
        Dim ('Apache'.PadRight($col) + 'not installed')
    }
    if ($S.Php) {
        $txt = 'PHP'.PadRight($col) + $S.Php.PadRight($col) + [string]$S.PhpUp + ' of ' + $Workers + ' workers'
        if ($S.PhpUp -eq $Workers) { Ok $txt } else { Warn $txt }
    } else {
        Dim ('PHP'.PadRight($col) + 'not installed')
    }
    if ($S.Domains.Count -eq 0) {
        Dim ('Sites'.PadRight($col) + 'none in ' + $SitesDir)
    } else {
        $txt = 'Sites'.PadRight($col) + ([string]$S.Domains.Count + ' domains').PadRight($col) + [string]$S.WithCert + ' with certificate'
        if ($S.WithCert -eq $S.Domains.Count) { Ok $txt } else { Warn $txt }
    }
    if ($S.Staging) { Bad ('HTTPS'.PadRight($col) + 'TEST certificates - browsers do not trust them') }
    Rule
}

function Do-InstallApache {
    param($S)
    Show-Screen 'install apache'
    if ($S.Apache) {
        if (-not (Ask-Yes ('Apache ' + $S.Apache + ' is installed. Reinstall it?'))) { return }
    }
    try {
        if (-not (Test-VcRuntime)) {
            Dim 'installing the Visual C++ runtime'
            if (-not (Install-VcRuntime)) { Warn 'the Visual C++ runtime could not be installed, Apache may not start' }
        }
        Stop-Strays
        Install-Zip -Url $UrlApache -Target $ApacheDir -TopLevel 'Apache24' -Marker 'bin\httpd.exe' -What 'Apache'
        New-Directories
        $withPhp = (Test-Path -LiteralPath (Join-Path $PhpDir 'php-cgi.exe') -PathType Leaf)
        Set-AllAcls -WithPhp $withPhp
        Write-ApacheConfig -WithPhp $withPhp
        $cfg = Get-Config
        $mail = ''
        $stage = $false
        if ($cfg) { try { $mail = [string]$cfg.Email; $stage = [bool]$cfg.Staging } catch { } }
        Write-Automation -Email $mail -WithPhp $withPhp -Staging $stage
        Set-Firewall
        Install-Service
        Register-Automation
        $r = Start-Apache
        Line
        if ($r.Ok) {
            Ok ('Apache ' + (Get-ApacheVersion) + ' installed and running')
            Dim 'port 80 serves only the ACME challenge and redirects to HTTPS'
        } else {
            Bad 'Apache does not start'
            foreach ($l in $r.Lines) { Dim $l }
        }
    } catch {
        Line
        Bad $_.Exception.Message
    }
    Pause-Key
}

function Do-InstallPhp {
    Show-Screen 'install php'
    if (-not (Test-Path -LiteralPath $Httpd -PathType Leaf)) {
        Bad 'install Apache first'
        Pause-Key
        return
    }
    try {
        Dim 'looking up the current release'
        $url = Resolve-PhpUrl
        Dim ($url.Substring($url.LastIndexOf('/') + 1))
        Install-Zip -Url $url -Target $PhpDir -TopLevel '' -Marker 'php-cgi.exe' -What 'PHP'
        New-Directories
        foreach ($d in @($PhpTmp, $PhpSess)) {
            if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }
        Set-PhpIni
        Set-AllAcls -WithPhp $true
        Write-ApacheConfig -WithPhp $true
        $cfg = Get-Config
        $mail = ''
        $stage = $false
        if ($cfg) { try { $mail = [string]$cfg.Email; $stage = [bool]$cfg.Staging } catch { } }
        Write-Automation -Email $mail -WithPhp $true -Staging $stage
        Register-PhpWorkers
        Invoke-Worker
        $r = Start-Apache
        Line
        $up = Get-WorkersUp
        if ($r.Ok -and $up -eq $Workers) {
            Ok ('PHP ' + (Get-PhpVersion) + ' installed, ' + $up + ' workers running')
        } elseif ($r.Ok) {
            Warn ('PHP ' + (Get-PhpVersion) + ' installed, only ' + $up + ' of ' + $Workers + ' workers came up')
            $probe = Invoke-Native -FilePath (Join-Path $PhpDir 'php-cgi.exe') -Arguments @('-v')
            foreach ($l in @($probe.Lines | Select-Object -First 6)) { Dim $l }
        } else {
            Bad 'Apache does not start'
            foreach ($l in $r.Lines) { Dim $l }
        }
    } catch {
        Line
        Bad $_.Exception.Message
    }
    Pause-Key
}

function Do-RemovePhp {
    Show-Screen 'remove php'
    if (-not (Ask-Yes 'Remove PHP and disable it in Apache?')) { return }
    try {
        Unregister-PhpWorkers
        if (Test-Path -LiteralPath $PhpDir) { Remove-Item -LiteralPath $PhpDir -Recurse -Force -ErrorAction SilentlyContinue }
        [Environment]::SetEnvironmentVariable('PHP_FCGI_MAX_REQUESTS', $null, 'Machine')
        if (Test-Path -LiteralPath $Httpd -PathType Leaf) {
            Write-ApacheConfig -WithPhp $false
            $cfg = Get-Config
            $mail = ''
            $stage = $false
            if ($cfg) { try { $mail = [string]$cfg.Email; $stage = [bool]$cfg.Staging } catch { } }
            Write-Automation -Email $mail -WithPhp $false -Staging $stage
            Invoke-Worker
            $r = Start-Apache
            Line
            if ($r.Ok) { Ok 'PHP removed, Apache serves static files only' }
            else { Bad 'Apache does not start'; foreach ($l in $r.Lines) { Dim $l } }
        } else {
            Line
            Ok 'PHP removed'
        }
    } catch {
        Line
        Bad $_.Exception.Message
    }
    Pause-Key
}

function Do-Https {
    param($S)
    Show-Screen 'enable https'
    if (-not (Test-Path -LiteralPath $Httpd -PathType Leaf)) {
        Bad 'install Apache first'
        Pause-Key
        return
    }
    if ($S.Domains.Count -eq 0) {
        Bad ('no website in ' + $SitesDir)
        Pause-Key
        return
    }
    foreach ($d in $S.Domains) {
        $i = Get-CertInfo -Domain $d
        if ($null -eq $i) { Dim ($d.PadRight(30) + 'no certificate') }
        elseif ($i.Staging) { Warn ($d.PadRight(30) + 'test certificate') }
        else { Ok ($d.PadRight(30) + [string]$i.Days + ' days left') }
    }
    Line
    $mail = Ask 'contact e-mail for Let''s Encrypt' $S.Email
    if ($mail -notmatch '^[^@\s,;]+@[^@\s,;]+\.[A-Za-z]{2,}$') {
        Bad 'not a valid e-mail address'
        Pause-Key
        return
    }
    Line
    Dim 'each domain needs a public DNS record pointing here and port 80 open'
    if (-not (Ask-Yes 'Request certificates now?')) { return }

    try {
        if (-not (Test-Path -LiteralPath (Join-Path $WacsDir 'wacs.exe') -PathType Leaf)) {
            Install-Zip -Url $UrlWacs -Target $WacsDir -TopLevel '' -Marker 'wacs.exe' -What 'win-acme'
            [void](Set-HardenedAcl -Path $WacsDir)
        }
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            $isW = $false
            try { foreach ($a in @($t.Actions)) { if (([string]$a.Execute) -match 'wacs\.exe') { $isW = $true } } } catch { }
            if ($isW) { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
        }
        foreach ($d in $S.Domains) {
            $i = Get-CertInfo -Domain $d
            if ($i -and $i.Staging) {
                Remove-Item -LiteralPath (Join-Path $CertDir ($d + '.*')) -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Join-Path $PemDir ($d + '-*')) -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Join-Path $SiteConf ($d + '.conf')) -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath (Join-Path $AutoDir 'state.json') -Force -ErrorAction SilentlyContinue
        $withPhp = (Test-Path -LiteralPath (Join-Path $PhpDir 'php-cgi.exe') -PathType Leaf)
        Write-Automation -Email $mail -WithPhp $withPhp -Staging $false
        Register-Automation
        [void](Start-Apache)
        Line
        for ($pass = 1; $pass -le ($S.Domains.Count + 1); $pass++) {
            $missing = @($S.Domains | Where-Object { $null -eq (Get-CertInfo -Domain $_) })
            if ($missing.Count -eq 0) { break }
            Invoke-Worker
        }
        Line
        Rule
        foreach ($d in $S.Domains) {
            $served = $null
            try { $served = Get-ServedCertificate -Domain $d } catch { }
            if ($null -eq $served) { Bad ($d.PadRight(30) + 'no TLS answer'); continue }
            if ([string]$served.Issuer -match 'STAGING') { Bad ($d.PadRight(30) + 'test certificate'); continue }
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $chain.ChainPolicy.RevocationMode = 'NoCheck'
            if ($chain.Build($served)) { Ok ($d.PadRight(30) + 'trusted, until ' + $served.NotAfter.ToString('yyyy-MM-dd')) }
            else { Bad ($d.PadRight(30) + 'certificate not trusted') }
        }
    } catch {
        Line
        Bad $_.Exception.Message
    }
    Pause-Key
}

function Do-AddSite {
    Show-Screen 'add website'
    $domain = (Ask 'domain name' '').ToLowerInvariant()
    if (-not (Test-DomainName $domain)) {
        Bad 'not a valid public domain name'
        Pause-Key
        return
    }
    $base = Join-Path $SitesDir $domain
    foreach ($sub in @('www', 'data')) {
        $d = Join-Path $base $sub
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $index = Join-Path $base 'www\index.html'
    if (-not (Test-Path -LiteralPath $index -PathType Leaf)) {
        Set-Content -LiteralPath $index -Encoding ASCII -Value ('<!doctype html><title>' + $domain + '</title><h1>' + $domain + '</h1>')
    }
    Grant-Access -Path $base -Rights 'RX'
    Line
    Ok (Join-Path $base 'www')
    Dim (Join-Path $base 'data')
    Line
    Dim 'point the DNS A record here, then use [3] to get a certificate'
    Pause-Key
}

function Do-Service {
    Show-Screen 'apache service'
    Dim '1 start   2 stop   3 restart   0 back'
    Line
    $c = Read-Host '  >'
    try {
        if ($c -eq '1') { Start-Service -Name $SvcName -ErrorAction Stop }
        elseif ($c -eq '2') { Stop-Service -Name $SvcName -Force -ErrorAction Stop }
        elseif ($c -eq '3') { $r = Start-Apache; if (-not $r.Ok) { foreach ($l in $r.Lines) { Dim $l } } }
        else { return }
        Start-Sleep -Seconds 2
        Line
        if (Test-ServiceRunning $SvcName) { Ok 'running' } else { Warn 'stopped' }
    } catch {
        Line
        Bad $_.Exception.Message
    }
    Pause-Key
}

function Do-RemoveAll {
    Show-Screen 'remove everything'
    Dim 'Apache, PHP, win-acme, all certificates, tasks and firewall rules'
    Dim ($SitesDir + ' and your websites are kept')
    Line
    if (-not (Ask-Yes 'Remove everything?')) { return }
    Unregister-PhpWorkers
    foreach ($n in @($TaskName, 'IIS-HTTPS-AutoProvision')) {
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $isW = $false
        try { foreach ($a in @($t.Actions)) { if (([string]$a.Execute) -match 'wacs\.exe') { $isW = $true } } } catch { }
        if ($isW) { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
    }
    foreach ($sv in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Apache*' })) {
        if ($sv.Status -ne 'Stopped') { Stop-Service -Name $sv.Name -Force -ErrorAction SilentlyContinue }
        [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('delete', $sv.Name))
    }
    Stop-Strays
    foreach ($d in @($ApacheDir, $PhpDir, $WacsDir, $AutoDir, (Join-Path $env:ProgramData 'win-acme'), 'C:\inetpub\automated')) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        for ($i = 1; $i -le 3; $i++) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $d)) { break }
            Start-Sleep -Seconds 2
        }
    }
    if (Get-Command 'Remove-NetFirewallRule' -ErrorAction SilentlyContinue) {
        foreach ($n in @('Apache HTTP 80', 'Apache HTTP 443')) {
            Remove-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue
        }
    }
    [Environment]::SetEnvironmentVariable('PHP_FCGI_MAX_REQUESTS', $null, 'Machine')
    Line
    $left = @()
    foreach ($d in @($ApacheDir, $PhpDir, $WacsDir, $AutoDir)) { if (Test-Path -LiteralPath $d) { $left += $d } }
    if ($left.Count -eq 0) { Ok 'removed' }
    else { Warn 'these are locked, reboot and run again:'; foreach ($l in $left) { Dim $l } }
    Pause-Key
}

function Do-Logs {
    Show-Screen 'logs'
    $today = Join-Path $LogDir ('provision-' + (Get-Date -Format 'yyyyMMdd') + '.log')
    if (Test-Path -LiteralPath $today -PathType Leaf) {
        foreach ($l in @(Get-Content -LiteralPath $today -Tail 18 -ErrorAction SilentlyContinue)) { Dim $l }
    } else {
        Dim 'no provisioning log today'
    }
    Line
    $err = Join-Path $ApacheDir 'logs\error.log'
    if (Test-Path -LiteralPath $err -PathType Leaf) {
        foreach ($l in @(Get-Content -LiteralPath $err -Tail 8 -ErrorAction SilentlyContinue)) { Dim $l }
    }
    Line
    if (Test-Path -LiteralPath $LogDir -PathType Container) { Start-Process -FilePath 'explorer.exe' -ArgumentList $LogDir }
    Pause-Key
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator rights are required.' -ForegroundColor Red
    exit 1
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host 'PowerShell 5.1 or newer is required.' -ForegroundColor Red
    exit 1
}
$Host.UI.RawUI.WindowTitle = 'Apache for Windows'

while ($true) {
    $S = Get-State
    Show-Screen ''
    Show-Status -S $S
    $phpItem = '2  Install PHP'
    if ($S.Php) { $phpItem = '2  Remove PHP' }
    $apacheItem = '1  Install Apache'
    if ($S.Apache) { $apacheItem = '1  Reinstall Apache' }
    Head ($apacheItem.PadRight(28) + '5  Apache service')
    Head ($phpItem.PadRight(28)    + '6  Logs')
    Head ('3  Enable HTTPS'.PadRight(28) + '7  Remove everything')
    Head ('4  Add website'.PadRight(28) + '0  Exit')
    Rule
    $choice = Read-Host '  >'
    switch (([string]$choice).Trim()) {
        '1' { Do-InstallApache -S $S }
        '2' { if ($S.Php) { Do-RemovePhp } else { Do-InstallPhp } }
        '3' { Do-Https -S $S }
        '4' { Do-AddSite }
        '5' { Do-Service }
        '6' { Do-Logs }
        '7' { Do-RemoveAll }
        '0' { Clear-Host; exit 0 }
    }
}
#@AW_MAIN_END@

#@AW_SYNC_BEGIN@
[CmdletBinding()]
param([string]$ConfigPath, [switch]$Reload)
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $out = & $FilePath @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Lines = @($out | ForEach-Object { [string]$_ }) }
    } finally { $ErrorActionPreference = $prev }
}

$base = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($base) -and $MyInvocation.MyCommand.Path) { $base = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $base 'config.json' }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$pemPath  = [string]$cfg.PemPath
$certPath = [string]$cfg.CertPath
$logPath  = [string]$cfg.LogPath
$logFile  = Join-Path $logPath ('sync-' + (Get-Date -Format 'yyyyMMdd') + '.log')

function Write-SyncLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
}

function Get-PemKind {
    param([string]$Path)
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $null }
    if ($text -match '-----BEGIN [A-Z ]*PRIVATE KEY-----') { return 'key' }
    $n = ([regex]::Matches($text, '-----BEGIN CERTIFICATE-----')).Count
    if ($n -gt 0) { return 'cert:' + $n }
    return $null
}

$domains = @(Get-ChildItem -LiteralPath ([string]$cfg.SitesRoot) -Directory -ErrorAction SilentlyContinue |
             ForEach-Object { $_.Name.ToLowerInvariant() } |
             Where-Object { $_ -match '^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$' })

$changed = $false
foreach ($domain in $domains) {
    $rx = '^' + [regex]::Escape($domain) + '-(crt|key|chain|chain-only)\.pem$'
    $files = @(Get-ChildItem -LiteralPath $pemPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $rx })
    if ($files.Count -eq 0) { continue }
    $key = $null
    $cert = $null
    $best = 0
    foreach ($f in $files) {
        $kind = Get-PemKind -Path $f.FullName
        if ($kind -eq 'key') {
            if ($f.Name -ieq ($domain + '-key.pem')) { $key = $f.FullName }
            continue
        }
        if ($kind -and $kind.StartsWith('cert:')) {
            $n = [int]$kind.Substring(5)
            if ($n -gt $best) { $best = $n; $cert = $f.FullName }
        }
    }
    if (-not $key -or -not $cert) { continue }
    $touched = $false
    foreach ($pair in @(@($cert, (Join-Path $certPath ($domain + '.crt.pem'))), @($key, (Join-Path $certPath ($domain + '.key.pem'))))) {
        $srcHash = (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash
        $dstHash = ''
        if (Test-Path -LiteralPath $pair[1] -PathType Leaf) { $dstHash = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash }
        if ($srcHash -ne $dstHash) {
            Copy-Item -LiteralPath $pair[0] -Destination $pair[1] -Force
            $touched = $true
            $changed = $true
        }
    }
    if ($touched) { Write-SyncLog ('[' + $domain + '] certificate updated') }
}

if ($changed -and $Reload) {
    $httpd = Join-Path ([string]$cfg.ApacheRoot) 'bin\httpd.exe'
    $t = Invoke-Native -FilePath $httpd -Arguments @('-t')
    if ($t.ExitCode -ne 0) {
        Write-SyncLog ('config test failed, not reloading: ' + ($t.Lines -join ' | '))
        exit 1
    }
    $r = Invoke-Native -FilePath $httpd -Arguments @('-k', 'restart', '-n', ([string]$cfg.ServiceName))
    if ($r.ExitCode -ne 0) { Restart-Service -Name ([string]$cfg.ServiceName) -Force }
    Write-SyncLog 'apache reloaded'
}
exit 0
#@AW_SYNC_END@

#@AW_WORKER_BEGIN@
[CmdletBinding()]
param([string]$ConfigPath)
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:LogFile = $null
$script:ExitCode = 0

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $out = & $FilePath @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Lines = @($out | ForEach-Object { [string]$_ }) }
    } finally { $ErrorActionPreference = $prev }
}

function Write-Log {
    param([ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO', [string]$Message = '')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) {
        for ($i = 0; $i -lt 3; $i++) {
            try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8; break } catch { Start-Sleep -Milliseconds 150 }
        }
    }
}

function Cfg {
    param($Config, [string]$Name, $Default)
    $p = $Config.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Entry {
    param($E, [string]$Name, $Default)
    if ($null -eq $E) { return $Default }
    $p = $E.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Quote-Arg {
    param([string]$Value)
    if ($Value -match '[\s"]') { return ('"' + ($Value -replace '"', '\"') + '"') }
    return $Value
}

function Test-DomainName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 253) { return $false }
    if ($Name -notmatch '^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$') { return $false }
    $labels = $Name.Split('.')
    $tld = $labels[$labels.Count - 1]
    if ($tld -notmatch '^([a-z]{2,63}|xn--[a-z0-9-]{2,59})$') { return $false }
    return (@('local','localhost','localdomain','test','invalid','example','internal','intranet','home','lan','corp') -notcontains $tld)
}

function Test-DomainResolvable {
    param([string]$Domain)
    if (Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue) {
        try {
            $r = @(Resolve-DnsName -Name $Domain -Type A_AAAA -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' -or $_.Type -eq 'AAAA' })
            if ($r.Count -gt 0) { return $true }
        } catch { }
    }
    try { return (@([System.Net.Dns]::GetHostAddresses($Domain)).Count -gt 0) } catch { return $false }
}

function Test-ChallengeServed {
    param([string]$Domain)
    $token = 'preflight-' + [Guid]::NewGuid().ToString('N')
    $dir = Join-Path $script:AcmeRoot '.well-known\acme-challenge'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir $token
    Set-Content -LiteralPath $file -Value $token -Encoding ASCII
    try {
        $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1/.well-known/acme-challenge/' + $token)
        $req.Host = $Domain
        $req.Timeout = 10000
        $req.AllowAutoRedirect = $false
        $resp = $req.GetResponse()
        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        $body = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()
        return ($body.Trim() -eq $token)
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Get-CertificateStatus {
    param([string]$Domain)
    $crt = Join-Path $script:CertPath ($Domain + '.crt.pem')
    $key = Join-Path $script:CertPath ($Domain + '.key.pem')
    if (-not (Test-Path -LiteralPath $crt -PathType Leaf)) { return $null }
    if (-not (Test-Path -LiteralPath $key -PathType Leaf)) { return $null }
    try { $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($crt) } catch { return $null }
    $names = $c.Subject
    foreach ($ext in $c.Extensions) { if ($ext.Oid.Value -eq '2.5.29.17') { $names = $names + ' ' + $ext.Format($false) } }
    return [pscustomobject]@{
        Days    = [int][math]::Floor(($c.NotAfter - (Get-Date)).TotalDays)
        Matches = ($names -match ('(^|[=,\s])' + [regex]::Escape($Domain) + '($|[,\s])'))
    }
}

function Test-CertUsable {
    param($Status)
    if ($null -eq $Status) { return $false }
    if (-not $Status.Matches) { return $false }
    return ($Status.Days -gt $script:RenewDays)
}

function Get-VhostBody {
    param([string]$Domain, [string]$Path)
    $root = (Join-Path $Path 'www').Replace('\', '/')
    $certs = $script:CertPath.Replace('\', '/')
    $logs = $script:LogPath.Replace('\', '/')
    $php = ''
    if ($script:PhpEnabled) {
        $php = @'

    DirectoryIndex index.php index.html index.htm
    <FilesMatch "\.php$">
        SetHandler "proxy:balancer://phpfcgi/"
    </FilesMatch>
'@
    }
    return @"
<VirtualHost *:443>
    ServerName $Domain
    DocumentRoot "$root"

    SSLEngine on
    SSLCertificateFile    "$certs/$Domain.crt.pem"
    SSLCertificateKeyFile "$certs/$Domain.key.pem"

    <IfModule headers_module>
        Header always set Strict-Transport-Security "max-age=31536000"
    </IfModule>
$php
    <Directory "$root">
        AllowOverride None
        Options -Indexes -Includes -ExecCGI -FollowSymLinks
        Require all granted
    </Directory>

    ErrorLog  "$logs/$Domain-error.log"
    CustomLog "$logs/$Domain-access.log" combined
</VirtualHost>
"@
}

function Test-ApacheConfig {
    $r = Invoke-Native -FilePath $script:Httpd -Arguments @('-t')
    return [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Output = ($r.Lines -join ' | ') }
}

function Restart-Apache {
    $r = Invoke-Native -FilePath $script:Httpd -Arguments @('-k', 'restart', '-n', $script:ServiceName)
    if ($r.ExitCode -ne 0) { Restart-Service -Name $script:ServiceName -Force }
}

function Get-LogTail {
    param([string]$Path, [int]$Count = 20)
    try {
        return @(Get-Content -LiteralPath $Path -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last $Count)
    } catch { return @() }
}

function Invoke-WinAcme {
    param([string]$Domain)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outLog = Join-Path $script:LogPath ('wacs-' + $Domain + '-' + $stamp + '.out.log')
    $errLog = Join-Path $script:LogPath ('wacs-' + $Domain + '-' + $stamp + '.err.log')
    $wacsArgs = @(
        '--accepttos',
        '--emailaddress', $script:Email,
        '--source', 'manual',
        '--host', $Domain,
        '--validation', 'filesystem',
        '--webroot', $script:AcmeRoot,
        '--store', 'pemfiles',
        '--pemfilespath', $script:PemPath,
        '--pemfilesname', $Domain,
        '--installation', 'script',
        '--script', (Join-Path $script:BaseDir 'apply-certificates.bat'),
        '--usedefaulttaskuser'
    )
    if ($script:Staging) { $wacsArgs += @('--baseuri', 'https://acme-staging-v02.api.letsencrypt.org/') }
    $line = (($wacsArgs | ForEach-Object { Quote-Arg $_ }) -join ' ')
    Write-Log INFO ('[' + $Domain + '] win-acme')
    $p = Start-Process -FilePath $script:WacsPath -ArgumentList $line -WorkingDirectory (Split-Path -Parent $script:WacsPath) -NoNewWindow -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    if (-not $p.WaitForExit($script:Timeout * 1000)) {
        try { $p.Kill() } catch { }
        throw ('win-acme timed out after ' + $script:Timeout + ' seconds')
    }
    return $outLog
}

function Read-State {
    $state = @{}
    if (Test-Path -LiteralPath $script:StatePath -PathType Leaf) {
        try {
            $o = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch { }
    }
    return $state
}

function Save-State {
    param($State)
    try {
        $tmp = $script:StatePath + '.tmp'
        ($State | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force
    } catch { }
}

function Set-Failure {
    param($State, [string]$Domain, [string]$Message)
    $n = [int](Entry $State[$Domain] 'Failures' 0) + 1
    $minutes = [int]$script:Backoff[[Math]::Min($n - 1, $script:Backoff.Count - 1)]
    $next = (Get-Date).ToUniversalTime().AddMinutes($minutes)
    $State[$Domain] = [pscustomobject]@{
        Failures = $n
        LastError = $Message
        NextAttemptUtc = $next.ToString('o')
    }
    Save-State -State $State
    return $next
}

function Invoke-Provision {
    param([string]$Domain, [string]$Path)
    $status = Get-CertificateStatus -Domain $Domain
    if (-not (Test-CertUsable -Status $status)) {
        Write-Log INFO ('[' + $Domain + '] requesting a certificate')
        if (-not (Test-DomainResolvable -Domain $Domain)) { throw ('no public DNS record for ' + $Domain) }
        if (-not (Test-ChallengeServed -Domain $Domain)) { throw 'the ACME challenge path is not served on port 80' }
        $outLog = Invoke-WinAcme -Domain $Domain
        $sync = Invoke-Native -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:BaseDir 'Sync-Certificates.ps1'), '-Reload')
        if ($sync.ExitCode -ne 0) { Write-Log WARN ('[' + $Domain + '] sync returned ' + $sync.ExitCode) }
        $status = Get-CertificateStatus -Domain $Domain
        if ($null -eq $status -or -not $status.Matches -or $status.Days -le 0) {
            foreach ($t in (Get-LogTail -Path $outLog -Count 20)) { Write-Log ERROR ('[' + $Domain + '] ' + $t) }
            throw ('no usable certificate for ' + $Domain)
        }
        Write-Log INFO ('[' + $Domain + '] certificate valid for ' + $status.Days + ' days')
    }
    foreach ($sub in @('www', 'data')) {
        $d = Join-Path $Path $sub
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $vhostFile = Join-Path $script:SiteConf ($Domain + '.conf')
    $wanted = Get-VhostBody -Domain $Domain -Path $Path
    $current = ''
    if (Test-Path -LiteralPath $vhostFile -PathType Leaf) { $current = [IO.File]::ReadAllText($vhostFile) }
    if ($current.Trim() -ne $wanted.Trim()) {
        $had = (-not [string]::IsNullOrEmpty($current))
        Set-Content -LiteralPath $vhostFile -Value $wanted -Encoding ASCII
        $t = Test-ApacheConfig
        if (-not $t.Ok) {
            if ($had) { Set-Content -LiteralPath $vhostFile -Value $current -Encoding ASCII }
            else { Remove-Item -LiteralPath $vhostFile -Force -ErrorAction SilentlyContinue }
            throw ('apache rejected the vhost: ' + $t.Output)
        }
        Restart-Apache
        Write-Log INFO ('[' + $Domain + '] vhost written')
    }
}

function Invoke-Run {
    if (-not (Test-Path -LiteralPath $script:SitesRoot -PathType Container)) { throw ('missing ' + $script:SitesRoot) }
    if (-not (Test-Path -LiteralPath $script:Httpd -PathType Leaf)) { throw ('missing ' + $script:Httpd) }
    if (-not (Test-Path -LiteralPath $script:WacsPath -PathType Leaf)) { throw ('missing ' + $script:WacsPath) }

    $state = Read-State
    $now = (Get-Date).ToUniversalTime()
    $folders = @(Get-ChildItem -LiteralPath $script:SitesRoot -Directory -ErrorAction Stop)
    $names = New-Object System.Collections.ArrayList
    $pending = New-Object System.Collections.ArrayList
    $todo = New-Object System.Collections.ArrayList
    $ready = 0
    $deferred = 0
    $done = 0
    $failed = 0

    foreach ($f in $folders) {
        $domain = $f.Name.ToLowerInvariant()
        if (-not (Test-DomainName $domain)) { continue }
        [void]$names.Add($domain)
        if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) { continue }
        $vhost = Join-Path $script:SiteConf ($domain + '.conf')
        $certOk = Test-CertUsable -Status (Get-CertificateStatus -Domain $domain)
        if ($certOk -and (Test-Path -LiteralPath $vhost -PathType Leaf)) { $ready++; continue }
        [void]$pending.Add($domain)
        if (-not $certOk) {
            $next = [datetime]::MinValue
            $raw = Entry $state[$domain] 'NextAttemptUtc' $null
            if ($raw) {
                try { $next = [datetime]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) } catch { }
            }
            if ($next -gt $now) { $deferred++; continue }
        }
        [void]$todo.Add([pscustomobject]@{ Domain = $domain; Path = $f.FullName; NeedsCert = (-not $certOk) })
    }

    $spent = 0
    foreach ($item in @($todo)) {
        if ($item.NeedsCert -and $spent -ge $script:MaxPerRun) { continue }
        if ($item.NeedsCert) { $spent++ }
        try {
            Invoke-Provision -Domain $item.Domain -Path $item.Path
            if ($state.ContainsKey($item.Domain)) { [void]$state.Remove($item.Domain) }
            $done++
        } catch {
            $msg = $_.Exception.Message
            $next = Set-Failure -State $state -Domain $item.Domain -Message $msg
            Write-Log ERROR ('[' + $item.Domain + '] ' + $msg + ' | retry ' + $next.ToString('HH:mm') + ' UTC')
            $failed++
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $script:SiteConf -File -Filter '*.conf' -ErrorAction SilentlyContinue)) {
        if ($file.Name -like '00-*') { continue }
        $name = [IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant()
        if ($names -notcontains $name) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            Write-Log INFO ('[' + $name + '] removed, folder is gone')
            try { if ((Test-ApacheConfig).Ok) { Restart-Apache } } catch { }
        }
    }

    foreach ($k in @($state.Keys)) { if ($pending -notcontains $k) { [void]$state.Remove($k) } }
    Save-State -State $state
    Write-Log INFO ('done: sites=' + $names.Count + ' ok=' + $ready + ' waiting=' + $deferred + ' new=' + $done + ' failed=' + $failed)
}

$script:BaseDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:BaseDir) -and $MyInvocation.MyCommand.Path) { $script:BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($script:BaseDir)) { exit 2 }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $script:BaseDir 'config.json' }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { exit 2 }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$script:SitesRoot   = [string](Cfg $cfg 'SitesRoot' 'C:\htdocs')
$script:ApacheRoot  = [string](Cfg $cfg 'ApacheRoot' 'C:\Apache24')
$script:ServiceName = [string](Cfg $cfg 'ServiceName' 'Apache2.4')
$script:WacsPath    = [string](Cfg $cfg 'WacsPath' '')
$script:Email       = [string](Cfg $cfg 'Email' '')
$script:Staging     = [bool]  (Cfg $cfg 'Staging' $false)
$script:PhpEnabled  = [bool]  (Cfg $cfg 'PhpEnabled' $false)
$script:AcmeRoot    = [string](Cfg $cfg 'AcmeWebRoot' '')
$script:PemPath     = [string](Cfg $cfg 'PemPath' '')
$script:CertPath    = [string](Cfg $cfg 'CertPath' '')
$script:SiteConf    = [string](Cfg $cfg 'SiteConf' '')
$script:LogPath     = [string](Cfg $cfg 'LogPath' '')
$script:RenewDays   = [int]   (Cfg $cfg 'RenewDays' 2)
$script:MaxPerRun   = [int]   (Cfg $cfg 'MaxPerRun' 1)
$script:Timeout     = [int]   (Cfg $cfg 'Timeout' 600)
$script:Retention   = [int]   (Cfg $cfg 'Retention' 30)
$script:Backoff     = @(Cfg $cfg 'Backoff' @(15, 30, 60, 120, 240, 480, 1440))
if ($script:Backoff.Count -eq 0) { $script:Backoff = @(15) }
if ($script:MaxPerRun -lt 1) { $script:MaxPerRun = 1 }
if ($script:Timeout -lt 60) { $script:Timeout = 60 }
$script:Httpd = Join-Path $script:ApacheRoot 'bin\httpd.exe'
$script:StatePath = Join-Path $script:BaseDir 'state.json'

if (-not (Test-Path -LiteralPath $script:LogPath -PathType Container)) { New-Item -ItemType Directory -Path $script:LogPath -Force | Out-Null }
$script:LogFile = Join-Path $script:LogPath ('provision-' + (Get-Date -Format 'yyyyMMdd') + '.log')

$mutex = $null
$owned = $false
try { $mutex = New-Object System.Threading.Mutex($false, 'Global\Apache-HTTPS-AutoProvision') } catch { $mutex = $null }
if ($mutex) {
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }
}
try {
    Invoke-Run
    if ($script:Retention -gt 0) {
        $limit = (Get-Date).AddDays(-$script:Retention)
        Get-ChildItem -LiteralPath $script:LogPath -File -Filter 'wacs-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Log ERROR $_.Exception.Message
    $script:ExitCode = 1
} finally {
    if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
    if ($mutex) { $mutex.Dispose() }
}
exit $script:ExitCode
#@AW_WORKER_END@
