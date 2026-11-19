#Requires -Version 5.1
<#
.SYNOPSIS
  Strip ads, AI assistant, online stickers, PDF tools, games, pet and self-updaters
  from Sogou Pinyin IME on Windows while keeping plain pinyin input working.

.DESCRIPTION
  Dry run by default: prints what would change. Pass -Apply to change things.
  Needs an elevated (Administrator) PowerShell for -Apply.
  Idempotent: run it again after a reboot to finish steps that were blocked by
  DLLs still loaded in running programs.

  Nothing here patches a binary. See docs/how-it-works.md for the launch chain.

.PARAMETER Apply
  Actually make the changes.

.PARAMETER RemoveVoice
  Also neutralize SGSmartAssistant.exe (toolbox). Voice input lives there, so it is kept by default.

.PARAMETER RemoveKaomoji
  Also neutralize SGKaomoji.exe (local emoticon panel, no network). Kept by default.

.PARAMETER NoCloud
  Also disable cloud candidates (EnableCloudRequest=0). Cloud input is kept by default.

.PARAMETER ShowComponents
  Only decrypt and print the component table (id / enable / forceenable), then exit.

.PARAMETER BootEnvIni
  Internal. Used by the one-shot startup task that -Apply registers: edits env.ini under
  -ProfilePath before anyone logs on, then removes the task.

.EXAMPLE
  .\SogouDebloat.ps1                 # dry run
  .\SogouDebloat.ps1 -Apply          # do it
  .\SogouDebloat.ps1 -ShowComponents
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$RemoveVoice,
    [switch]$RemoveKaomoji,
    [switch]$NoCloud,
    [switch]$ShowComponents,
    [switch]$BootEnvIni,
    [string]$ProfilePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ---------------------------------------------------------------- constants
# AES-256-CBC key/IV that SogouComMgr.exe uses for Components\ComponentConfig.ini
$CfgKey = $null  # removed from history: derived at run time since v1.1.0
$CfgIV  = $null  # removed from history

# component bundles to stop loading (bundle id in ComponentConfig.ini -> folder under Components)
$OffBundles = [ordered]@{
    'IChatComBundle'      = 'IChat'        # AI assistant 'Wangzai' (+ Tencent file indexer)
    'ISGPetComBundle'     = 'isgpet'       # desktop pet
    'GameCenterComBundle' = 'game_center'  # game center
    'PicFaceComBundle'    = 'PicFace'      # online stickers / picture emoji
    'BizCenterComBundle'  = $null          # ads, toast, PDF, context menu (folder kept: SogouCloud may load libamssdk.dll from it)
    'BizPDFComBundle'     = 'biz_pdf'
}

$ShellExtClsids = @('{7BCE96FA-77AF-4288-9E16-2388A50EC807}', '{85212cfd-77ed-4add-8e24-a0a39e3dbfc3}')
$ToastActivator = '{1BB732FA-391B-4648-BC00-8AECA408C065}'

# HKCU\Software\SogouInput.store.user switches. Missing means ON, so they are written as 0.
$StoreOff = 'ichatenable','status_pop_switch','systoast_enable','pdf_enable','petautorun',
            'gamecenterenable','writespiritenable','wizardpromotion'

# env.ini [Setting] values, and the ones to drop from [SyncMode] so account sync cannot restore them
$EnvSet = [ordered]@{
    AutoUpdate = '2'; CandWangzaiSwitch = '0'; CandWangzaiIconSwitch = '0'; HintWangzaiComp = '0'
    EnableWangzaiGuideWnd = '0'; EnableAiPicComp = '0'; EnableImePop = '0'; EnableStatusSkinPop = '0'
    EnableAdsDispatch = '0'; EnablePetAutoRun = '0'; AppBoxShow = '0'
}
if ($NoCloud) { $EnvSet['EnableCloudRequest'] = '0' }

