@echo off
setlocal EnableExtensions
REM ============================================================
REM  github-gitea-sync-gui.bat  -  ALLES-IN-EINEM
REM  Grafisches Tool: spiegelt ein GitHub-Repo nach Gitea.
REM  - Quelle und Ziel auswaehlbar (Repos per Knopf laden)
REM  - Anmeldung im Fenster: Gitea via Benutzer+Passwort (erstellt
REM    automatisch einen API-Token) oder direkt per Token.
REM    GitHub optional per Token (nur fuer private Repos noetig).
REM  - Zwei Modi: ZIP-Snapshot (1 frischer Commit) oder Mirror
REM    (komplette Historie, alle Branches+Tags). Beides Force-Push.
REM  Der PowerShell-Teil ist unten eingebettet (nach dem Marker).
REM  Bedienung: einfach doppelklicken. Keine Admin-Rechte noetig.
REM ============================================================

set "PS1=%TEMP%\gh2gitea-gui-%RANDOM%%RANDOM%.ps1"
set "start="
for /f "delims=:" %%a in ('findstr /n /b /c:"#@@@GUI_PS_PAYLOAD@@@" "%~f0"') do set "start=%%a"
if not defined start (
    echo [FEHLER] PowerShell-Marker in der Datei nicht gefunden.
    pause & exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%~f0' | Select-Object -Skip %start% | Set-Content -LiteralPath '%PS1%' -Encoding UTF8"
if not exist "%PS1%" (
    echo [FEHLER] Konnte Payload nicht entpacken.
    pause & exit /b 1
)
start "" powershell -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "%PS1%"
exit /b 0

#@@@GUI_PS_PAYLOAD@@@
<#  GitHub -> Gitea Sync GUI - wird von der .bat extrahiert und gestartet.  #>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$env:GIT_TERMINAL_PROMPT = '0'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function P([int]$x,[int]$y){ [System.Drawing.Point]::new($x,$y) }
function S([int]$w,[int]$h){ [System.Drawing.Size]::new($w,$h) }
function NewLabel([string]$text,[int]$x,[int]$y,[int]$w){
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = P $x $y; $l.Size = S $w 18
    $l
}
function NewText([int]$x,[int]$y,[int]$w,[string]$def,[bool]$mask){
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = P $x $y; $t.Size = S $w 24; $t.Text = $def
    if($mask){ $t.UseSystemPasswordChar = $true }
    $t
}
function NewBtn([string]$text,[int]$x,[int]$y,[int]$w,[int]$h){
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = P $x $y; $b.Size = S $w $h
    $b
}

# ---------- Formular ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'GitHub -> Gitea Sync'
$form.ClientSize = S 622 748
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

# --- Quelle (GitHub) ---
$grpSrc = New-Object System.Windows.Forms.GroupBox
$grpSrc.Text = 'Quelle (GitHub)'
$grpSrc.Location = P 10 10; $grpSrc.Size = S 602 158

$lblGhUser   = NewLabel 'Benutzer/Org:' 15 30 130
$txtGhUser   = NewText 150 27 200 'florianthepro' $false
$btnGhLoad   = NewBtn 'Repos laden' 472 25 115 26
$lblGhTok    = NewLabel 'Token (optional):' 15 62 130
$txtGhTok    = NewText 150 59 300 '' $true
$lnkGhTok    = New-Object System.Windows.Forms.LinkLabel
$lnkGhTok.Text = 'Token erstellen'; $lnkGhTok.Location = P 472 62; $lnkGhTok.Size = S 115 18
$lblSrcRepo  = NewLabel 'Repo (owner/name):' 15 94 130
$cmbSrc      = New-Object System.Windows.Forms.ComboBox
$cmbSrc.Location = P 150 91; $cmbSrc.Size = S 300 24; $cmbSrc.Text = 'florianthepro/pages'
$lblSrcBr    = NewLabel 'Branch:' 15 126 130
$txtSrcBr    = NewText 150 123 120 'main' $false
$grpSrc.Controls.AddRange(@($lblGhUser,$txtGhUser,$btnGhLoad,$lblGhTok,$txtGhTok,$lnkGhTok,$lblSrcRepo,$cmbSrc,$lblSrcBr,$txtSrcBr))

# --- Ziel (Gitea) ---
$grpDst = New-Object System.Windows.Forms.GroupBox
$grpDst.Text = 'Ziel (Gitea)'
$grpDst.Location = P 10 176; $grpDst.Size = S 602 224

$lblGtUrl  = NewLabel 'Gitea URL:' 15 30 130
$txtGtUrl  = NewText 150 27 300 'https://gitea.getitsec.com' $false
$lblGtUser = NewLabel 'Benutzer:' 15 62 130
$txtGtUser = NewText 150 59 120 'florianthepro' $false
$lblGtPass = NewLabel 'Passwort:' 285 62 65
$txtGtPass = NewText 352 59 120 '' $true
$btnLogin  = NewBtn 'Anmelden' 490 57 97 26
$lblGtTok  = NewLabel 'oder Token:' 15 94 130
$txtGtTok  = NewText 150 91 300 '' $true
$lnkGtTok  = New-Object System.Windows.Forms.LinkLabel
$lnkGtTok.Text = 'Token-Seite'; $lnkGtTok.Location = P 472 94; $lnkGtTok.Size = S 115 18
$lblDstRepo = NewLabel 'Repo (owner/name):' 15 126 130
$cmbDst     = New-Object System.Windows.Forms.ComboBox
$cmbDst.Location = P 150 123; $cmbDst.Size = S 300 24; $cmbDst.Text = 'florianthepro/p2'
$btnGtLoad  = NewBtn 'Repos laden' 472 121 115 26
$lblDstBr   = NewLabel 'Branch:' 15 158 130
$txtDstBr   = NewText 150 155 120 'main' $false
$chkCreate  = New-Object System.Windows.Forms.CheckBox
$chkCreate.Text = 'Ziel-Repo automatisch anlegen, falls es fehlt (privat)'
$chkCreate.Location = P 150 188; $chkCreate.Size = S 420 20; $chkCreate.Checked = $true
$grpDst.Controls.AddRange(@($lblGtUrl,$txtGtUrl,$lblGtUser,$txtGtUser,$lblGtPass,$txtGtPass,$btnLogin,$lblGtTok,$txtGtTok,$lnkGtTok,$lblDstRepo,$cmbDst,$btnGtLoad,$lblDstBr,$txtDstBr,$chkCreate))

# --- Modus ---
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = 'Modus'
$grpMode.Location = P 10 408; $grpMode.Size = S 602 74
$rbSnap = New-Object System.Windows.Forms.RadioButton
$rbSnap.Text = 'ZIP-Snapshot: 1 frischer Commit, ersetzt den Ziel-Branch (Force)'
$rbSnap.Location = P 15 22; $rbSnap.Size = S 570 20; $rbSnap.Checked = $true
$rbMirror = New-Object System.Windows.Forms.RadioButton
$rbMirror.Text = 'Mirror: komplette Historie, alle Branches + Tags (Force, Branch-Felder egal)'
$rbMirror.Location = P 15 46; $rbMirror.Size = S 570 20
$grpMode.Controls.AddRange(@($rbSnap,$rbMirror))

# --- Start / Log / Status ---
$btnStart = NewBtn 'Sync starten' 10 492 602 36
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = P 10 538; $txtLog.Size = S 602 178
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
$txtLog.Font = New-Object System.Drawing.Font('Consolas',8.5)
$lblStatus = NewLabel 'Bereit.' 10 722 602

$form.Controls.AddRange(@($grpSrc,$grpDst,$grpMode,$btnStart,$txtLog,$lblStatus))

# ---------- Hilfsfunktionen ----------
function MaskSecrets([string]$s){
    foreach($sec in @($txtGhTok.Text,$txtGtTok.Text,$txtGtPass.Text)){
        if($sec -and $sec.Length -ge 4){ $s = $s.Replace($sec,'***') }
    }
    $s
}
function Log([string]$m){
    $txtLog.AppendText((MaskSecrets $m) + [Environment]::NewLine)
    [System.Windows.Forms.Application]::DoEvents()
}
function SetStatus([string]$m){ $lblStatus.Text = MaskSecrets $m; [System.Windows.Forms.Application]::DoEvents() }
function MsgErr([string]$m){ [void][System.Windows.Forms.MessageBox]::Show($form,$m,'GitHub -> Gitea Sync','OK','Warning') }
function Run-Git([string[]]$gitArgs,[string]$step){
    Log ('  > git ' + (($gitArgs | Where-Object { $_ -notmatch '^(user\.(name|email)=|credential\.helper=|init\.defaultBranch=)' }) -join ' '))
    $out = & git @gitArgs 2>&1
    foreach($l in @($out)){ if("$l".Trim()){ Log ('    ' + $l) } }
    if($LASTEXITCODE -ne 0){ throw ('git fehlgeschlagen bei Schritt: ' + $step) }
}
function GiteaBase(){ ($txtGtUrl.Text.Trim().TrimEnd('/')) }
function GhHeaders(){
    $h = @{ Accept = 'application/vnd.github+json' }
    if($txtGhTok.Text.Trim()){ $h['Authorization'] = 'token ' + $txtGhTok.Text.Trim() }
    $h
}
function GtTokenHeaders(){ @{ Authorization = 'token ' + $txtGtTok.Text.Trim() } }
function HttpStatus($err){
    try { return [int]$err.Exception.Response.StatusCode } catch { return 0 }
}
function Do-GiteaLogin(){
    $u = $txtGtUser.Text.Trim(); $p = $txtGtPass.Text
    if(-not $u -or -not $p){ MsgErr 'Bitte Gitea-Benutzer und Passwort eingeben (oder direkt einen Token eintragen).'; return $false }
    $pair  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u + ':' + $p))
    $basic = @{ Authorization = 'Basic ' + $pair }
    try {
        $me = Invoke-RestMethod -Uri ((GiteaBase) + '/api/v1/user') -Headers $basic
        $body = @{ name = 'gh2gitea-' + (Get-Date -Format 'yyyyMMddHHmmss'); scopes = @('read:repository','write:repository','read:user') } | ConvertTo-Json
        $tok = Invoke-RestMethod -Method Post -Uri ((GiteaBase) + '/api/v1/users/' + $me.login + '/tokens') -Headers $basic -Body $body -ContentType 'application/json'
        $txtGtTok.Text = $tok.sha1
        $txtGtPass.Text = ''
        SetStatus ('Angemeldet als ' + $me.login + ' - Token wurde erstellt.')
        Log ('[OK] Gitea-Login als ' + $me.login + ', API-Token erstellt (nur im Speicher).')
        return $true
    } catch {
        $code = HttpStatus $_
        if($code -eq 401){ Log '[FEHLER] Gitea-Login abgelehnt (401). Passwort falsch? Bei aktivierter 2FA bitte direkt einen Token eintragen.' }
        else { Log ('[FEHLER] Gitea-Login: ' + $_.Exception.Message) }
        return $false
    }
}
function Ensure-DstRepo([string]$dst){
    $hdr = GtTokenHeaders
    try {
        [void](Invoke-RestMethod -Uri ((GiteaBase) + '/api/v1/repos/' + $dst) -Headers $hdr)
        Log ('[i] Ziel-Repo ' + $dst + ' existiert.')
        return
    } catch {
        if((HttpStatus $_) -ne 404){ throw }
    }
    if(-not $chkCreate.Checked){ throw ('Ziel-Repo ' + $dst + ' existiert nicht (automatisches Anlegen ist deaktiviert).') }
    $owner,$name = $dst.Split('/',2)
    $me = Invoke-RestMethod -Uri ((GiteaBase) + '/api/v1/user') -Headers $hdr
    $body = @{ name = $name; private = $true; auto_init = $false } | ConvertTo-Json
    if($owner -ieq $me.login){ $uri = (GiteaBase) + '/api/v1/user/repos' }
    else { $uri = (GiteaBase) + '/api/v1/orgs/' + $owner + '/repos' }
    [void](Invoke-RestMethod -Method Post -Uri $uri -Headers $hdr -Body $body -ContentType 'application/json')
    Log ('[OK] Ziel-Repo ' + $dst + ' angelegt (privat).')
}

