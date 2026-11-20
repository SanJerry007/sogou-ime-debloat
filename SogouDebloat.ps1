#Requires -Version 5.1
<#
.SYNOPSIS
  Strip ads, AI assistant, online stickers, PDF tools, games, pet, telemetry SDKs and
  self-updaters from Sogou Pinyin IME on Windows while keeping plain pinyin input working.

.DESCRIPTION
  Dry run by default: prints what would change. Pass -Apply to change things.
  Needs an elevated (Administrator) PowerShell for -Apply.
  Idempotent: run it again after a reboot, or after a Sogou upgrade.
  Exit code is non-zero when any step failed.

  Nothing here patches a binary. See docs/how-it-works.md for the launch chain.

.PARAMETER Apply
  Actually make the changes.

.PARAMETER NoCloud
  Also turn off cloud candidates (EnableCloudRequest=0). Cloud input is kept by default.

.PARAMETER NoSync
  Also stop account / dictionary cloud sync (blocks userNetSchedule.exe). Kept by default.

.PARAMETER BlockNet
  Add Windows Firewall outbound block rules for SGTool.exe and userNetSchedule.exe of the
  active version. Off by default: SGTool also fetches cell dictionaries and skins.

.PARAMETER RemoveVoice
  Also block SGSmartAssistant.exe (toolbox). Voice input lives there, so it is kept by default.

.PARAMETER RemoveKaomoji
  Also block SGKaomoji.exe (local emoticon panel, no network). Kept by default.

.PARAMETER ShowComponents
  Only decrypt and print the component table (id / enable / forceenable), then exit.

.PARAMETER Install
  Apply now, then keep it applied: copies this script and the chosen options to
  %ProgramData%\SogouDebloat (admin-only) and registers the task SogouDebloat-Watch, which
  re-runs it at every logon and every 6 hours, so a Sogou upgrade or repair is undone automatically.

.PARAMETER Uninstall
  Remove the tasks, IFEO blocks, firewall rules and %ProgramData%\SogouDebloat that this script created.
  Files already removed from Sogou come back only by reinstalling Sogou.

.PARAMETER Auto
  Used by the SogouDebloat-Watch task: -Apply with the saved options, logging to %ProgramData%\SogouDebloat.

.EXAMPLE
  .\SogouDebloat.ps1                 # dry run
  .\SogouDebloat.ps1 -Apply          # do it once
  .\SogouDebloat.ps1 -Install        # do it and keep it done after Sogou updates
  .\SogouDebloat.ps1 -Install -NoSync -BlockNet
  .\SogouDebloat.ps1 -Uninstall
  .\SogouDebloat.ps1 -ShowComponents
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$NoCloud,
    [switch]$NoSync,
    [switch]$BlockNet,
    [switch]$RemoveVoice,
    [switch]$RemoveKaomoji,
    [switch]$ShowComponents,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Auto
)
$ScriptVersion = '1.1.0'

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$StateDir  = Join-Path $env:ProgramData 'SogouDebloat'
$EnvTask   = 'SogouDebloat-EnvIni'
$WatchTask = 'SogouDebloat-Watch'
$OptionsFile = Join-Path $StateDir 'options.json'
$OptionNames = 'NoCloud', 'NoSync', 'BlockNet', 'RemoveVoice', 'RemoveKaomoji'

if ($Auto) {
    # Scheduled run: saved options win, output goes to the log.
    if (Test-Path -LiteralPath $OptionsFile) {
        $saved = Get-Content -LiteralPath $OptionsFile -Raw | ConvertFrom-Json
        foreach ($n in $OptionNames) { if ($saved.$n) { Set-Variable -Name $n -Value ([switch]$true) } }
    }
    $Apply = [switch]$true
    try { Start-Transcript -LiteralPath (Join-Path $StateDir 'auto.log') -Force | Out-Null } catch { }
}

# ---------------------------------------------------------------- constants
# Components\ComponentConfig.ini is base64 of AES-256-CBC. No key ships with this script: it is located at
# run time inside the user's own Sogou install (see Get-ComponentConfigKey) and never written to disk.