# ---------------------------------------------------------------- helpers
$script:Changes = 0
function Say([string]$tag, [string]$msg) {
    $color = @{ DO = 'Yellow'; OK = 'Green'; SKIP = 'DarkGray'; WARN = 'Magenta'; FAIL = 'Red' }[$tag]
    Write-Host ('[{0,-4}] {1}' -f $tag, $msg) -ForegroundColor $color
}
function Act([string]$msg, [scriptblock]$do) {
    $script:Changes++
    if (-not $Apply) { Say 'DO' "(dry) $msg"; return }
    try { $r = & $do; if (@($r) -notcontains 'warned') { Say 'OK' $msg } } catch { Say 'FAIL' "$msg :: $($_.Exception.Message)" }
}

function Get-SogouRoot {
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $base) { continue }
        $r = Join-Path $base 'SogouInput'
        if (Test-Path -LiteralPath (Join-Path $r 'Components')) { return $r }
    }
    throw 'Sogou Pinyin is not installed (no SogouInput\Components under Program Files).'
}
function Get-SogouVersionDir([string]$root) {
    $d = Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+){3}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'SGTool.exe')) } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $d) { throw "No version directory with SGTool.exe under $root." }
    $d.FullName
}

function Invoke-Aes([byte[]]$data, [bool]$encrypt) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $CfgKey; $aes.IV = $CfgIV
    $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
    $t = if ($encrypt) { $aes.CreateEncryptor() } else { $aes.CreateDecryptor() }
    try { $t.TransformFinalBlock($data, 0, $data.Length) } finally { $t.Dispose(); $aes.Dispose() }
}
# plaintext = 16 random bytes + ini text. Edited as Latin-1 so every byte round-trips untouched.
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
function Read-ComponentConfig([string]$path) {
    $pt = Invoke-Aes ([Convert]::FromBase64String(([IO.File]::ReadAllText($path)).Trim())) $false
    [pscustomobject]@{ Prefix = $pt[0..15]; Text = $Latin1.GetString($pt, 16, $pt.Length - 16) }
}
function Write-ComponentConfig([string]$path, $cfg) {
    $body = $Latin1.GetBytes($cfg.Text)
    $pt = New-Object byte[] (16 + $body.Length)
    [Array]::Copy([byte[]]$cfg.Prefix, 0, $pt, 0, 16); [Array]::Copy($body, 0, $pt, 16, $body.Length)
    $blob = [Convert]::ToBase64String((Invoke-Aes $pt $true))
    [IO.File]::WriteAllText($path, $blob, $Latin1)
    $check = Read-ComponentConfig $path
    if ($check.Text -ne $cfg.Text) { throw 'ComponentConfig.ini did not read back identically.' }
}
function Get-ComponentTable([string]$text) {
    $rows = @{}; $sec = $null; $isCom = $false
    foreach ($ln in ($text -split "`n")) {
        $s = $ln.Trim()
        if ($s -match '^\[(bundle\d+)(com\d+)?\]$') { $sec = $Matches[1]; if (-not $rows[$sec]) { $rows[$sec] = [ordered]@{ section = $sec; id = ''; forceenable = ''; enable = '' } }; $isCom = [bool]$Matches[2]; continue }
        if ($s -match '^\[') { $sec = $null; continue }
        if (-not $sec) { continue }
        if (-not $isCom -and $s -match '^id=(.*)$') { $rows[$sec].id = $Matches[1] }
        elseif (-not $isCom -and $s -match '^forceenable=(.*)$') { $rows[$sec].forceenable = $Matches[1] }
        elseif ($isCom -and $s -match '^enable=(.*)$') { $rows[$sec].enable = $Matches[1] }
    }
    $rows.Values | ForEach-Object { [pscustomobject]$_ } | Sort-Object { [int]($_.section -replace '\D', '') }
}
function Set-ComponentOff([string]$text, [string[]]$bundleSections) {
    $out = New-Object System.Collections.Generic.List[string]; $sec = $null; $isCom = $false
    foreach ($ln in ($text -split "`n")) {
        $s = $ln.Trim()
        if ($s -match '^\[(bundle\d+)(com\d+)?\]$') { $sec = $Matches[1]; $isCom = [bool]$Matches[2] }
        elseif ($s -match '^\[') { $sec = $null }
        if ($sec -and $bundleSections -contains $sec) {
            if ($isCom -and $s -match '^enable=') { $ln = $ln -replace 'enable=\S*', 'enable=0' }
            elseif (-not $isCom -and $s -match '^forceenable=') { $ln = $ln -replace 'forceenable=\S*', 'forceenable=0' }
        }
        $out.Add($ln)
    }
    $out -join "`n"
}