# ---------- Events ----------
$lnkGhTok.Add_LinkClicked({ Start-Process 'https://github.com/settings/tokens/new?scopes=repo&description=gh2gitea-sync' })
$lnkGtTok.Add_LinkClicked({ Start-Process ((GiteaBase) + '/user/settings/applications') })
$rbSnap.Add_CheckedChanged({ $txtSrcBr.Enabled = $rbSnap.Checked; $txtDstBr.Enabled = $rbSnap.Checked })

$btnGhLoad.Add_Click({
    try {
        SetStatus 'Lade GitHub-Repos ...'
        if($txtGhTok.Text.Trim()){ $uri = 'https://api.github.com/user/repos?per_page=100&sort=updated' }
        else {
            $u = $txtGhUser.Text.Trim()
            if(-not $u){ MsgErr 'Bitte GitHub-Benutzer/Org eintragen.'; SetStatus 'Bereit.'; return }
            $uri = 'https://api.github.com/users/' + $u + '/repos?per_page=100&sort=updated'
        }
        $repos = Invoke-RestMethod -Uri $uri -Headers (GhHeaders)
        $cmbSrc.Items.Clear()
        foreach($r in @($repos)){ [void]$cmbSrc.Items.Add($r.full_name) }
        if($cmbSrc.Items.Count -gt 0 -and -not $cmbSrc.Text){ $cmbSrc.SelectedIndex = 0 }
        Log ('[OK] ' + $cmbSrc.Items.Count + ' GitHub-Repos geladen.')
        SetStatus 'Bereit.'
    } catch { Log ('[FEHLER] GitHub-Repos laden: ' + $_.Exception.Message); SetStatus 'Bereit.' }
})