# component bundles to stop loading (bundle id in ComponentConfig.ini -> folder under Components)
$OffBundles = [ordered]@{
    'IChatComBundle'      = 'IChat'        # AI assistant 'Wangzai' (+ Tencent file indexer)
    'ISGPetComBundle'     = 'isgpet'       # desktop pet
    'GameCenterComBundle' = 'game_center'  # game center
    'PicFaceComBundle'    = 'PicFace'      # online stickers / picture emoji
    'BizCenterComBundle'  = $null          # ads, toast, PDF, context menu (folder kept: SogouCloud loads DLLs from it)
    'BizPDFComBundle'     = 'biz_pdf'
}

# Executables blocked by name through Image File Execution Options. The names are Sogou-specific,
# and the block keeps working when an upgrade installs them into a new version directory.
$BlockedExe = @('SogouComMgr.exe', 'SGBizLauncher.exe', 'PinyinUp.exe', 'SGDownload.exe', 'SGWangzai.exe',
                'SOGOUSmartAssistant.exe', 'isgpet.exe', 'SogouPlayLauncher.exe', 'SGPicFaceTool.exe',
                'SogouToolkits.exe', 'sgfeedbackhelper.exe', 'SGIGuideHelper.exe', 'biz_helper.exe', 'biz_notify.exe')
if ($NoSync)        { $BlockedExe += 'userNetSchedule.exe' }
if ($RemoveVoice)   { $BlockedExe += 'SGSmartAssistant.exe' }
if ($RemoveKaomoji) { $BlockedExe += 'SGKaomoji.exe' }
$IfeoTarget = Join-Path $env:SystemRoot 'System32\SogouDebloat-blocked\blocked.exe'   # never exists

$ShellExtClsids = @('{7BCE96FA-77AF-4288-9E16-2388A50EC807}', '{85212cfd-77ed-4add-8e24-a0a39e3dbfc3}')
$ToastActivator = '{1BB732FA-391B-4648-BC00-8AECA408C065}'

# HKCU\Software\SogouInput.store.user switches. Missing means ON, so they are written as 0.
$StoreOff = 'ichatenable','status_pop_switch','systoast_enable','pdf_enable','petautorun',
            'gamecenterenable','writespiritenable','wizardpromotion'

# env.ini [Setting] values. The same keys are dropped from [SyncMode] so account sync cannot restore them.
$EnvSet = [ordered]@{
    AutoUpdate = '2'; CandWangzaiSwitch = '0'; CandWangzaiIconSwitch = '0'; HintWangzaiComp = '0'
    EnableWangzaiGuideWnd = '0'; EnableAiPicComp = '0'; EnableImePop = '0'; EnableStatusSkinPop = '0'
    EnableAdsDispatch = '0'; EnablePetAutoRun = '0'; AppBoxShow = '0'
}
if ($NoCloud) { $EnvSet['EnableCloudRequest'] = '0' }

# ---------------------------------------------------------------- helpers
$script:Changes = 0; $script:Failures = 0
function Say([string]$tag, [string]$msg) {
    $color = @{ DO = 'Yellow'; OK = 'Green'; SKIP = 'DarkGray'; WARN = 'Magenta'; FAIL = 'Red' }[$tag]
    Write-Host ('[{0,-4}] {1}' -f $tag, $msg) -ForegroundColor $color
}
function Act([string]$msg, [scriptblock]$do) {
    $script:Changes++
    if (-not $Apply) { Say 'DO' "(dry) $msg"; return }
    try { $r = & $do; if (@($r) -contains 'warned') { $script:Changes-- } else { Say 'OK' $msg } }
    catch { $script:Failures++; Say 'FAIL' "$msg :: $($_.Exception.Message)" }
}
function Invoke-Native([string]$exe, [string[]]$argv) {
    $out = & $exe @argv 2>&1
    if ($LASTEXITCODE) { throw "$exe exit $LASTEXITCODE`: $($out -join ' ')" }
    $out
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
    # Prefer the version the installer registered as active; fall back to the highest one present.
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\SogouInput', 'HKLM:\SOFTWARE\SogouInput') {
        $v = (Get-ItemProperty -LiteralPath $k -Name Version -ErrorAction SilentlyContinue).Version
        if ($v -and (Test-Path -LiteralPath (Join-Path $root "$v\SGTool.exe"))) { return (Join-Path $root $v) }
    }
    $d = Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+){3}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'SGTool.exe')) } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $d) { throw "No version directory with SGTool.exe under $root." }
    $d.FullName
}