# env.ini is UTF-16LE with BOM. Returns the list of changes; writes only when $write.
function Update-EnvIni([string]$path, [bool]$write) {
    $raw = [IO.File]::ReadAllBytes($path)
    if ($raw.Length -lt 2 -or $raw[0] -ne 0xFF -or $raw[1] -ne 0xFE) { throw "$path is not UTF-16LE" }
    $text = [Text.Encoding]::Unicode.GetString($raw, 2, $raw.Length - 2)
    $parts = [regex]::Split($text, '(\r?\n)')
    $sb = New-Object System.Text.StringBuilder; $sec = $null; $diff = @()
    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        $ln = $parts[$i]; $sep = if ($i + 1 -lt $parts.Count) { $parts[$i + 1] } else { '' }
        $s = $ln.Trim()
        if ($s.StartsWith('[')) { $sec = $s }
        if ($s -match '^([^=]+)=(.*)$') {
            $k = $Matches[1]; $v = $Matches[2]
            if ($sec -eq '[SyncMode]' -and $EnvSet.Contains($k)) { $diff += "unsync $k"; continue }
            if ($sec -ne '[SyncMode]' -and $EnvSet.Contains($k) -and $v -ne $EnvSet[$k]) { $diff += "$k $v->$($EnvSet[$k])"; $ln = "$k=$($EnvSet[$k])" }
        }
        [void]$sb.Append($ln).Append($sep)
    }
    if ($write -and $diff) {
        (Get-Item -LiteralPath $path).IsReadOnly = $false
        [IO.File]::WriteAllBytes($path, [byte[]](@([byte]0xFF, [byte]0xFE) + [Text.Encoding]::Unicode.GetBytes($sb.ToString())))
    }
    , $diff
}
$EnvTask = 'SogouDebloat-EnvIni'

function Test-ModuleLoaded([string]$name) {
    $r = @(tasklist /m $name /fo csv /nh 2>$null | Where-Object { $_ -match '^"' })
    $r.Count -gt 0
}
function Set-Placeholder([string]$path, [ValidateSet('Directory', 'File')]$kind) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -Confirm:$false }
    New-Item -ItemType $kind -Path $path -Force | Out-Null
    if ($kind -eq 'File') { (Get-Item -LiteralPath $path).IsReadOnly = $true }
}

# ---------------------------------------------------------------- start
if ($BootEnvIni) {
    # Runs as SYSTEM at startup, before any logon: no IME is loaded, so nothing can flush stale settings over the file.
    Get-ChildItem -Path (Join-Path $ProfilePath 'AppData\LocalLow\SogouPY.users\*\env.ini') -ErrorAction SilentlyContinue |
        ForEach-Object { try { Update-EnvIni $_.FullName $true | Out-Null } catch { } }
    Unregister-ScheduledTask -TaskName $EnvTask -Confirm:$false -ErrorAction SilentlyContinue
    return
}

$Root = Get-SogouRoot
$Ver  = Get-SogouVersionDir $Root
$Comp = Join-Path $Root 'Components'
$CfgPath = Join-Path $Comp 'ComponentConfig.ini'

if ($ShowComponents) {
    Get-ComponentTable (Read-ComponentConfig $CfgPath).Text | Format-Table -AutoSize
    return
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Apply -and -not $isAdmin) { throw 'Run this from an elevated (Administrator) PowerShell when using -Apply.' }

Write-Host "Sogou install : $Root"
Write-Host "Version dir   : $Ver"
Write-Host ("Mode          : {0}" -f $(if ($Apply) { 'APPLY' } else { 'dry run (add -Apply to change things)' }))
Write-Host ''