$btnLogin.Add_Click({ [void](Do-GiteaLogin) })

$btnGtLoad.Add_Click({
    try {
        if(-not $txtGtTok.Text.Trim()){
            if(-not (Do-GiteaLogin)){ return }
        }
        SetStatus 'Lade Gitea-Repos ...'
        $r = Invoke-RestMethod -Uri ((GiteaBase) + '/api/v1/repos/search?limit=50') -Headers (GtTokenHeaders)
        $cmbDst.Items.Clear()
        foreach($it in @($r.data)){ [void]$cmbDst.Items.Add($it.full_name) }
        Log ('[OK] ' + $cmbDst.Items.Count + ' Gitea-Repos geladen.')
        SetStatus 'Bereit.'
    } catch { Log ('[FEHLER] Gitea-Repos laden: ' + $_.Exception.Message); SetStatus 'Bereit.' }
})

$btnStart.Add_Click({
    $src = $cmbSrc.Text.Trim(); $dst = $cmbDst.Text.Trim()
    $srcBr = $txtSrcBr.Text.Trim(); $dstBr = $txtDstBr.Text.Trim()
    if($src -notmatch '^[^/\s]+/[^/\s]+$'){ MsgErr 'Quelle bitte als owner/name angeben, z.B. florianthepro/pages'; return }
    if($dst -notmatch '^[^/\s]+/[^/\s]+$'){ MsgErr 'Ziel bitte als owner/name angeben, z.B. florianthepro/p2'; return }
    if($rbSnap.Checked -and (-not $srcBr -or -not $dstBr)){ MsgErr 'Bitte Quell- und Ziel-Branch angeben.'; return }
    if(-not $txtGtTok.Text.Trim()){
        if(-not (Do-GiteaLogin)){ MsgErr 'Ohne Gitea-Token oder Login geht es nicht weiter.'; return }
    }
    if(-not (Get-Command git -ErrorAction SilentlyContinue)){ MsgErr 'git wurde nicht gefunden. Bitte Git for Windows installieren.'; return }

    $btnStart.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $work = Join-Path $env:TEMP ('gh2gitea-gui-' + [guid]::NewGuid().ToString('N'))
    try {
        SetStatus 'Sync laeuft ...'
        Log ('=== Start: ' + $src + ' -> ' + $dst + ' (' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ') ===')
        Ensure-DstRepo $dst

        [void](New-Item -ItemType Directory -Path $work)
        $uri = [Uri](GiteaBase)
        $gtUserEnc = [Uri]::EscapeDataString($txtGtUser.Text.Trim())
        $pushUrl = '{0}://{1}:{2}@{3}{4}/{5}.git' -f $uri.Scheme,$gtUserEnc,$txtGtTok.Text.Trim(),$uri.Authority,$uri.AbsolutePath.TrimEnd('/'),$dst

        if($rbSnap.Checked){
            $zip = Join-Path $work 'src.zip'
            Log ('[i] Lade ZIP von GitHub (' + $src + '@' + $srcBr + ') ...')
            Invoke-WebRequest -UseBasicParsing -Uri ('https://api.github.com/repos/' + $src + '/zipball/' + $srcBr) -Headers (GhHeaders) -OutFile $zip
            Log '[i] Entpacke ...'
            Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x')
            $srcDir = Get-ChildItem -LiteralPath (Join-Path $work 'x') -Directory | Select-Object -First 1
            if(-not $srcDir){ throw 'Kein Ordner im ZIP gefunden.' }
            $d = $srcDir.FullName
            Log ('[i] Erzeuge frisches Repo im entpackten Ordner (Inhalt = Repo-Root, kein Wrapper-Ordner).')
            Run-Git @('-C',$d,'-c','init.defaultBranch=main','init','-q') 'init'
            Run-Git @('-C',$d,'add','-A','-f','.') 'add'
            Run-Git @('-C',$d,'-c','user.name=github-sync','-c','user.email=sync@gh2gitea.local','commit','-q','-m',('Sync von GitHub ' + $src + '@' + $srcBr + ' (' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ')')) 'commit'
            Log ('[i] Force-Push nach ' + (GiteaBase) + '/' + $dst + ' (Branch ' + $dstBr + ') ...')
            Run-Git @('-C',$d,'-c','credential.helper=','push','--force',$pushUrl,('HEAD:refs/heads/' + $dstBr)) 'push'
        } else {
            if($txtGhTok.Text.Trim()){ $srcUrl = 'https://git:' + $txtGhTok.Text.Trim() + '@github.com/' + $src + '.git' }
            else { $srcUrl = 'https://github.com/' + $src + '.git' }
            $bare = Join-Path $work 'bare'
            Log ('[i] Klone komplette Historie von GitHub (' + $src + ') ...')
            Run-Git @('-c','credential.helper=','clone','--bare','-q',$srcUrl,$bare) 'clone'
            Log ('[i] Force-Push aller Branches und Tags nach ' + (GiteaBase) + '/' + $dst + ' ...')
            Run-Git @('-C',$bare,'-c','credential.helper=','push','--force',$pushUrl,'refs/heads/*:refs/heads/*','refs/tags/*:refs/tags/*') 'push'
        }
        Log ('[OK] Fertig: ' + (GiteaBase) + '/' + $dst)
        SetStatus 'Fertig.'
    } catch {
        Log ('[FEHLER] ' + $_.Exception.Message)
        SetStatus 'Fehler - Details siehe Log.'
    } finally {
        try {
            if(Test-Path -LiteralPath $work){
                Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
                if(Test-Path -LiteralPath $work){ & cmd /c rd /s /q "$work" 2>$null }
            }
        } catch { }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnStart.Enabled = $true
    }
})

[void]$form.ShowDialog()
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