# Plaintext = 16 random bytes + ini text starting with "[system]". In CBC the second block decrypts as
# D(C2) xor C1, independent of the IV, so a candidate key is confirmed by one block decryption. The IV is
# never needed either: re-encryption keeps the original first ciphertext block C1 (so Sogou still decrypts
# its own random prefix) and chains the new text from C1.
Add-Type -TypeDefinition @'
using System; using System.Security.Cryptography;
public static class SogouCfgKey {
    static readonly byte[] Magic = System.Text.Encoding.ASCII.GetBytes("[system]");
    public static byte[] Find(byte[] img, byte[] c1, byte[] c2) {
        using (var aes = Aes.Create()) {
            aes.Mode = CipherMode.ECB; aes.Padding = PaddingMode.None;
            var key = new byte[32]; var o = new byte[16];
            for (int i = 0; i + 32 <= img.Length; i += 4) {
                int z = 0; for (int j = 0; j < 32 && z < 4; j++) if (img[i + j] == 0) z++;
                if (z >= 4) continue;                       // keys are high-entropy; skip padding/tables
                Buffer.BlockCopy(img, i, key, 0, 32);
                using (var d = aes.CreateDecryptor(key, null)) d.TransformBlock(c2, 0, 16, o, 0);
                bool ok = true;
                for (int j = 0; j < Magic.Length; j++) if ((byte)(o[j] ^ c1[j]) != Magic[j]) { ok = false; break; }
                if (ok) return (byte[])key.Clone();
            }
        }
        return null;
    }
}
'@
$script:CfgKeyCache = $null
function Get-ComponentConfigKey([byte[]]$ct) {
    if ($script:CfgKeyCache) { return $script:CfgKeyCache }
    $c1 = $ct[0..15]; $c2 = $ct[16..31]
    # Small core binaries first; the IME core is never neutralized, so the key stays derivable.
    $sources = @((Join-Path $env:SystemRoot 'SysWOW64\IME\SogouPY\SogouImeBroker.exe'),
                 (Join-Path $env:SystemRoot 'System32\SogouTSF.ime'), (Join-Path $env:SystemRoot 'SysWOW64\SogouTSF.ime'),
                 (Join-Path $Ver 'SGTool.exe'), (Join-Path $Comp 'SogouComMgr.exe'))
    foreach ($s in $sources) {
        if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { continue }
        $k = [SogouCfgKey]::Find([IO.File]::ReadAllBytes($s), [byte[]]$c1, [byte[]]$c2)
        if ($k) { $script:CfgKeyCache = $k; return $k }
    }
    throw 'Could not locate the ComponentConfig key in the installed Sogou binaries (unsupported version?).'
}
function Invoke-Cbc([byte[]]$key, [byte[]]$iv, [byte[]]$data, [bool]$encrypt) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key; $aes.IV = $iv; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
    $t = if ($encrypt) { $aes.CreateEncryptor() } else { $aes.CreateDecryptor() }
    try { $t.TransformFinalBlock($data, 0, $data.Length) } finally { $t.Dispose(); $aes.Dispose() }
}
# Text is edited as Latin-1 so every byte round-trips untouched.
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
function Read-ComponentConfig([string]$path) {
    $ct = [Convert]::FromBase64String(([IO.File]::ReadAllText($path)).Trim())
    $key = Get-ComponentConfigKey $ct
    $c1 = [byte[]]$ct[0..15]
    $rest = New-Object byte[] ($ct.Length - 16); [Array]::Copy($ct, 16, $rest, 0, $rest.Length)
    $pt = Invoke-Cbc $key $c1 $rest $false                        # blocks 2..n, chained from C1
    [pscustomobject]@{ C1 = $c1; Text = $Latin1.GetString($pt) }
}
function Write-ComponentConfig([string]$path, $cfg) {
    $key = $script:CfgKeyCache
    $enc = Invoke-Cbc $key ([byte[]]$cfg.C1) ($Latin1.GetBytes($cfg.Text)) $true
    $out = New-Object byte[] (16 + $enc.Length)
    [Array]::Copy([byte[]]$cfg.C1, 0, $out, 0, 16); [Array]::Copy($enc, 0, $out, 16, $enc.Length)
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, [Convert]::ToBase64String($out), $Latin1)
    if ((Read-ComponentConfig $tmp).Text -ne $cfg.Text) { Remove-Item -LiteralPath $tmp -Force; throw 're-encrypted config did not read back identically' }
    [IO.File]::Replace($tmp, $path, [NullString]::Value)
}
function Get-ComponentTable([string]$text) {
    $rows = @{}; $sec = $null; $isCom = $false
    foreach ($ln in ($text -split "`n")) {
        $s = $ln.Trim()
        if ($s -match '^\[(bundle\d+)(com\d+)?\]$') {
            $sec = $Matches[1]; $isCom = [bool]$Matches[2]
            if (-not $rows[$sec]) { $rows[$sec] = [ordered]@{ section = $sec; id = ''; forceenable = ''; enable = '' } }
            continue
        }
        if ($s -match '^\[') { $sec = $null; continue }
        if (-not $sec) { continue }
        if (-not $isCom -and $s -match '^id=(.*)$') { $rows[$sec].id = $Matches[1] }
        elseif (-not $isCom -and $s -match '^forceenable=(.*)$') { $rows[$sec].forceenable = $Matches[1] }
        elseif ($isCom -and $s -match '^enable=(.*)$') {
            # several com sub-sections: report the bundle as enabled if any of them is
            if ($rows[$sec].enable -eq '' -or $rows[$sec].enable -eq '0') { $rows[$sec].enable = $Matches[1] }
        }
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

# env.ini is UTF-16LE with BOM. Sets $Want inside [Setting] (adding missing keys), drops the same keys
# from [SyncMode]. Returns the list of changes; writes only when $write. Self-contained on purpose:
# its source is copied verbatim into the startup task script.
function Update-EnvIni([string]$path, $Want, [bool]$write) {
    $raw = [IO.File]::ReadAllBytes($path)
    if ($raw.Length -lt 2 -or $raw[0] -ne 0xFF -or $raw[1] -ne 0xFE) { throw "$path is not UTF-16LE" }
    $text = [Text.Encoding]::Unicode.GetString($raw, 2, $raw.Length - 2)
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [regex]::Split($text, '\r?\n')
    $out = New-Object System.Collections.Generic.List[string]; $sec = $null; $diff = @(); $seen = @{}
    $flush = {
        if ($sec -eq '[Setting]') {
            foreach ($k in $Want.Keys) { if (-not $seen.ContainsKey($k)) { $out.Add("$k=$($Want[$k])"); $diff += "+$k=$($Want[$k])"; $seen[$k] = 1 } }
        }
    }
    foreach ($ln in $lines) {
        $s = $ln.Trim()
        if ($s.StartsWith('[')) {
            # insert missing keys before trailing blank lines of [Setting]
            if ($sec -eq '[Setting]') { $blank = 0; while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1); $blank++ }; . $flush; for ($i = 0; $i -lt $blank; $i++) { $out.Add('') } }
            $sec = $s; $out.Add($ln); continue
        }
        if ($s -match '^([^=]+)=(.*)$' -and $Want.Contains($Matches[1])) {
            $k = $Matches[1]; $v = $Matches[2]
            if ($sec -eq '[SyncMode]') { $diff += "unsync $k"; continue }
            if ($sec -eq '[Setting]') { $seen[$k] = 1; if ($v -ne $Want[$k]) { $diff += "$k $v->$($Want[$k])"; $ln = "$k=$($Want[$k])" } }
        }
        $out.Add($ln)
    }
    if ($sec -eq '[Setting]') { . $flush }
    if (-not ($lines | Where-Object { $_.Trim() -eq '[Setting]' })) { $out.Add('[Setting]'); $sec = '[Setting]'; . $flush }
    if ($write -and $diff) {
        (Get-Item -LiteralPath $path).IsReadOnly = $false
        $bytes = [byte[]](@([byte]0xFF, [byte]0xFE) + [Text.Encoding]::Unicode.GetBytes(($out -join $nl)))
        [IO.File]::WriteAllBytes($path, $bytes)
    }
    , $diff
}