# 1. SogouSvc: the only path that silently writes Program Files\SogouInput (reinstall, update, repair)
$svc = Get-CimInstance Win32_Service -Filter "Name='SogouSvc'" -ErrorAction SilentlyContinue
if ($svc -and $svc.StartMode -ne 'Disabled') {
    Act 'Disable service SogouSvc' { sc.exe config SogouSvc start= disabled | Out-Null; if ($LASTEXITCODE) { throw "sc.exe exit $LASTEXITCODE" } }
} elseif ($svc) { Say 'SKIP' 'SogouSvc already disabled' } else { Say 'SKIP' 'SogouSvc not present' }

# 2. Sogou PDF (installed per user under LocalAppData\sogoupdf)
$pdfDir = Join-Path $env:LOCALAPPDATA 'sogoupdf'
$pdfExe = Join-Path $pdfDir 'pdfsdk.exe'
if (Test-Path -LiteralPath $pdfExe) {
    Act 'Uninstall Sogou PDF with its own uninstaller' {
        $p = Start-Process $pdfExe -ArgumentList '/uninstall', '/from:imeuninst' -PassThru -Wait
        if ($p.ExitCode) { throw "uninstaller exit $($p.ExitCode)" }
    }
}
$acl = if (Test-Path -LiteralPath $pdfDir) { (icacls $pdfDir) -join ' ' } else { '' }
if ($acl -notmatch "$([regex]::Escape($env:USERNAME)):\(OI\)\(CI\)\(DENY\)") {
    Act "Empty and lock $pdfDir so Sogou PDF cannot reinstall" {
        if (Test-Path -LiteralPath $pdfDir) { Get-ChildItem -LiteralPath $pdfDir -Force | Remove-Item -Recurse -Force -Confirm:$false }
        else { New-Item -ItemType Directory -Path $pdfDir | Out-Null }
        icacls $pdfDir /deny "${env:USERNAME}:(OI)(CI)(WD,AD,WEA,WA)" | Out-Null
    }
} else { Say 'SKIP' 'sogoupdf directory already locked' }

# 3. Component switches in the encrypted global config (this is what actually gates loading)
$cfg = Read-ComponentConfig $CfgPath
$table = Get-ComponentTable $cfg.Text
$targets = @($table | Where-Object { $OffBundles.Contains($_.id) -and ($_.enable -ne '0' -or $_.forceenable -ne '0') })
if ($targets) {
    Act ("Disable components: " + (($targets | ForEach-Object id) -join ', ')) {
        Get-Process SGTool, SogouCloud, SogouImeBroker -ErrorAction SilentlyContinue | Stop-Process -Force -Confirm:$false
        $cfg.Text = Set-ComponentOff $cfg.Text @($targets | ForEach-Object section)
        Write-ComponentConfig $CfgPath $cfg
    }
} else { Say 'SKIP' 'Components already disabled' }

# 4. Registry: context menu, toast, protocol, feature switches
$lm = [Microsoft.Win32.Registry]::LocalMachine
$cu = [Microsoft.Win32.Registry]::CurrentUser
function Remove-SubKeyIfPresent($hive, [string]$parent, [string]$name) {
    $k = $hive.OpenSubKey($parent)
    if (-not $k) { return }
    $has = $k.GetSubKeyNames() -contains $name; $k.Close()
    if (-not $has) { return }
    $hiveName = if ($hive -eq $lm) { 'HKLM' } else { 'HKCU' }
    Act "Delete $hiveName\$parent\[$name]" {
        $w = $null; try { $w = $hive.OpenSubKey($parent, $true) } catch { }
        if ($w) { $w.DeleteSubKeyTree($name); $w.Close(); return }
        reg.exe delete "$hiveName\$parent\$name" /f 2>$null | Out-Null
        if ($LASTEXITCODE) { Say 'WARN' "Cannot delete $hiveName\$parent\[$name]: owned by TrustedInstaller. Harmless: the CLSID it points to is deleted and blocked."; 'warned' }
    }
}
$cmParents = @('*', 'Directory', 'Directory\Background', 'Drive', 'lnkfile', 'Folder', 'AllFilesystemObjects',
               'CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}', 'CLSID\{645FF040-5081-101B-9F08-00AA002F954E}',
               'WOW6432Node\CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}', 'WOW6432Node\CLSID\{645FF040-5081-101B-9F08-00AA002F954E}')
