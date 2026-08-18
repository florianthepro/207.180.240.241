@echo off
:: ============================================================================
:: setup-v2.bat  -  Apache + PHP (FastCGI) Reparatur / Konvergenz-Werkzeug
:: AW-SCRIPT v2.0 setup-v2
::
:: Jederzeit ausfuehrbar. Erkennt den Ist-Zustand, aendert nur die Differenz.
:: Jede Datei wird vor Aenderung gesichert; danach "httpd -t"; schlaegt der
:: Test fehl, werden ALLE Aenderungen automatisch zurueckgerollt.
:: Domains in ignore.json (neben dieser .bat) werden nie angefasst.
::
:: Aufruf:
::   setup-v2.bat            Menue
::   setup-v2.bat /check     nur pruefen, NICHTS aendern  (Exit 0 = ok, 1 = Abweichung)
::   setup-v2.bat /repair    pruefen + reparieren ohne Rueckfrage
:: ============================================================================
setlocal EnableExtensions DisableDelayedExpansion
set "AW_SELF=%~f0"
set "AW_DIR=%~dp0"
set "AW_MODE=%~1"

fltmc >nul 2>&1
if not errorlevel 1 goto run
if /i "%~1"=="--elevated" (
  echo [x] Administratorrechte konnten nicht erlangt werden.
  pause & exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { Start-Process -FilePath $env:AW_SELF -ArgumentList @('--elevated', $env:AW_MODE) -WorkingDirectory $env:AW_DIR -Verb RunAs } catch { Write-Host ('Elevation abgebrochen: ' + $_.Exception.Message) -ForegroundColor Red; Start-Sleep 4 }"
exit /b 0

:run
if /i "%~1"=="--elevated" set "AW_MODE=%~2"
set "AW_TMP=%TEMP%\awv2-%RANDOM%%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -Command "$ErrorActionPreference='Stop'; $a='#@AW_'+'MAIN_BEGIN@'; $b='#@AW_'+'MAIN_END@'; $c=[IO.File]::ReadAllText($env:AW_SELF); $s=$c.IndexOf($a); if($s -lt 0){exit 3}; $s+=$a.Length; $e=$c.IndexOf($b,$s); if($e -lt 0){exit 3}; $t=$c.Substring($s,$e-$s); if($t.Length -lt 200){exit 3}; [IO.File]::WriteAllText($env:AW_TMP,$t,(New-Object System.Text.UTF8Encoding $true)); exit 0"
if not "%ERRORLEVEL%"=="0" goto broken
if not exist "%AW_TMP%" goto broken
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AW_TMP%" -Mode "%AW_MODE%" -Self "%AW_SELF%" -Dir "%AW_DIR%"
set "RC=%ERRORLEVEL%"
del /f /q "%AW_TMP%" >nul 2>&1
endlocal & exit /b %RC%

:broken
echo [x] Eingebetteter PowerShell-Block konnte nicht entpackt werden.
pause
endlocal & exit /b 1

#@AW_MAIN_BEGIN@
param([string]$Mode = '', [string]$Self = '', [string]$Dir = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --------------------------------------------------------------------- Ausgabe
function Line($t){ Write-Host $t }
function Head($t){ Write-Host ''; Write-Host ('=== ' + $t + ' ===') -ForegroundColor Cyan }
function Ok  ($t){ Write-Host ('  [+] ' + $t) -ForegroundColor Green }
function Bad ($t){ Write-Host ('  [x] ' + $t) -ForegroundColor Red }
function Warn($t){ Write-Host ('  [!] ' + $t) -ForegroundColor Yellow }
function Info($t){ Write-Host ('  [i] ' + $t) }
function Skip($t){ Write-Host ('  [-] ' + $t) -ForegroundColor DarkGray }

# externe Programme sicher aufrufen (stderr darf das Script nicht abbrechen)
function Invoke-Native([string]$FilePath, [string[]]$Arguments){
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try   { $out = & $FilePath @Arguments 2>&1; $code = $LASTEXITCODE }
  catch { $out = "$_"; $code = 1 }
  finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = [int]$code; Text = ($out | Out-String) }
}

$script:CheckOnly = ($Mode -match '(?i)^[/-]{0,2}check$')
$script:AutoRepair = ($Mode -match '(?i)^[/-]{0,2}repair$')
$script:Changed = @{}          # Pfad -> Backup, fuer Rollback
$script:Findings = 0

# --------------------------------------------------------------- Umgebung finden
function Find-Apache {
  foreach($c in @('C:\Apache24','C:\Apache2','C:\xampp\apache')){
    if(Test-Path (Join-Path $c 'bin\httpd.exe')){ return $c }
  }
  $w = Get-Command httpd.exe -ErrorAction SilentlyContinue
  if($w){ return (Split-Path (Split-Path $w.Source)) }
  return $null
}
function Find-Php([string]$apache){
  $w = Get-Command php.exe -ErrorAction SilentlyContinue
  if($w){ return (Split-Path $w.Source) }
  foreach($c in @('C:\php','C:\php8','C:\xampp\php')){ if(Test-Path (Join-Path $c 'php.exe')){ return $c } }
  return $null
}

# ----------------------------------------------------------------- ignore.json
function Get-IgnoreList([string]$dir){
  $p = Join-Path $dir 'ignore.json'
  $res = [pscustomobject]@{ Path = $p; Exact = @{}; Suffix = @(); Status = 'missing'; Raw = @() }
  if(-not (Test-Path $p)){
    if(-not $script:CheckOnly){
      $tpl = '{' + "`r`n" + '  "hinweis": "Domains hier eintragen - diese vHosts werden nie geaendert.",' + "`r`n" + '  "ignore": []' + "`r`n" + '}' + "`r`n"
      try{ Set-Content -LiteralPath $p -Value $tpl -Encoding UTF8; Info "ignore.json angelegt (leer): $p" }catch{}
    }
    return $res
  }
  try{
    $j = Get-Content -Raw -LiteralPath $p | ConvertFrom-Json
    $list = @()
    if($j -is [array]){ $list = @($j) }
    elseif($j -and ($j.PSObject.Properties.Name -contains 'ignore')){ $list = @($j.ignore) }
    foreach($d in $list){
      if(-not $d){ continue }
      $s = ("$d").Trim().ToLower(); if($s -eq ''){ continue }
      $res.Raw += $s
      if($s.StartsWith('*.')){ $res.Suffix += $s.Substring(1) }   # *.a.com -> .a.com
      else{ $res.Exact[$s] = $true }
    }
    $res.Status = 'ok'
  }catch{
    $res.Status = 'broken'; $res.Error = $_.Exception.Message
  }
  return $res
}
function Test-Ignored([string]$domain, $ign){
  if(-not $domain){ return $false }
  $d = $domain.ToLower()
  if($ign.Exact.ContainsKey($d)){ return $true }
  foreach($suf in $ign.Suffix){ if($d.EndsWith($suf)){ return $true } }
  return $false
}

# ------------------------------------------------------- Backup / Schreiben / Rollback
function Backup-File([string]$path){
  if($script:Changed.ContainsKey($path)){ return }
  $bak = $path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item -LiteralPath $path -Destination $bak -Force
  $script:Changed[$path] = $bak
}
function Write-Fixed([string]$path, [string]$content){
  Backup-File $path
  Set-Content -LiteralPath $path -Value $content -NoNewline -Encoding Default
}
function Rollback-All {
  foreach($k in @($script:Changed.Keys)){
    try{ Copy-Item -LiteralPath $script:Changed[$k] -Destination $k -Force }catch{}
  }
}

# ------------------------------------------------------------- Kern: Handler-Fix
# der bewiesene Bug - Trailing-Slash im Balancer-Ziel:
#   falsch:  SetHandler "proxy:balancer://phpfcgi/"
#   richtig: SetHandler "proxy:balancer://phpfcgi"
# Der Slash laesst Apache SCRIPT_FILENAME mit fuehrendem Extra-Slash senden
# (unter Windows /C:/htdocs/... ), worauf php-cgi mit "No input file specified" antwortet.
function Repair-HandlerText([string]$text){
  $n = 0
  $rx1 = '(?im)^(\s*SetHandler\s+)"proxy:balancer://phpfcgi/+"\s*$'
  $rx2 = "(?im)^(\s*SetHandler\s+)'proxy:balancer://phpfcgi/+'\s*`$"
  $rx3 = '(?im)^(\s*SetHandler\s+)proxy:balancer://phpfcgi/+\s*$'
  foreach($rx in @($rx1,$rx2,$rx3)){
    $m = [regex]::Matches($text,$rx); if($m.Count -gt 0){ $n += $m.Count }
  }
  $text = [regex]::Replace($text,$rx1,'$1"proxy:balancer://phpfcgi"')
  $text = [regex]::Replace($text,$rx2,'$1"proxy:balancer://phpfcgi"')
  $text = [regex]::Replace($text,$rx3,'$1"proxy:balancer://phpfcgi"')
  return [pscustomobject]@{ Text = $text; Count = $n }
}

# ============================================================================ MAIN
Head 'setup-v2 : Apache/PHP pruefen und reparieren'
if($script:CheckOnly){ Warn 'Modus /check - es wird NICHTS geaendert.' }
elseif($script:AutoRepair){ Info 'Modus /repair - reparieren ohne Rueckfrage.' }

$apache = Find-Apache
if(-not $apache){ Bad 'Apache nicht gefunden.'; exit 3 }
$httpd = Join-Path $apache 'bin\httpd.exe'
$phpDir = Find-Php $apache
Ok "Apache : $apache"
if($phpDir){ Ok "PHP    : $phpDir" } else { Warn 'PHP-Verzeichnis nicht gefunden.' }

$ign = Get-IgnoreList $Dir
switch($ign.Status){
  'ok'      { Ok ("ignore.json: " + $ign.Raw.Count + " Eintrag(e): " + ($ign.Raw -join ', ')) }
  'missing' { Info 'ignore.json: keine (nichts wird uebersprungen)' }
  'broken'  { Bad ("ignore.json ist ungueltiges JSON: " + $ign.Error); Bad 'Abbruch - bitte JSON reparieren.'; exit 3 }
}

# ---------------------------------------------------------------- 1) vHosts / Handler-Bug
Head '1) vHosts (SetHandler-Korrektur)'
$siteDirs = @((Join-Path $apache 'conf\sites'),(Join-Path $apache 'conf\extra'),(Join-Path $apache 'conf'))
$confs = @()
foreach($d in $siteDirs){ if(Test-Path $d){ $confs += Get-ChildItem -LiteralPath $d -Filter *.conf -File -ErrorAction SilentlyContinue } }
$confs = $confs | Sort-Object FullName -Unique
foreach($f in $confs){
  $txt = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
  if([string]::IsNullOrEmpty($txt)){ continue }
  if($txt -notmatch '(?i)phpfcgi'){ continue }
  $name = ''
  $mn = [regex]::Match($txt,'(?im)^\s*ServerName\s+(\S+)'); if($mn.Success){ $name = $mn.Groups[1].Value }
  if(-not $name){ $name = $f.BaseName }
  if((Test-Ignored $name $ign) -or (Test-Ignored $f.BaseName $ign)){ Skip "$name  (ignore.json)"; continue }
  $r = Repair-HandlerText $txt
  if($r.Count -gt 0){
    $script:Findings++
    if($script:CheckOnly){ Warn "$name  : fehlerhafter SetHandler mit Slash (wuerde korrigiert, $($r.Count)x)" }
    else{ Write-Fixed $f.FullName $r.Text; Ok "$name  : SetHandler korrigiert ($($r.Count)x, Backup angelegt)" }
  }else{
    Ok "$name  : Handler ok"
  }
}
if($confs.Count -eq 0){ Info 'keine .conf gefunden' }

# ---------------------------------------------------------------- 2) php.ini
Head '2) php.ini'
if($phpDir){
  $ini = $null
  $probe = Invoke-Native (Join-Path $phpDir 'php.exe') @('--ini')
  $mi = [regex]::Match($probe.Text,'(?im)^Loaded Configuration File:\s*(.+)$')
  if($mi.Success){ $v = $mi.Groups[1].Value.Trim(); if($v -notmatch '^\(none\)$' -and (Test-Path $v)){ $ini = $v } }
  if(-not $ini){ $c = Join-Path $phpDir 'php.ini'; if(Test-Path $c){ $ini = $c } }
  if(-not $ini){ Warn 'keine php.ini gefunden' }
  else{
    Info "Datei: $ini"
    $content = Get-Content -Raw -LiteralPath $ini
    $iniChanges = @()
    # WICHTIG: bei FastCGI mit explizitem SCRIPT_FILENAME MUSS cgi.fix_pathinfo=0 bleiben.
    $wants = @{ 'cgi.fix_pathinfo' = '0'; 'cgi.force_redirect' = '0'; 'fastcgi.impersonate' = '0' }
    if(Test-Path (Join-Path $phpDir 'ext')){ $wants['extension_dir'] = '"' + (Join-Path $phpDir 'ext') + '"' }
    foreach($k in $wants.Keys){
      $val = $wants[$k]
      $rx = '(?m)^\s*;?\s*' + [regex]::Escape($k) + '\s*=.*$'
      $cur = [regex]::Match($content,$rx)
      if($cur.Success){
        $line = $cur.Value.Trim()
        if($line -ne ($k + '=' + $val) -and $line -ne ($k + ' = ' + $val)){
          $content = [regex]::Replace($content,$rx,($k + '=' + $val),1)
          $iniChanges += ($k + ' : ' + $line + ' -> ' + $k + '=' + $val)
        }
      }else{
        $content = $content.TrimEnd() + "`r`n" + $k + '=' + $val + "`r`n"
        $iniChanges += ($k + ' : fehlte -> ' + $k + '=' + $val)
      }
    }
    if($iniChanges.Count -eq 0){ Ok 'php.ini bereits korrekt' }
    elseif($script:CheckOnly){ $script:Findings += $iniChanges.Count; foreach($c in $iniChanges){ Warn "wuerde setzen: $c" } }
    else{ $script:Findings += $iniChanges.Count; Write-Fixed $ini $content; Ok 'php.ini angepasst:'; foreach($c in $iniChanges){ Line "        $c" } }
  }
}else{ Skip 'uebersprungen (kein PHP)' }

# ---------------------------------------------------------------- 3) FastCGI-Worker-Tasks
Head '3) PHP-FastCGI Worker (Scheduled Tasks)'
$tasks = @(Get-ScheduledTask -TaskName 'PHP-FastCGI-*' -ErrorAction SilentlyContinue)
$phpCgi = if($phpDir){ Join-Path $phpDir 'php-cgi.exe' } else { $null }
if($tasks.Count -eq 0){
  Warn 'keine PHP-FastCGI-* Tasks vorhanden'
  $script:Findings++
  if(-not $script:CheckOnly -and $phpCgi -and (Test-Path $phpCgi)){
    try{
      $principal = $null
      try   { $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount }
      catch { $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount }
      $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
      $settings.ExecutionTimeLimit = 'PT0S'
      for($i=0; $i -lt 4; $i++){
        $port = 9000 + $i
        $a = New-ScheduledTaskAction -Execute $phpCgi -Argument ('-b 127.0.0.1:' + $port) -WorkingDirectory $phpDir
        $tr = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName ('PHP-FastCGI-' + $port) -Action $a -Trigger $tr -Settings $settings -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName ('PHP-FastCGI-' + $port)
      }
      Ok '4 Worker-Tasks (9000-9003) neu registriert und gestartet'
    }catch{ Bad ("Worker-Registrierung fehlgeschlagen: " + $_.Exception.Message) }
  }
}else{
  foreach($t in ($tasks | Sort-Object TaskName)){
    $st = 'unbekannt'
    try{ $st = (Get-ScheduledTask -TaskName $t.TaskName).State }catch{}
    if("$st" -ne 'Running'){
      Warn ($t.TaskName + " : Status " + $st)
      $script:Findings++
      if(-not $script:CheckOnly){ try{ Start-ScheduledTask -TaskName $t.TaskName; Ok ($t.TaskName + ' gestartet') }catch{ Bad ($t.TaskName + ' Start fehlgeschlagen') } }
    }else{ Ok ($t.TaskName + ' laeuft') }
  }
}

# ---------------------------------------------------------------- 4) Automations-Scripte pruefen
Head '4) Automations-Scripte (Marker/Version)'
$autoDir = 'C:\apache-automation'
if(Test-Path $autoDir){
  $scripts = Get-ChildItem -LiteralPath $autoDir -Filter *.ps1 -File -ErrorAction SilentlyContinue
  foreach($s in $scripts){
    $head = (Get-Content -LiteralPath $s.FullName -TotalCount 5 -ErrorAction SilentlyContinue) -join "`n"
    $hasIgnore = ($head -match '(?i)ignore\.json') -or ((Get-Content -Raw -LiteralPath $s.FullName -ErrorAction SilentlyContinue) -match '(?i)Test-Ignored|ignore\.json')
    if($hasIgnore){ Ok ($s.Name + ' : ignore.json-Unterstuetzung vorhanden') }
    else{ Warn ($s.Name + ' : KEINE ignore.json-Unterstuetzung (veraltet)'); $script:Findings++ }
  }
  if($scripts.Count -eq 0){ Info 'keine .ps1 im Automations-Ordner' }
  Info 'Hinweis: veraltete Automations-Scripte werden von diesem Repair-Tool nicht neu geschrieben (nur gemeldet).'
}else{ Info 'kein C:\apache-automation - uebersprungen' }

# ---------------------------------------------------------------- 5) Apache testen + neu
Head '5) Apache'
if($script:CheckOnly){
  Info 'Modus /check beendet.'
  if($script:Findings -gt 0){ Warn ("$($script:Findings) Abweichung(en) gefunden - mit /repair beheben."); exit 1 }
  Ok 'alles konform.'; exit 0
}

if($script:Changed.Count -gt 0){
  Info 'Konfiguration pruefen (httpd -t) ...'
  $t = Invoke-Native $httpd @('-t')
  if($t.ExitCode -ne 0){
    Bad 'httpd -t FEHLGESCHLAGEN - alle Aenderungen werden zurueckgerollt.'
    Line $t.Text
    Rollback-All
    Ok 'Rollback abgeschlossen - Stand wie vorher.'
    exit 2
  }
  Ok ($t.Text.Trim())
  Info 'Apache neu starten ...'
  $svc = Get-Service -Name 'Apache*' -ErrorAction SilentlyContinue | Select-Object -First 1
  if($svc){ Restart-Service -Name $svc.Name -Force; Ok ("Dienst '" + $svc.Name + "' neu gestartet.") }
  else{ Invoke-Native $httpd @('-k','restart') | Out-Null; Ok 'httpd -k restart ausgefuehrt.' }
}else{
  Info 'keine Konfigurationsdatei geaendert - kein Neustart noetig.'
}

# ---------------------------------------------------------------- 6) Selbsttest
Head '6) Selbsttest (php-cgi direkt)'
if($phpCgi -and (Test-Path $phpCgi)){
  $probe = Join-Path $env:TEMP 'awv2_probe.php'
  Set-Content -LiteralPath $probe -Value '<?php echo "OK-PHP";' -Encoding ASCII
  $env:REDIRECT_STATUS = '200'; $env:REQUEST_METHOD = 'GET'
  $env:SCRIPT_FILENAME = $phpCgi; $env:PATH_TRANSLATED = $probe
  $res = Invoke-Native $phpCgi @()
  Remove-Item Env:REDIRECT_STATUS,Env:REQUEST_METHOD,Env:SCRIPT_FILENAME,Env:PATH_TRANSLATED -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $probe -ErrorAction SilentlyContinue
  if($res.Text -match 'OK-PHP'){ Ok 'php-cgi liefert Inhalt - PHP funktioniert.' }
  elseif($res.Text -match 'No input file specified'){ Bad 'php-cgi meldet weiterhin "No input file specified".' }
  else{ Warn ('unerwartete Ausgabe: ' + (($res.Text -replace "`r?`n",' ').Trim())) }
}else{ Skip 'php-cgi.exe nicht gefunden' }

# ---------------------------------------------------------------- Abschluss
Head 'Zusammenfassung'
if($script:Changed.Count -eq 0){ Info 'keine Datei veraendert' }
else{
  Ok ("$($script:Changed.Count) Datei(en) geaendert (Backups mit .bak-Zeitstempel):")
  foreach($k in $script:Changed.Keys){ Line "        $k" }
}
Line ''
Line 'Test im Browser (danach loeschen):  https://getitsec.com/  bzw.  /index.php'
Ok 'fertig.'
exit 0
#@AW_MAIN_END@