# $true / $false, or $null when the query itself failed (unknown: do not treat as "not loaded")
function Test-ModuleLoaded([string]$name) {
    $r = & tasklist.exe /m $name /fo csv /nh 2>&1
    if ($LASTEXITCODE) { return $null }
    @($r | Where-Object { $_ -match '^"' }).Count -gt 0
}
function Stop-ByPath([string]$path) {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $path } catch { $false } } |
        Stop-Process -Force -Confirm:$false
}
function Set-Placeholder([string]$path, [ValidateSet('Directory', 'File')]$kind) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -Confirm:$false }
    New-Item -ItemType $kind -Path $path -Force | Out-Null
    if ($kind -eq 'File') { (Get-Item -LiteralPath $path).IsReadOnly = $true }
}
function Test-UserDenyWrite([string]$path) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $path
    [bool]($acl.Access | Where-Object {
        $_.AccessControlType -eq 'Deny' -and
        $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $sid -and
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData) })
}

# State dir: SYSTEM and Administrators full, Users read. Elevated tasks only ever run code from here.
function Protect-StateDir {
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    Invoke-Native icacls.exe @($StateDir, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX') | Out-Null
}
function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- install / uninstall
if ($Uninstall) {
    if (-not (Test-IsAdmin)) { throw 'Run -Uninstall from an elevated (Administrator) PowerShell.' }
    foreach ($t in $WatchTask, $EnvTask) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $t -Confirm:$false; Say 'OK' "Removed task $t" }
    }
    $lm64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $ifeoKey = $lm64.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options', $true)
    foreach ($n in $ifeoKey.GetSubKeyNames()) {
        $k = $ifeoKey.OpenSubKey($n, $true)
        if ($k -and $k.GetValue('Debugger') -eq $IfeoTarget) {
            $k.DeleteValue('Debugger'); $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0); $k.Close()
            if ($empty) { $ifeoKey.DeleteSubKey($n) }
            Say 'OK' "Removed IFEO block for $n"
        } elseif ($k) { $k.Close() }
    }
    $ifeoKey.Close()
    Get-NetFirewallRule -DisplayName 'SogouDebloat block*' -ErrorAction SilentlyContinue | ForEach-Object { Remove-NetFirewallRule -Name $_.Name; Say 'OK' "Removed firewall rule $($_.DisplayName)" }
    if (Test-Path -LiteralPath $StateDir) { Remove-Item -LiteralPath $StateDir -Recurse -Force -Confirm:$false; Say 'OK' "Removed $StateDir" }
    Write-Host ''
    Write-Host 'Removed what this script registered. To get Sogou''s removed files back, reinstall Sogou over the top,'
    Write-Host 'then run: sc config SogouSvc start= demand   (see README, section 撤销).'
    return
}