foreach ($p in $cmParents) {
    foreach ($view in @('SOFTWARE\Classes')) {
        $parent = "$view\$p\shellex\ContextMenuHandlers"
        $k = $lm.OpenSubKey($parent); if (-not $k) { continue }
        $names = $k.GetSubKeyNames() | Where-Object { $_ -match '^[\s-]*sgshellext' }; $k.Close()
        foreach ($n in $names) { Remove-SubKeyIfPresent $lm $parent $n }
    }
}
foreach ($g in $ShellExtClsids + $ToastActivator) {
    Remove-SubKeyIfPresent $lm 'SOFTWARE\Classes\CLSID' $g
    Remove-SubKeyIfPresent $lm 'SOFTWARE\Classes\WOW6432Node\CLSID' $g
}
$blockedPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
$bk = $lm.OpenSubKey($blockedPath)
$missing = @($ShellExtClsids | Where-Object { -not $bk -or $null -eq $bk.GetValue($_) }); if ($bk) { $bk.Close() }
if ($missing) {
    Act 'Block Sogou shell extension CLSIDs from re-registering' {
        $w = $lm.CreateSubKey($blockedPath); foreach ($g in $missing) { $w.SetValue($g, 'Sogou biz_shellext') }; $w.Close()
    }
}
Remove-SubKeyIfPresent $lm 'SOFTWARE\Classes' 'sgbiz'
foreach ($h in @($lm, $cu)) {
    $base = if ($h -eq $lm) { 'SOFTWARE\Classes\AppUserModelId' } else { 'Software\Classes\AppUserModelId' }
    $k = $h.OpenSubKey($base); if (-not $k) { continue }
    $ids = $k.GetSubKeyNames() | Where-Object { $_ -like 'Sogou.Ime.SysToast*' }; $k.Close()
    foreach ($i in $ids) { Remove-SubKeyIfPresent $h $base $i }
}
$notif = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$nk = $cu.OpenSubKey($notif)
$toastIds = @('Sogou.Ime.SysToast.Biz') + @(if ($nk) { $nk.GetSubKeyNames() | Where-Object { $_ -like 'Sogou.Ime.SysToast*' } }) | Select-Object -Unique
if ($nk) { $nk.Close() }
foreach ($a in $toastIds) {
    $k = $cu.OpenSubKey("$notif\$a")
    $on = -not $k -or $k.GetValue('Enabled') -ne 0; if ($k) { $k.Close() }
    if ($on) { Act "Turn off Windows notifications for $a" { $w = $cu.CreateSubKey("$notif\$a"); $w.SetValue('Enabled', 0, 'DWord'); $w.Close() } }
}
$sk = $cu.OpenSubKey('Software\SogouInput.store.user')
$storeTodo = @($StoreOff | Where-Object { -not $sk -or $sk.GetValue($_) -ne 0 }); if ($sk) { $sk.Close() }
if ($storeTodo) {
    Act ("Set store.user switches to 0: " + ($storeTodo -join ', ')) {
        $w = $cu.CreateSubKey('Software\SogouInput.store.user'); foreach ($v in $storeTodo) { $w.SetValue($v, 0, 'DWord') }; $w.Close()
    }
}