if ($Install) {
    if (-not (Test-IsAdmin)) { throw 'Run -Install from an elevated (Administrator) PowerShell.' }
    Protect-StateDir
    $installed = Join-Path $StateDir 'SogouDebloat.ps1'
    if ($PSCommandPath -ne $installed) { Copy-Item -LiteralPath $PSCommandPath -Destination $installed -Force }
    $opt = [ordered]@{}; foreach ($n in $OptionNames) { $opt[$n] = [bool](Get-Variable -Name $n -ValueOnly) }
    $opt | ConvertTo-Json | Set-Content -LiteralPath $OptionsFile -Encoding UTF8
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # conhost --headless keeps the run invisible; the task runs elevated as the installing user, so
    # HKCU, %LOCALAPPDATA% and the Sogou user profile resolve to that user.
    $act = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installed`" -Auto"
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $user
    $every = New-ScheduledTaskTrigger -Daily -At '00:00'
    $every.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
    $pri = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $WatchTask -Action $act -Trigger @($logon, $every) -Principal $pri -Settings $set -Force `
        -Description "SogouDebloat $ScriptVersion：登录时和每 6 小时检查搜狗输入法，被更新或修复后自动重新精简 (re-applies after Sogou updates)" | Out-Null
    Say 'OK' "Installed to $installed and registered task $WatchTask (logon + every 6 h)"
    Write-Host ''
    # Fall through: apply now with the same options.
    $Apply = [switch]$true
}

# ---------------------------------------------------------------- start
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

Write-Host "SogouDebloat  : v$ScriptVersion"
Write-Host "Sogou install : $Root"
Write-Host "Version dir   : $Ver"
Write-Host ("Mode          : {0}" -f $(if ($Apply) { 'APPLY' } else { 'dry run (add -Apply to change things)' }))
Write-Host ''

# 1. SogouSvc: the only path that silently writes Program Files\SogouInput (reinstall, update, repair)
$svc = Get-CimInstance Win32_Service -Filter "Name='SogouSvc'" -ErrorAction SilentlyContinue
if ($svc -and $svc.StartMode -ne 'Disabled') {
    Act 'Disable service SogouSvc' { Invoke-Native sc.exe @('config', 'SogouSvc', 'start=', 'disabled') | Out-Null }
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
if (-not ((Test-Path -LiteralPath $pdfDir) -and (Test-UserDenyWrite $pdfDir))) {
    Act "Empty and lock $pdfDir against reinstall (current user only)" {
        if (Test-Path -LiteralPath $pdfDir) { Get-ChildItem -LiteralPath $pdfDir -Force | Remove-Item -Recurse -Force -Confirm:$false }
        else { New-Item -ItemType Directory -Path $pdfDir | Out-Null }
        Invoke-Native icacls.exe @($pdfDir, '/deny', "*$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value):(OI)(CI)(WD,AD,WEA,WA)") | Out-Null
    }
} else { Say 'SKIP' 'sogoupdf directory already locked' }

# 3. Component switches in the encrypted global config (this is what actually gates loading)
$cfg = Read-ComponentConfig $CfgPath
$targets = @(Get-ComponentTable $cfg.Text | Where-Object { $OffBundles.Contains($_.id) -and ($_.enable -ne '0' -or $_.forceenable -ne '0') })
if ($targets) {
    Act ("Disable components: " + (($targets | ForEach-Object id) -join ', ')) {
        foreach ($exe in 'SGTool.exe', 'SogouCloud.exe') { Stop-ByPath (Join-Path $Ver $exe) }
        $cfg.Text = Set-ComponentOff $cfg.Text @($targets | ForEach-Object section)
        Write-ComponentConfig $CfgPath $cfg
    }
} else { Say 'SKIP' 'Components already disabled' }

# 4. Registry: context menu, toast, protocol, feature switches. HKLM always through the 64-bit view.
$lm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$cu = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
function Remove-SubKeyIfPresent($hive, [string]$parent, [string]$name) {
    $k = $hive.OpenSubKey($parent)
    if (-not $k) { return }
    $has = $k.GetSubKeyNames() -contains $name; $k.Close()
    if (-not $has) { return }
    $hiveName = if ($hive -eq $lm) { 'HKLM' } else { 'HKCU' }
    Act "Delete $hiveName\$parent\[$name]" {
        $w = $null; try { $w = $hive.OpenSubKey($parent, $true) } catch { }
        if ($w) { $w.DeleteSubKeyTree($name); $w.Close(); return }
        cmd.exe /c "reg.exe delete `"$hiveName\$parent\$name`" /f /reg:64 >nul 2>&1"
        if ($LASTEXITCODE) { Say 'WARN' "Cannot delete $hiveName\$parent\[$name]: owned by TrustedInstaller. Harmless: the CLSID it points to is deleted and blocked."; 'warned' }
    }
}
$cmParents = @('*', 'Directory', 'Directory\Background', 'Drive', 'lnkfile', 'Folder', 'AllFilesystemObjects',
               'CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}', 'CLSID\{645FF040-5081-101B-9F08-00AA002F954E}',
               'WOW6432Node\CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}', 'WOW6432Node\CLSID\{645FF040-5081-101B-9F08-00AA002F954E}')
foreach ($h in @($lm, $cu)) {
    $classes = if ($h -eq $lm) { 'SOFTWARE\Classes' } else { 'Software\Classes' }
    foreach ($p in $cmParents) {
        $parent = "$classes\$p\shellex\ContextMenuHandlers"
        $k = $h.OpenSubKey($parent); if (-not $k) { continue }
        $names = $k.GetSubKeyNames() | Where-Object { $_ -match '^[\s-]*sgshellext' }; $k.Close()
        foreach ($n in $names) { Remove-SubKeyIfPresent $h $parent $n }
    }
    foreach ($g in $ShellExtClsids + $ToastActivator) {
        Remove-SubKeyIfPresent $h "$classes\CLSID" $g
        Remove-SubKeyIfPresent $h "$classes\WOW6432Node\CLSID" $g
    }
}
$blockedPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
$bk = $lm.OpenSubKey($blockedPath)
$missing = @($ShellExtClsids | Where-Object { -not $bk -or $null -eq $bk.GetValue($_) }); if ($bk) { $bk.Close() }
if ($missing) {
    Act 'Stop Explorer from loading the Sogou shell extension (Shell Extensions\Blocked)' {
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

# 5. Block executables by name (IFEO). Survives upgrades into a new version directory.
$ifeo = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
foreach ($n in $BlockedExe) {
    $k = $lm.OpenSubKey("$ifeo\$n")
    $cur = if ($k) { $k.GetValue('Debugger') } else { $null }; if ($k) { $k.Close() }
    if ($cur -eq $IfeoTarget) { continue }
    if ($cur) { Say 'WARN' "IFEO $n already has Debugger '$cur'; left alone"; continue }
    Act "Block $n from starting (IFEO)" { $w = $lm.CreateSubKey("$ifeo\$n"); $w.SetValue('Debugger', $IfeoTarget); $w.Close() }
}

# 6. Neutralize files: delete and leave a same-named directory so nothing can write them back.
#    Telemetry / remote-config / ad SDK DLLs are all loaded dynamically (no import-table references),
#    so their hosts (SGTool, SogouCloud) keep running without them.
$sdkDlls = @("$Ver\beacon_sdk.dll", "$Ver\qimei.dll", "$Ver\shiply.dll")
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
    $script:sdkDlls += "$b\libamssdk.dll", "$b\qimei.dll"   # Tencent AMS ad SDK loaded by SogouCloud
    "$b\biz_helper.exe", "$b\biz_notify.exe", "$b\ginkgo.exe", "$b\pdf\pdfsdk.exe",
    "$b\pdf\extension\pdfext.exe", "$b\pdf\menuex\menuexinstaller.exe", "$b\pdf\menuex\pdfmenuex.dll"
}
if ($NoSync)        { $files += "$Ver\userNetSchedule.exe" }
if ($RemoveVoice)   { $files += "$Ver\SGSmartAssistant.exe" }
if ($RemoveKaomoji) { $files += "$Ver\SGKaomoji.exe" }
$liveSdk = @($sdkDlls | Where-Object { (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($liveSdk) {
    Act ("Remove telemetry / ad SDKs: " + ((($liveSdk | ForEach-Object { Split-Path $_ -Leaf }) | Select-Object -Unique) -join ', ')) {
        foreach ($exe in 'SGTool.exe', 'SogouCloud.exe') { Stop-ByPath (Join-Path $Ver $exe) }
        Start-Sleep -Milliseconds 500
        foreach ($d in $liveSdk) { Set-Placeholder $d 'Directory' }
    }
}
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
    Act "Replace with placeholder dir: $f" {
        if ($f -like '*.exe') { Stop-ByPath $f }
        Set-Placeholder $f 'Directory'
    }
}
$shellSdk = Join-Path $env:ProgramData 'SogouInput\shell_ext\sdk'
if (Test-Path -LiteralPath $shellSdk -PathType Container) { Act "Replace with read-only file: $shellSdk" { Set-Placeholder $shellSdk 'File' } }

# 7. Component folders -> read-only files (only when no running program has their DLLs loaded)
$pending = @()
foreach ($kv in $OffBundles.GetEnumerator()) {
    if (-not $kv.Value) { continue }
    $dir = Join-Path $Comp $kv.Value
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $dlls = Get-ChildItem -LiteralPath $dir -Recurse -Filter *.dll -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique
    $state = @($dlls | ForEach-Object { Test-ModuleLoaded $_ })
    if ($Apply -and ($state -contains $true -or $state -contains $null)) {
        $pending += $kv.Value; Say 'WARN' "$dir may still be loaded; reboot and run again"; continue
    }
    Act "Replace component folder with read-only file: $dir" { Set-Placeholder $dir 'File' }
}
foreach ($p in (Join-Path $env:ProgramData 'SogouInput\Components\Picface'), (Join-Path $env:ProgramData 'SogouInput\wangzairootdir')) {
    if (Test-Path -LiteralPath $p -PathType Container) { Act "Replace with read-only file: $p" { Set-Placeholder $p 'File' } }
}

# 8. Optional firewall rules for the processes that still talk to the network on their own.
if ($BlockNet) {
    foreach ($exe in @("$Ver\SGTool.exe", "$Ver\userNetSchedule.exe")) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $name = "SogouDebloat block $(Split-Path $exe -Leaf) $(Split-Path $Ver -Leaf)"
        if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) { continue }
        Act "Firewall: block outbound for $exe" { New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block -Program $exe | Out-Null }
    }
}

# 9. env.ini. The IME keeps settings in shared memory and flushes them back over the file (it even
#    clears the read-only bit), so an edit made while any program has the IME loaded does not stick.
#    A one-shot startup task edits it before logon instead. The task runs a small script kept in an
#    admin-only folder, so SYSTEM never executes a file the user can change. It removes itself only
#    after the edit succeeded, and logs to $StateDir\envini.log.
$envFiles = @(Get-ChildItem -Path (Join-Path $env:USERPROFILE 'AppData\LocalLow\SogouPY.users\*\env.ini') -ErrorAction SilentlyContinue)
$envDiff = @(); foreach ($ef in $envFiles) { try { $envDiff += Update-EnvIni $ef.FullName $EnvSet $false } catch { Say 'WARN' $_.Exception.Message } }
if ($envDiff) {
    $want = ($EnvSet.Keys | ForEach-Object { "'$_'='$($EnvSet[$_])'" }) -join '; '
    $targetsList = ($envFiles | ForEach-Object { "'" + ($_.FullName -replace "'", "''") + "'" }) -join ', '
    $body = @"
`$ErrorActionPreference = 'Stop'
function Update-EnvIni {${function:Update-EnvIni}}
`$want = [ordered]@{ $want }
`$log = '$StateDir\envini.log'
`$ok = `$true
foreach (`$f in @($targetsList)) {
    try { `$d = Update-EnvIni `$f `$want `$true; Add-Content -LiteralPath `$log "`$(Get-Date -Format s) `$f :: `$(`$d -join ', ')" }
    catch { `$ok = `$false; Add-Content -LiteralPath `$log "`$(Get-Date -Format s) FAILED `$f :: `$(`$_.Exception.Message)" }
}
if (`$ok) { Unregister-ScheduledTask -TaskName '$EnvTask' -Confirm:`$false }
"@
    $envScript = Join-Path $StateDir 'envini.ps1'
    $same = (Test-Path -LiteralPath $envScript) -and ([IO.File]::ReadAllText($envScript) -eq $body) -and (Get-ScheduledTask -TaskName $EnvTask -ErrorAction SilentlyContinue)
    if ($same) { Say 'SKIP' "env.ini edit already scheduled for next boot ($EnvTask): $(($envDiff | Select-Object -Unique) -join ', ')" }
    else {
        Act ("Schedule env.ini edit at next boot: " + (($envDiff | Select-Object -Unique) -join ', ')) {
            Protect-StateDir
            [IO.File]::WriteAllText($envScript, $body, (New-Object Text.UTF8Encoding $false))
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$envScript`""
            $trg = New-ScheduledTaskTrigger -AtStartup
            $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $EnvTask -Action $act -Trigger $trg -Principal $pri -Force `
                -Description 'SogouDebloat：开机时改一次搜狗 env.ini，成功后删除自己 (one-shot)' | Out-Null
        }
    }
} elseif ($envFiles) { Say 'SKIP' 'env.ini already set' }

Write-Host ''
if ($Auto) {
    Add-Content -LiteralPath (Join-Path $StateDir 'history.log') ("{0} v{1} Sogou {2}: {3} change(s), {4} failure(s)" -f
        (Get-Date -Format s), $ScriptVersion, (Split-Path $Ver -Leaf), $script:Changes, $script:Failures)
    try { Stop-Transcript | Out-Null } catch { }
}
if (-not $Apply) { Write-Host "$script:Changes change(s) planned. Run again with -Apply in an elevated PowerShell." }
else {
    if ($script:Failures) { Write-Host "$script:Failures step(s) FAILED, see above." -ForegroundColor Red }
    Write-Host 'Reboot (needed for the env.ini step and to unload old DLLs), then type in a few programs to confirm input still works.'
    if ($pending) { Write-Host "After the reboot run '.\SogouDebloat.ps1 -Apply' once more to finish: $($pending -join ', ')" }
}
if ($script:Failures) { exit 1 }
exit 0