# 5. Neutralize executables: delete and leave a same-named directory so nothing can write them back
$files = @(
    "$Comp\SogouComMgr.exe",                 # component downloader / repairer / launcher
    "$Comp\crashrpt.exe",
    "$Ver\SGBizLauncher.exe",                # Shiply remote config + promoted installs
    "$Ver\PinyinUp.exe",                     # updater / repair
    "$Ver\SGDownload.exe",
    "$Ver\crashrpt.exe",
    "$Ver\sgfeedbackhelper.exe",
    "$Ver\SogouToolkits.exe",                # runs daily with -auto=1
    "$Ver\SGWangzai.exe",                    # AI assistant 'Wangzai'
    "$Ver\SGIGuideHelper.exe",               # rare-character install prompt
    "$Ver\Data\Bin\sgutil.dll",              # server popup
    "$Ver\Data\Bin\sgtool.dll"               # server popup
)
$files += Get-ChildItem -LiteralPath (Join-Path $Comp 'biz_center') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $b = $_.FullName
    "$b\biz_helper.exe", "$b\biz_notify.exe", "$b\ginkgo.exe", "$b\pdf\pdfsdk.exe",
    "$b\pdf\extension\pdfext.exe", "$b\pdf\menuex\menuexinstaller.exe", "$b\pdf\menuex\pdfmenuex.dll"
}
if ($RemoveVoice)   { $files += "$Ver\SGSmartAssistant.exe" }
if ($RemoveKaomoji) { $files += "$Ver\SGKaomoji.exe" }
foreach ($f in $files) {
    if (Test-Path -LiteralPath $f -PathType Container) { continue }
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $leaf = Split-Path $f -Leaf
    if ($leaf -like '*.exe' -and (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($leaf)) -ErrorAction SilentlyContinue)) {
        Act "Stop $leaf" { Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($leaf)) | Stop-Process -Force -Confirm:$false }
    }
    Act "Replace with placeholder dir: $f" { Set-Placeholder $f 'Directory' }
}
$sdk = 'C:\ProgramData\SogouInput\shell_ext\sdk'
if (Test-Path -LiteralPath $sdk -PathType Container) { Act "Replace with read-only file: $sdk" { Set-Placeholder $sdk 'File' } }

# 6. Component folders -> read-only files (only when no running program has their DLLs loaded)
$pending = @()
foreach ($kv in $OffBundles.GetEnumerator()) {
    if (-not $kv.Value) { continue }
    $dir = Join-Path $Comp $kv.Value
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $dlls = Get-ChildItem -LiteralPath $dir -Recurse -Filter *.dll -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique
    $busy = @($dlls | Where-Object { Test-ModuleLoaded $_ })
    if ($busy -and $Apply) { $pending += $kv.Value; Say 'WARN' "$dir still loaded ($($busy -join ', ')); reboot and run again"; continue }
    Act "Replace component folder with read-only file: $dir" { Set-Placeholder $dir 'File' }
}
foreach ($p in 'C:\ProgramData\SogouInput\Components\Picface', 'C:\ProgramData\SogouInput\wangzairootdir') {
    if (Test-Path -LiteralPath $p -PathType Container) { Act "Replace with read-only file: $p" { Set-Placeholder $p 'File' } }
}

# 7. env.ini: the IME keeps settings in shared memory and flushes them back over the file (it even
#    clears the read-only bit), so editing the file while any program has the IME loaded does not
#    stick. Register a one-shot startup task that edits it before logon, then removes itself.
$envFiles = @(Get-ChildItem -Path (Join-Path $env:USERPROFILE 'AppData\LocalLow\SogouPY.users\*\env.ini') -ErrorAction SilentlyContinue)
$envDiff = @(); foreach ($ef in $envFiles) { try { $envDiff += Update-EnvIni $ef.FullName $false } catch { Say 'WARN' $_.Exception.Message } }
if ($envDiff) {
    $already = Get-ScheduledTask -TaskName $EnvTask -ErrorAction SilentlyContinue
    if ($already) { Say 'SKIP' "env.ini edit already scheduled for next boot ($EnvTask)" }
    else {
        Act ("Schedule env.ini edit at next boot: " + (($envDiff | Select-Object -Unique) -join ', ')) {
            $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -BootEnvIni -ProfilePath `"$env:USERPROFILE`""
            if ($NoCloud) { $arg += ' -NoCloud' }
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
            $trg = New-ScheduledTaskTrigger -AtStartup
            $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $EnvTask -Action $act -Trigger $trg -Principal $pri `
                -Description 'One-shot: edit Sogou env.ini before logon, then delete this task (SogouDebloat).' | Out-Null
        }
    }
} elseif ($envFiles) { Say 'SKIP' 'env.ini already set' }
Write-Host ''
if (-not $Apply) { Write-Host "$script:Changes change(s) planned. Run again with -Apply in an elevated PowerShell." }
else {
    Write-Host "Done. Reboot (needed for the env.ini step and to unload old DLLs), then type in a few programs to confirm input still works."
    if ($pending) { Write-Host "After the reboot run '.\SogouDebloat.ps1 -Apply' once more to finish: $($pending -join ', ')" }
}
