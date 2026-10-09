#Requires -Version 5.1
<#
.SYNOPSIS
    Win11-DeepDebloat - deep, verified debloat of Windows 11.

.DESCRIPTION
    ALWAYS applied (no questions):
      - Telemetry / diagnostic-data / CEIP / error-reporting policies, services and scheduled tasks
      - ETW AutoLogger sessions that feed the telemetry pipeline from boot (the kernel-side part)
      - Outbound firewall blocks for the telemetry binaries; Defender sample sharing off
      - Recall / Click to Do / Copilot policies, advertising ID, ads in Start / lock screen / Settings,
        web results in Start search, Widgets and news feeds, cloud clipboard, activity history, settings sync
      - Consumer junk apps, legacy Windows features, junk and leftover files
    ASKED per item (Y/N): Camera, Photos, Notepad, Xbox, Phone Link, Office (Word ...), OneDrive, Edge,
      Print Spooler, Bluetooth, Search indexing, Location, ...   (only items that are present are asked)

    Every change is VERIFIED after it is applied (registry value read back, service start type, task
    state, package really gone, path really deleted ...). The final report lists whatever did not verify.

    NOT touched on purpose: Windows Update, Microsoft Defender protection, Microsoft Store, winget,
    Windows Terminal, WebView2 runtime, drivers.
    Do NOT use on a PC that is managed by an employer or school.

.PARAMETER DryRun
    Show what would be changed. Nothing is modified.
.PARAMETER VerifyOnly
    Re-check the result of a previous run (uses -Config or the last saved choices). Nothing is modified.
    Run it after every Windows feature update: updates can silently re-enable things.
.PARAMETER Restore
    Revert registry values, service start types, scheduled tasks, firewall rules and Defender settings to
    what they were before the FIRST run (baseline.json). Removed apps and deleted files cannot be restored
    automatically (reinstall apps from the Microsoft Store or with winget).
.PARAMETER Config
    Path to a choices.json written by a previous run. Skips all questions.
.PARAMETER Defaults
    Answer every optional question with its default. Skips all questions.
.PARAMETER Yes
    Do not ask for the final confirmation.
.PARAMETER NoRestorePoint
    Do not create a System Restore point first.
.PARAMETER SkipCleanup
    Skip the file clean-up and the component-store clean-up.
.PARAMETER StateDir
    Where logs, baseline.json, choices.json and reports are kept.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Win11-DeepDebloat.ps1
.EXAMPLE
    .\Win11-DeepDebloat.ps1 -DryRun
.EXAMPLE
    .\Win11-DeepDebloat.ps1 -Config C:\ProgramData\Win11DeepDebloat\choices.json -Yes
.EXAMPLE
    .\Win11-DeepDebloat.ps1 -VerifyOnly
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$VerifyOnly,
    [switch]$Restore,
    [string]$Config,
    [switch]$Defaults,
    [switch]$Yes,
    [switch]$NoRestorePoint,
    [switch]$SkipCleanup,
    [string]$StateDir = (Join-Path $env:ProgramData 'Win11DeepDebloat')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Script:Version  = '1.0.0'
$Script:ExitCode = 0

# =============================================================================
#  0. Elevation / host (needs Windows PowerShell 5.1 + Administrator)
# =============================================================================
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (($PSVersionTable.PSEdition -ne 'Desktop') -or (-not (Test-IsAdmin))) {
    if (-not $PSCommandPath) { throw 'Save this script as a .ps1 file and run it from Windows PowerShell 5.1.' }
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = New-Object System.Collections.Generic.List[string]
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))) { $relaunch.Add($a) }
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value.IsPresent) { $relaunch.Add('-' + $kv.Key) }
        } else {
            $v = [string]$kv.Value
            if ($kv.Key -eq 'Config') { $v = (Resolve-Path -LiteralPath $v).Path }
            $relaunch.Add('-' + $kv.Key)
            $relaunch.Add(('"{0}"' -f $v))
        }
    }
    Write-Host 'Re-launching in an elevated Windows PowerShell session ...' -ForegroundColor Cyan
    $env:W11DD_RELAUNCHED = '1'
    if (Test-IsAdmin) { Start-Process -FilePath $winPs -ArgumentList $relaunch.ToArray() }
    else { Start-Process -FilePath $winPs -ArgumentList $relaunch.ToArray() -Verb RunAs }
    return
}

# =============================================================================
#  1. Logging and prompts
# =============================================================================
$Script:LogFile = $null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $colors = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; STEP = 'Cyan'; DRY = 'Magenta'; DIM = 'DarkGray' }
    $c = $colors[$Level]
    if (-not $c) { $c = 'Gray' }
    $line = '[{0}] [{1,-4}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $c
    if ($Script:LogFile) { try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8 } catch { } }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host (' ' + $Title) -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    if ($Script:LogFile) { try { Add-Content -LiteralPath $Script:LogFile -Value ("`r`n== " + $Title + ' ==') -Encoding UTF8 } catch { } }
}

function Read-YesNo {
    param([string]$Question, [bool]$DefaultYes = $false)
    $hint = '[y/N]'
    if ($DefaultYes) { $hint = '[Y/n]' }
    while ($true) {
        $a = ([string](Read-Host ('{0} {1}' -f $Question, $hint))).Trim().ToLowerInvariant()
        if ($a -eq '') { return $DefaultYes }
        if (@('y', 'yes') -contains $a) { return $true }
        if (@('n', 'no') -contains $a) { return $false }
    }
}

# =============================================================================
#  2. Small utilities
# =============================================================================
function Invoke-Native {
    # Runs a native command, never throws on stderr output, returns ExitCode + Output.
    param([string]$File, [string[]]$Arguments = @())
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $File @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{ ExitCode = $code; Output = (($out | Out-String).Trim()) }
}

function Start-ProcessWait {
    param([string]$File, [string]$Arguments = '', [int]$TimeoutSec = 600)
    $sp = @{ FilePath = $File; PassThru = $true; WindowStyle = 'Hidden' }
    if ($Arguments) { $sp['ArgumentList'] = $Arguments }
    $p = Start-Process @sp
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ ExitCode = -1; TimedOut = $true }
    }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; TimedOut = $false }
}

function Split-CommandLine {
    param([string]$Cmd)
    $Cmd = $Cmd.Trim()
    if ($Cmd -match '^"([^"]+)"\s*(.*)$') { return [pscustomobject]@{ File = $Matches[1]; Arguments = $Matches[2] } }
    if ($Cmd -match '^(.+?\.exe)\s*(.*)$') { return [pscustomobject]@{ File = $Matches[1]; Arguments = $Matches[2] } }
    return [pscustomobject]@{ File = $Cmd; Arguments = '' }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-FreeBytes {
    $drv = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($null -eq $drv) { return [int64]0 }
    return [int64]$drv.Free
}

function Get-ProfilePaths {
    return @(Get-CimInstance -ClassName Win32_UserProfile |
        Where-Object { (-not $_.Special) -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
        ForEach-Object { $_.LocalPath })
}

# =============================================================================
#  3. State directory and baseline (original values, written once, used by -Restore)
# =============================================================================
$Script:Baseline = @{}
$Script:Saved    = $null
$Script:Bulk     = $null

function Import-Baseline {
    if (-not (Test-Path -LiteralPath $Script:BaselineFile)) { return }
    try {
        $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Script:BaselineFile -Raw)
        foreach ($e in $parsed) {
            $h = @{}
            foreach ($p in $e.PSObject.Properties) { $h[$p.Name] = $p.Value }
            if ($h.ContainsKey('Key')) { $Script:Baseline[[string]$h['Key']] = $h }
        }
    } catch { Write-Log ('Could not read baseline.json: ' + $_.Exception.Message) 'WARN' }
}

function Save-Baseline {
    if ($DryRun -or $VerifyOnly -or $Restore) { return }
    if ($Script:Baseline.Count -eq 0) { return }
    try {
        $json = ConvertTo-Json -InputObject @($Script:Baseline.Values) -Depth 6
        Set-Content -LiteralPath $Script:BaselineFile -Value $json -Encoding UTF8
    } catch { Write-Log ('Could not save baseline.json: ' + $_.Exception.Message) 'WARN' }
}

function Initialize-State {
    foreach ($d in @($StateDir, (Join-Path $StateDir 'logs'), (Join-Path $StateDir 'reports'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $Script:Stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Script:LogFile      = Join-Path $StateDir ('logs\run-{0}.log' -f $Script:Stamp)
    $Script:BaselineFile = Join-Path $StateDir 'baseline.json'
    $Script:ChoicesFile  = Join-Path $StateDir 'choices.json'
    Import-Baseline
    Write-Log ('State directory: ' + $StateDir) 'DIM'
}

# =============================================================================
#  4. User registry hives (every existing profile + the Default profile for new users)
# =============================================================================
$Script:UserRoots = New-Object System.Collections.Generic.List[object]

function Mount-UserHives {
    $Script:UserRoots.Clear()
    foreach ($k in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        if ($k.PSChildName -match '^S-1-(5-21|12-1)-[\d-]+$') {
            $Script:UserRoots.Add([pscustomobject]@{ Id = $k.PSChildName; Root = ('Registry::HKEY_USERS\{0}' -f $k.PSChildName); Mounted = $false; MountName = $null })
        }
    }
    foreach ($p in @(Get-CimInstance -ClassName Win32_UserProfile | Where-Object { (-not $_.Special) -and $_.LocalPath })) {
        if (@($Script:UserRoots | Where-Object { $_.Id -eq $p.SID }).Count -gt 0) { continue }
        $dat = Join-Path $p.LocalPath 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $dat)) { continue }
        $name = 'DBL_' + ($p.SID -replace '[^0-9A-Za-z]', '_')
        $r = Invoke-Native 'reg.exe' @('load', ('HKU\' + $name), $dat)
        if ($r.ExitCode -eq 0) {
            $Script:UserRoots.Add([pscustomobject]@{ Id = $p.SID; Root = ('Registry::HKEY_USERS\{0}' -f $name); Mounted = $true; MountName = $name })
        } else {
            Write-Log ('Profile hive not loaded (in use?): ' + $p.LocalPath) 'WARN'
        }
    }
    $def = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (Test-Path -LiteralPath $def) {
        $r = Invoke-Native 'reg.exe' @('load', 'HKU\DBL_DEFAULT', $def)
        if ($r.ExitCode -eq 0) {
            $Script:UserRoots.Add([pscustomobject]@{ Id = 'DEFAULT'; Root = 'Registry::HKEY_USERS\DBL_DEFAULT'; Mounted = $true; MountName = 'DBL_DEFAULT' })
        }
    }
    Write-Log ('User registry hives available: {0} (including the Default profile for new users)' -f $Script:UserRoots.Count) 'DIM'
}

function Dismount-UserHives {
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 300
    foreach ($r in @($Script:UserRoots | Where-Object { $_.Mounted })) {
        $ok = $false
        for ($i = 0; ($i -lt 6) -and (-not $ok); $i++) {
            $x = Invoke-Native 'reg.exe' @('unload', ('HKU\' + $r.MountName))
            if ($x.ExitCode -eq 0) { $ok = $true } else { [gc]::Collect(); Start-Sleep -Milliseconds 500 }
        }
        if (-not $ok) { Write-Log ('Could not unload hive ' + $r.MountName + ' - Windows releases it at the next reboot.') 'WARN' }
    }
    $Script:UserRoots.Clear()
}

# =============================================================================
#  5. Registry helpers (every first change is recorded in the baseline)
# =============================================================================
function Get-RegTargets {
    param([string]$Hive)
    if ($Hive -eq 'HKLM') { return @([pscustomobject]@{ Id = 'HKLM'; Root = 'HKLM:' }) }
    return @($Script:UserRoots)
}

function Get-RegTargetsById {
    param([string]$Id)
    if ($Id -eq 'HKLM') { return @([pscustomobject]@{ Id = 'HKLM'; Root = 'HKLM:' }) }
    return @($Script:UserRoots | Where-Object { $_.Id -eq $Id })
}

function Get-RegValue {
    # Returns the raw value, or $null when the key or the value does not exist.
    param([string]$Full, [string]$Name)
    if (-not (Test-Path -LiteralPath $Full)) { return $null }
    $k = Get-Item -LiteralPath $Full -ErrorAction SilentlyContinue
    if ($null -eq $k) { return $null }
    if ($k.GetValueNames() -notcontains $Name) { return $null }
    return $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Save-RegBaseline {
    param([string]$Full, [string]$Name, [string]$RootId, [string]$RelPath)
    $bkey = 'R|{0}|{1}|{2}' -f $RootId, $RelPath, $Name
    if ($Script:Baseline.ContainsKey($bkey)) { return }
    $existed = $false
    $old = $null
    $kind = $null
    $k = $null
    if (Test-Path -LiteralPath $Full) { $k = Get-Item -LiteralPath $Full -ErrorAction SilentlyContinue }
    if (($null -ne $k) -and ($k.GetValueNames() -contains $Name)) {
        $existed = $true
        $old = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = $k.GetValueKind($Name).ToString()
        if ($old -is [byte[]]) { $old = [Convert]::ToBase64String($old) }
    }
    $Script:Baseline[$bkey] = @{ Key = $bkey; T = 'reg'; RootId = $RootId; Path = $RelPath; Name = $Name; Existed = $existed; Kind = $kind; Value = $old }
}

function Set-RegTracked {
    param([string]$Full, [string]$Name, $Value, [string]$Type, [string]$RootId, [string]$RelPath)
    Save-RegBaseline -Full $Full -Name $Name -RootId $RootId -RelPath $RelPath
    if (-not (Test-Path -LiteralPath $Full)) { New-Item -Path $Full -Force | Out-Null }
    New-ItemProperty -LiteralPath $Full -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-RegTracked {
    param([string]$Full, [string]$Name, [string]$RootId, [string]$RelPath)
    Save-RegBaseline -Full $Full -Name $Name -RootId $RootId -RelPath $RelPath
    Remove-ItemProperty -LiteralPath $Full -Name $Name -Force -ErrorAction Stop
}

function Test-RegEqual {
    param($Current, $Wanted, [string]$Type)
    if ($null -eq $Current) { return $false }
    if (($Type -eq 'DWord') -or ($Type -eq 'QWord')) {
        try { return ([int64]$Current -eq [int64]$Wanted) } catch { return $false }
    }
    return ([string]$Current -ieq [string]$Wanted)
}

# =============================================================================
#  6. Cached system inventories (the DISM-based ones are slow, so they are read once)
# =============================================================================
$Script:Cache = @{ Appx = $null; Prov = $null; Caps = $null; Feats = $null }
$Script:RemovedPkg  = New-Object 'System.Collections.Generic.HashSet[string]'
$Script:RemovedProv = New-Object 'System.Collections.Generic.HashSet[string]'

function Get-AppxAllCached {
    if ($null -eq $Script:Cache.Appx) {
        try { $Script:Cache.Appx = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) } catch { $Script:Cache.Appx = @() }
    }
    return $Script:Cache.Appx
}

function Get-AppxProvCached {
    if ($null -eq $Script:Cache.Prov) {
        try { $Script:Cache.Prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) }
        catch { Write-Log ('Provisioned package list unavailable: ' + $_.Exception.Message) 'WARN'; $Script:Cache.Prov = @() }
    }
    return $Script:Cache.Prov
}

function Get-CapsCached {
    if ($null -eq $Script:Cache.Caps) {
        try { $Script:Cache.Caps = @(Get-WindowsCapability -Online -ErrorAction Stop) }
        catch { Write-Log ('Windows capability list unavailable: ' + $_.Exception.Message) 'WARN'; $Script:Cache.Caps = @() }
    }
    return $Script:Cache.Caps
}

function Get-FeatsCached {
    if ($null -eq $Script:Cache.Feats) {
        try { $Script:Cache.Feats = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop) }
        catch { Write-Log ('Optional feature list unavailable: ' + $_.Exception.Message) 'WARN'; $Script:Cache.Feats = @() }
    }
    return $Script:Cache.Feats
}

function Reset-Caches {
    param([string[]]$Kinds)
    foreach ($k in $Kinds) { $Script:Cache[$k] = $null }
}

# =============================================================================
#  7. Safe file deletion (own tree walker: never follows junctions/symlinks, long-path aware)
# =============================================================================
function Test-SafePath {
    param([string]$Path)
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    $blocked = @(
        $env:SystemDrive, $env:SystemRoot, (Join-Path $env:SystemRoot 'System32'), (Join-Path $env:SystemRoot 'SysWOW64'),
        (Join-Path $env:SystemRoot 'WinSxS'), (Join-Path $env:SystemDrive 'Users'), $env:ProgramFiles,
        ${env:ProgramFiles(x86)}, $env:ProgramData
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    foreach ($b in $blocked) { if ($full -ieq $b) { return $false } }
    return ($full.Length -gt 8)
}

function Get-PathSizeBytes {
    param([string]$Path)
    $ext = $Path
    if (($Path -match '^[A-Za-z]:\\') -and (-not $Path.StartsWith('\\?\'))) { $ext = '\\?\' + $Path }
    try {
        if ([System.IO.File]::Exists($ext)) { return [int64](New-Object System.IO.FileInfo($ext)).Length }
        $di = New-Object System.IO.DirectoryInfo($ext)
        if (-not $di.Exists) { return [int64]0 }
        $sum = [int64]0
        $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $stack.Push($di)
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            try {
                foreach ($e in $cur.EnumerateFileSystemInfos()) {
                    if ($e -is [System.IO.DirectoryInfo]) {
                        if (([int]$e.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($e) }
                    } else { $sum += [int64]$e.Length }
                }
            } catch { }
        }
        return $sum
    } catch { return [int64]0 }
}

function Remove-TreeBestEffort {
    param([string]$Path)
    $ext = $Path
    if (($Path -match '^[A-Za-z]:\\') -and (-not $Path.StartsWith('\\?\'))) { $ext = '\\?\' + $Path }
    try {
        if ([System.IO.File]::Exists($ext)) {
            [System.IO.File]::SetAttributes($ext, [System.IO.FileAttributes]::Normal)
            [System.IO.File]::Delete($ext)
            return
        }
        $di = New-Object System.IO.DirectoryInfo($ext)
        if (-not $di.Exists) { return }
        if (([int]$di.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) { $di.Delete(); return }
        foreach ($c in @($di.EnumerateFileSystemInfos())) {
            if ($c -is [System.IO.DirectoryInfo]) { Remove-TreeBestEffort -Path $c.FullName }
            else { try { $c.Attributes = [System.IO.FileAttributes]::Normal; $c.Delete() } catch { } }
        }
        try { $di.Delete() } catch { }
    } catch { }
}

function Remove-PathForce {
    param([string]$Path, [switch]$ContentsOnly, [switch]$Gentle)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-SafePath $Path)) { throw ('Refusing to delete protected path: ' + $Path) }
    $items = @()
    if ($ContentsOnly) { $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue) }
    else { $items = @(Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) }
    foreach ($t in $items) {
        if ($null -eq $t) { continue }
        Remove-TreeBestEffort -Path $t.FullName
        if ((Test-Path -LiteralPath $t.FullName) -and (-not $Gentle)) {
            if ($t.PSIsContainer) { Invoke-Native 'takeown.exe' @('/f', $t.FullName, '/r', '/d', 'Y') | Out-Null }
            else { Invoke-Native 'takeown.exe' @('/f', $t.FullName) | Out-Null }
            Invoke-Native 'icacls.exe' @($t.FullName, '/grant', '*S-1-5-32-544:F', '/t', '/c', '/q') | Out-Null
            Remove-TreeBestEffort -Path $t.FullName
        }
    }
}

# =============================================================================
#  8. Task registry  (every change = a task with an Apply step and a Verify step)
# =============================================================================
$Script:Plan       = New-Object System.Collections.Generic.List[object]
$Script:Results    = New-Object System.Collections.Generic.List[object]
$Script:FreedBytes = [int64]0

function Row {
    # One registry value. Hive = HKLM (machine) or HKU (applied to EVERY loaded user hive + Default profile).
    param([string]$Hive, [string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [switch]$Soft, [switch]$IfKey, [switch]$Delete)
    return [pscustomobject]@{ Hive = $Hive; Path = $Path; Name = $Name; Value = $Value; Type = $Type; Soft = [bool]$Soft; IfKey = [bool]$IfKey; Delete = [bool]$Delete }
}

function Add-Task {
    param([string]$Phase, [string]$Kind, [string]$Title, [hashtable]$Data, [string]$Group = '', [switch]$Soft)
    $Script:Plan.Add([pscustomobject]@{ Phase = $Phase; Kind = $Kind; Title = $Title; Data = $Data; Group = $Group; Soft = [bool]$Soft; ApplyNote = $null; ApplyError = $null })
}

function Add-RegRows {
    param([string]$Group, $Rows)
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        if ($r.Delete) { $title = 'delete {0}\{1} : {2}' -f $r.Hive, $r.Path, $r.Name }
        else { $title = '{0}\{1} : {2} = {3}' -f $r.Hive, $r.Path, $r.Name, $r.Value }
        Add-Task -Phase 'Policies & settings' -Kind 'Reg' -Title $title -Group $Group -Soft:([bool]$r.Soft) -Data @{ Hive = $r.Hive; Path = $r.Path; Name = $r.Name; Value = $r.Value; Type = $r.Type; IfKey = $r.IfKey; Delete = $r.Delete }
    }
}

function Add-ServiceSpec {
    # 'Name' = normal service, 'Name:T' = per-user service template (instances are created at logon)
    param([string]$Spec)
    $tpl = $Spec.EndsWith(':T')
    $name = $Spec
    if ($tpl) { $name = $Spec.Substring(0, $Spec.Length - 2) }
    Add-Task -Phase 'Services' -Kind 'Service' -Title ('Service disabled: ' + $name) -Soft:$tpl -Data @{ Name = $name; Template = $tpl }
}

function Add-SchedSpec {
    # 'path\|name'
    param([string]$Spec)
    $parts = $Spec -split '\|', 2
    Add-Task -Phase 'Scheduled tasks' -Kind 'Sched' -Title ('Task disabled: ' + $parts[0] + $parts[1]) -Soft -Data @{ Path = $parts[0]; Name = $parts[1] }
}

function Add-PathTask {
    param([string]$Path, [string]$Mode = 'Contents', [switch]$Tolerant, [switch]$Soft, [string[]]$StopServices = @(), [string[]]$EtsStop = @())
    Add-Task -Phase 'Cleanup' -Kind 'Path' -Title ('Clean: ' + $Path) -Soft:$Soft -Data @{ Path = $Path; Mode = $Mode; Tolerant = [bool]$Tolerant; StopServices = $StopServices; EtsStop = $EtsStop; Before = [int64]0 }
}

# -----------------------------------------------------------------------------
#  Registry values
# -----------------------------------------------------------------------------
function Invoke-ApplyReg {
    param($d)
    $n = 0
    foreach ($t in @(Get-RegTargets $d.Hive)) {
        $full = '{0}\{1}' -f $t.Root, $d.Path
        if ($d.IfKey -and (-not (Test-Path -LiteralPath $full))) { continue }
        if ($d.Delete) {
            if ($null -ne (Get-RegValue $full $d.Name)) {
                Remove-RegTracked -Full $full -Name $d.Name -RootId $t.Id -RelPath $d.Path
                $n++
            }
        } else {
            Set-RegTracked -Full $full -Name $d.Name -Value $d.Value -Type $d.Type -RootId $t.Id -RelPath $d.Path
            $n++
        }
    }
    if ($n -eq 0) { return 'absent' }
    return ('applied to {0} target(s)' -f $n)
}

function Test-StateReg {
    param($d)
    $bad = New-Object System.Collections.Generic.List[string]
    $checked = 0
    foreach ($t in @(Get-RegTargets $d.Hive)) {
        $full = '{0}\{1}' -f $t.Root, $d.Path
        if ($d.IfKey -and (-not (Test-Path -LiteralPath $full))) { continue }
        $checked++
        $cur = Get-RegValue $full $d.Name
        if ($d.Delete) {
            if ($null -ne $cur) { $bad.Add(('{0}: still present' -f $t.Id)) }
        } elseif (-not (Test-RegEqual $cur $d.Value $d.Type)) {
            $shown = '<missing>'
            if ($null -ne $cur) { $shown = [string]$cur }
            $bad.Add(('{0}: {1}' -f $t.Id, $shown))
        }
    }
    if ($bad.Count -gt 0) { return @{ Ok = $false; Detail = ('mismatch in ' + ($bad -join '; ')) } }
    return @{ Ok = $true; Detail = ('{0} target(s) verified' -f $checked) }
}

# -----------------------------------------------------------------------------
#  Services
# -----------------------------------------------------------------------------
function Invoke-ApplyService {
    param($d)
    $name = $d.Name
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $name
    if (-not (Test-Path -LiteralPath $key)) { return 'absent' }
    $start = Get-RegValue $key 'Start'
    $bkey = 'S|' + $name
    if (-not $Script:Baseline.ContainsKey($bkey)) { $Script:Baseline[$bkey] = @{ Key = $bkey; T = 'svc'; Name = $name; Start = $start } }
    foreach ($s in @(Get-Service -Name $name, ($name + '_*') -ErrorAction SilentlyContinue)) {
        if ($s.Status -ne 'Stopped') { try { Stop-Service -InputObject $s -Force -ErrorAction Stop } catch { } }
    }
    $done = $false
    if (-not $d.Template) { try { Set-Service -Name $name -StartupType Disabled -ErrorAction Stop; $done = $true } catch { } }
    if (-not $done) { Set-ItemProperty -LiteralPath $key -Name 'Start' -Value 4 -Type DWord }
    if ($start -eq 4) { return 'already disabled' }
    return 'disabled'
}

function Test-StateService {
    param($d)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $d.Name
    if (-not (Test-Path -LiteralPath $key)) { return @{ Ok = $true; Detail = 'not present' } }
    $start = Get-RegValue $key 'Start'
    $svc = Get-Service -Name $d.Name -ErrorAction SilentlyContinue
    $note = ''
    if (($null -ne $svc) -and ($svc.Status -eq 'Running')) { $note = ' (still running, stops at reboot)' }
    return @{ Ok = ($start -eq 4); Detail = ('Start={0}{1}' -f $start, $note) }
}

# -----------------------------------------------------------------------------
#  Scheduled tasks
# -----------------------------------------------------------------------------
function Invoke-ApplySched {
    param($d)
    $t = Get-ScheduledTask -TaskPath $d.Path -TaskName $d.Name -ErrorAction SilentlyContinue
    if ($null -eq $t) { return 'absent' }
    $bkey = 'T|' + $d.Path + $d.Name
    if (-not $Script:Baseline.ContainsKey($bkey)) {
        $Script:Baseline[$bkey] = @{ Key = $bkey; T = 'task'; Path = $d.Path; Name = $d.Name; Enabled = ([string]$t.State -ne 'Disabled') }
    }
    if ([string]$t.State -eq 'Disabled') { return 'already disabled' }
    try { Disable-ScheduledTask -TaskPath $d.Path -TaskName $d.Name -ErrorAction Stop | Out-Null }
    catch {
        $r = Invoke-Native 'schtasks.exe' @('/Change', '/TN', ($d.Path + $d.Name), '/DISABLE')
        if ($r.ExitCode -ne 0) { throw ('cannot disable: ' + $r.Output) }
    }
    return 'disabled'
}

function Test-StateSched {
    param($d)
    $t = Get-ScheduledTask -TaskPath $d.Path -TaskName $d.Name -ErrorAction SilentlyContinue
    if ($null -eq $t) { return @{ Ok = $true; Detail = 'not present' } }
    return @{ Ok = ([string]$t.State -eq 'Disabled'); Detail = ('state=' + [string]$t.State) }
}

# -----------------------------------------------------------------------------
#  Store (AppX) packages: installed for any user + provisioned for new users
# -----------------------------------------------------------------------------
function Invoke-ApplyAppx {
    param($d)
    $pat = $d.Pattern
    $pk = @(Get-AppxAllCached | Where-Object { ($_.Name -like $pat) -and (-not $Script:RemovedPkg.Contains([string]$_.PackageFullName)) })
    $pv = @(Get-AppxProvCached | Where-Object { ($_.DisplayName -like $pat) -and (-not $Script:RemovedProv.Contains([string]$_.PackageName)) })
    if (($pk.Count -eq 0) -and ($pv.Count -eq 0)) { return 'absent' }
    $errs = New-Object System.Collections.Generic.List[string]
    foreach ($p in $pk) {
        if ($p.NonRemovable) { $errs.Add($p.Name + ': non-removable system package'); continue }
        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
        catch {
            try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
            catch { $errs.Add($p.Name + ': ' + (([string]$_.Exception.Message) -split "`r?`n")[0]) }
        }
        [void]$Script:RemovedPkg.Add([string]$p.PackageFullName)
    }
    foreach ($p in $pv) {
        try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null }
        catch { $errs.Add('provisioned ' + $p.DisplayName + ': ' + (([string]$_.Exception.Message) -split "`r?`n")[0]) }
        [void]$Script:RemovedProv.Add([string]$p.PackageName)
    }
    if ($errs.Count -gt 0) { throw ($errs -join ' | ') }
    return ('removed {0} installed + {1} provisioned' -f $pk.Count, $pv.Count)
}

function Test-StateAppx {
    param($d)
    $pat = $d.Pattern
    $pk = @(Get-AppxAllCached | Where-Object { $_.Name -like $pat })
    $pv = @(Get-AppxProvCached | Where-Object { $_.DisplayName -like $pat })
    if (($pk.Count -eq 0) -and ($pv.Count -eq 0)) { return @{ Ok = $true; Detail = 'package gone (installed + provisioned)' } }
    return @{ Ok = $false; Detail = ('still present: {0} installed, {1} provisioned' -f $pk.Count, $pv.Count) }
}

# -----------------------------------------------------------------------------
#  Windows capabilities and optional features
# -----------------------------------------------------------------------------
function Invoke-ApplyCap {
    param($d)
    $c = @(Get-CapsCached | Where-Object { ($_.Name -like $d.Pattern) -and ([string]$_.State -eq 'Installed') })
    if ($c.Count -eq 0) { return 'absent' }
    foreach ($x in $c) { Remove-WindowsCapability -Online -Name $x.Name -ErrorAction Stop | Out-Null }
    return ('removed: ' + (($c | ForEach-Object { $_.Name }) -join ', '))
}

function Test-StateCap {
    param($d)
    $c = @(Get-CapsCached | Where-Object { ($_.Name -like $d.Pattern) -and ([string]$_.State -eq 'Installed') })
    if ($c.Count -eq 0) { return @{ Ok = $true; Detail = 'not installed' } }
    return @{ Ok = $false; Detail = ('still installed: ' + (($c | ForEach-Object { $_.Name }) -join ', ')) }
}

function Invoke-ApplyFeature {
    param($d)
    $f = @(Get-FeatsCached | Where-Object { $_.FeatureName -eq $d.Name })
    if ($f.Count -eq 0) { return 'absent' }
    $st = [string]$f[0].State
    if ($st -like 'Disabled*') { return 'already off' }
    try { Disable-WindowsOptionalFeature -Online -FeatureName $d.Name -Remove -NoRestart -ErrorAction Stop | Out-Null }
    catch { Disable-WindowsOptionalFeature -Online -FeatureName $d.Name -NoRestart -ErrorAction Stop | Out-Null }
    return 'disabled'
}

function Test-StateFeature {
    param($d)
    $f = @(Get-FeatsCached | Where-Object { $_.FeatureName -eq $d.Name })
    if ($f.Count -eq 0) { return @{ Ok = $true; Detail = 'not present' } }
    $st = [string]$f[0].State
    return @{ Ok = ($st -like 'Disabled*'); Detail = ('state=' + $st) }
}

# -----------------------------------------------------------------------------
#  Files and folders (size before / after, verified by looking at the disk again)
# -----------------------------------------------------------------------------
function Invoke-ApplyPath {
    param($d)
    $p = $d.Path
    if (-not (Test-Path -LiteralPath $p)) { $d.Before = [int64]0; return 'absent' }
    if (-not (Test-SafePath $p)) { throw ('refusing protected path ' + $p) }
    $d.Before = Get-PathSizeBytes $p
    $wasRunning = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($d.StopServices)) {
        if (-not $s) { continue }
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if (($null -ne $svc) -and ($svc.Status -eq 'Running')) {
            try { Stop-Service -Name $s -Force -ErrorAction Stop; $wasRunning.Add($s) } catch { }
        }
    }
    foreach ($e in @($d.EtsStop)) {
        if ($e) { Invoke-Native 'logman.exe' @('stop', $e, '-ets') | Out-Null }
    }
    try {
        if ($d.Mode -eq 'Self') { Remove-PathForce -Path $p -Gentle:([bool]$d.Tolerant) }
        else { Remove-PathForce -Path $p -ContentsOnly -Gentle:([bool]$d.Tolerant) }
    } finally {
        foreach ($s in $wasRunning) { try { Start-Service -Name $s -ErrorAction SilentlyContinue } catch { } }
    }
    return ('cleaned ' + (Format-Size $d.Before))
}

function Test-StatePath {
    param($d)
    $p = $d.Path
    $before = [int64]$d.Before
    if (-not (Test-Path -LiteralPath $p)) {
        $Script:FreedBytes += $before
        return @{ Ok = $true; Detail = ('gone, freed ' + (Format-Size $before)) }
    }
    $left = Get-PathSizeBytes $p
    if ($d.Mode -eq 'Self') { return @{ Ok = $false; Detail = ('still exists (' + (Format-Size $left) + ' left)') } }
    $items = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)
    $freed = $before - $left
    if ($freed -gt 0) { $Script:FreedBytes += $freed }
    if ($items.Count -eq 0) { return @{ Ok = $true; Detail = ('emptied, freed ' + (Format-Size $before)) } }
    $detail = '{0} item(s) / {1} left (in use or protected), freed {2}' -f $items.Count, (Format-Size $left), (Format-Size ([math]::Max($freed, 0)))
    if ($d.Tolerant -and (($left -lt 10MB) -or ($left -le ($before * 0.1)))) { return @{ Ok = $true; Detail = $detail } }
    return @{ Ok = $false; Detail = $detail }
}

# -----------------------------------------------------------------------------
#  Firewall: outbound blocks for the telemetry binaries (survive a re-enabled service)
# -----------------------------------------------------------------------------
function Get-FirewallRuleDefs {
    $sys32 = Join-Path $env:SystemRoot 'System32'
    return @(
        @{ Name = 'DiagTrack service (outbound)'; Service = 'DiagTrack'; Program = $null },
        @{ Name = 'CompatTelRunner.exe (outbound)'; Service = $null; Program = (Join-Path $sys32 'CompatTelRunner.exe') },
        @{ Name = 'DeviceCensus.exe (outbound)'; Service = $null; Program = (Join-Path $sys32 'DeviceCensus.exe') },
        @{ Name = 'wsqmcons.exe (outbound)'; Service = $null; Program = (Join-Path $sys32 'wsqmcons.exe') }
    )
}

function Invoke-ApplyFirewall {
    param($d)
    $n = 0
    foreach ($r in @(Get-FirewallRuleDefs)) {
        $dn = 'Win11DeepDebloat: ' + $r.Name
        if ($r.Program -and (-not (Test-Path -LiteralPath $r.Program))) { continue }
        Get-NetFirewallRule -DisplayName $dn -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        $p = @{ DisplayName = $dn; Group = 'Win11DeepDebloat'; Direction = 'Outbound'; Action = 'Block'; Profile = 'Any'; Enabled = 'True' }
        if ($r.Service) { $p['Service'] = $r.Service }
        if ($r.Program) { $p['Program'] = $r.Program }
        New-NetFirewallRule @p | Out-Null
        $n++
    }
    return ('{0} outbound block rule(s) active' -f $n)
}

function Test-StateFirewall {
    param($d)
    $missing = New-Object System.Collections.Generic.List[string]
    $count = 0
    foreach ($r in @(Get-FirewallRuleDefs)) {
        if ($r.Program -and (-not (Test-Path -LiteralPath $r.Program))) { continue }
        $count++
        $rule = Get-NetFirewallRule -DisplayName ('Win11DeepDebloat: ' + $r.Name) -ErrorAction SilentlyContinue
        if (($null -eq $rule) -or ([string]$rule.Enabled -ne 'True')) { $missing.Add($r.Name) }
    }
    if ($missing.Count -gt 0) { return @{ Ok = $false; Detail = ('missing or disabled: ' + ($missing -join ', ')) } }
    return @{ Ok = $true; Detail = ('{0} rule(s) present and enabled' -f $count) }
}

# -----------------------------------------------------------------------------
#  Defender: stop sending samples, keep protection and basic cloud lookups
# -----------------------------------------------------------------------------
function Invoke-ApplyDefender {
    param($d)
    $mp = Get-MpPreference -ErrorAction Stop
    $bkey = 'D|prefs'
    if (-not $Script:Baseline.ContainsKey($bkey)) {
        $Script:Baseline[$bkey] = @{ Key = $bkey; T = 'mp'; Submit = [int]$mp.SubmitSamplesConsent; Maps = [int]$mp.MAPSReporting }
    }
    Set-MpPreference -SubmitSamplesConsent NeverSend -MAPSReporting Basic -ErrorAction Stop
    return 'sample submission: never; cloud reporting: basic'
}

function Test-StateDefender {
    param($d)
    $mp = Get-MpPreference -ErrorAction Stop
    $s = [int]$mp.SubmitSamplesConsent
    $m = [int]$mp.MAPSReporting
    return @{ Ok = (($s -eq 2) -and ($m -eq 1)); Detail = ('SubmitSamplesConsent={0}; MAPSReporting={1}' -f $s, $m) }
}

# -----------------------------------------------------------------------------
#  Component store + hibernation
# -----------------------------------------------------------------------------
function Invoke-ApplyComponentCleanup {
    param($d)
    $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    if ($d.ResetBase) { $dismArgs += '/ResetBase' }
    $before = Get-FreeBytes
    $r = Invoke-Native 'dism.exe' $dismArgs
    $d.ExitCode = $r.ExitCode
    $d.Freed = (Get-FreeBytes) - $before
    if (@(0, 3010) -notcontains $r.ExitCode) {
        $tail = (($r.Output -split "`r?`n") | Select-Object -Last 3) -join ' '
        throw ('DISM exit code {0}: {1}' -f $r.ExitCode, $tail)
    }
    return ('DISM finished, free space change ' + (Format-Size ([math]::Max($d.Freed, 0))))
}

function Test-StateComponentCleanup {
    param($d)
    if ($null -eq $d.ExitCode) { return @{ Ok = $true; Detail = 'not run in this mode' } }
    return @{ Ok = (@(0, 3010) -contains $d.ExitCode); Detail = ('DISM exit code {0}' -f $d.ExitCode) }
}

function Invoke-ApplyHibernate {
    param($d)
    $r = Invoke-Native 'powercfg.exe' @('/hibernate', 'off')
    if ($r.ExitCode -ne 0) { throw ('powercfg failed: ' + $r.Output) }
    return 'hibernation off'
}

function Test-StateHibernate {
    param($d)
    $gone = -not (Test-Path -LiteralPath (Join-Path $env:SystemDrive 'hiberfil.sys'))
    $msg = 'hiberfil.sys still present'
    if ($gone) { $msg = 'hiberfil.sys removed' }
    return @{ Ok = $gone; Detail = $msg }
}

# -----------------------------------------------------------------------------
#  Microsoft Edge (browser only; WebView2 runtime and Edge Update are left alone on purpose)
# -----------------------------------------------------------------------------
function Get-InstalledBrowsers {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($root in @('HKLM:\SOFTWARE\Clients\StartMenuInternet', 'HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $n = $k.PSChildName
            if (($n -notmatch 'Edge|IEXPLORE') -and (-not $names.Contains($n))) { $names.Add($n) }
        }
    }
    return $names.ToArray()
}

function Test-EdgePresent {
    $x86 = ${env:ProgramFiles(x86)}
    if (-not $x86) { $x86 = $env:ProgramFiles }
    return (Test-Path -LiteralPath (Join-Path $x86 'Microsoft\Edge\Application\msedge.exe'))
}

function Invoke-ApplyEdge {
    param($d)
    if (@(Get-InstalledBrowsers).Count -eq 0) { throw 'No other web browser is installed. Install one first (for example: winget install Mozilla.Firefox).' }
    Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $uk = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
    if (-not (Test-Path -LiteralPath $uk)) { $uk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' }
    if (-not (Test-Path -LiteralPath $uk)) { return 'absent' }
    $us = [string](Get-RegValue $uk 'UninstallString')
    if (-not $us) { throw 'Edge uninstall command not found in the registry.' }
    Set-RegTracked -Full $uk -Name 'NoRemove' -Value 0 -Type 'DWord' -RootId 'HKLM' -RelPath ($uk -replace '^HKLM:\\', '')
    $cl = Split-CommandLine $us
    $a = [string]$cl.Arguments
    if ($a -notmatch '--force-uninstall') { $a = ($a + ' --force-uninstall').Trim() }
    if ($a -notmatch '--system-level') { $a = ($a + ' --system-level').Trim() }
    $r = Start-ProcessWait -File $cl.File -Arguments $a -TimeoutSec 900
    if ($r.TimedOut) { throw 'Edge uninstaller timed out.' }
    foreach ($lnk in @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk'), (Join-Path $env:PUBLIC 'Desktop\Microsoft Edge.lnk'))) {
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
    }
    return ('uninstaller exit code ' + $r.ExitCode)
}

function Test-StateEdge {
    param($d)
    $left = New-Object System.Collections.Generic.List[string]
    if (Test-EdgePresent) { $left.Add('msedge.exe still installed') }
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge')) {
        if (Test-Path -LiteralPath $k) { $left.Add('uninstall entry still registered') }
    }
    if ($left.Count -eq 0) { return @{ Ok = $true; Detail = 'Edge browser is gone (WebView2 kept)' } }
    return @{ Ok = $false; Detail = ('left: ' + ($left -join '; ') + ' - Windows blocks Edge removal on some builds') }
}

# -----------------------------------------------------------------------------
#  OneDrive (refuses to run while Known Folder Move redirects your folders into OneDrive)
# -----------------------------------------------------------------------------
function Get-OneDriveKfm {
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($Script:UserRoots)) {
        $usf = $r.Root + '\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        if (-not (Test-Path -LiteralPath $usf)) { continue }
        $k = Get-Item -LiteralPath $usf -ErrorAction SilentlyContinue
        if ($null -eq $k) { continue }
        foreach ($n in $k.GetValueNames()) {
            $v = [string]$k.GetValue($n, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($v -match 'OneDrive') { $hits.Add(('{0}: {1}' -f $n, $v)) }
        }
    }
    return $hits.ToArray()
}

function Test-OneDrivePresent {
    if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe')) { return $true }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe') { return $true }
    foreach ($p in @(Get-ProfilePaths)) {
        if (Test-Path -LiteralPath (Join-Path $p 'AppData\Local\Microsoft\OneDrive\OneDrive.exe')) { return $true }
    }
    return $false
}

function Invoke-ApplyOneDrive {
    param($d)
    $kfm = @(Get-OneDriveKfm)
    if ($kfm.Count -gt 0) { throw ('OneDrive Known Folder Move is active (' + ($kfm -join '; ') + '). Move the folders back first.') }
    Get-Process -Name 'OneDrive', 'OneDriveStandaloneUpdater', 'FileCoAuth' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $cmds = New-Object System.Collections.Generic.List[object]
    foreach ($rk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe')) {
        if (Test-Path -LiteralPath $rk) {
            $us = [string](Get-RegValue $rk 'UninstallString')
            if ($us) { $cmds.Add((Split-CommandLine $us)) }
        }
    }
    foreach ($exe in @((Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'), (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'))) {
        if (Test-Path -LiteralPath $exe) { $cmds.Add([pscustomobject]@{ File = $exe; Arguments = '/uninstall' }) }
    }
    $seen = @{}
    foreach ($c in $cmds) {
        $sig = ($c.File + '|' + $c.Arguments).ToLowerInvariant()
        if ($seen.ContainsKey($sig)) { continue }
        $seen[$sig] = $true
        if (-not (Test-Path -LiteralPath $c.File)) { continue }
        [void](Start-ProcessWait -File $c.File -Arguments $c.Arguments -TimeoutSec 300)
    }
    foreach ($t in @(Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue)) {
        try { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop } catch { }
    }
    foreach ($p in @(Get-ProfilePaths)) {
        Remove-PathForce -Path (Join-Path $p 'AppData\Local\Microsoft\OneDrive')
        $od = Join-Path $p 'OneDrive'
        if (Test-Path -LiteralPath $od) {
            $files = @(Get-ChildItem -LiteralPath $od -Recurse -Force -File -ErrorAction SilentlyContinue)
            if ($files.Count -eq 0) { Remove-PathForce -Path $od }
            else { Write-Log ('Kept {0} (it still contains {1} file(s))' -f $od, $files.Count) 'WARN' }
        }
    }
    foreach ($x in @((Join-Path $env:ProgramData 'Microsoft OneDrive'), (Join-Path $env:SystemDrive 'OneDriveTemp'), (Join-Path $env:ProgramFiles 'Microsoft OneDrive'))) {
        Remove-PathForce -Path $x
    }
    return 'uninstalled'
}

function Test-StateOneDrive {
    param($d)
    $left = New-Object System.Collections.Generic.List[string]
    if (Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue) { $left.Add('process running') }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe') { $left.Add('machine-wide uninstall entry') }
    if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe')) { $left.Add('per-machine OneDrive.exe') }
    foreach ($p in @(Get-ProfilePaths)) {
        if (Test-Path -LiteralPath (Join-Path $p 'AppData\Local\Microsoft\OneDrive\OneDrive.exe')) { $left.Add('OneDrive.exe in ' + $p) }
    }
    foreach ($r in @($Script:UserRoots)) {
        if (Test-Path -LiteralPath ($r.Root + '\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe')) { $left.Add('uninstall entry in profile ' + $r.Id + ' (run the script as that user)') }
    }
    if ($left.Count -eq 0) { return @{ Ok = $true; Detail = 'OneDrive is gone' } }
    return @{ Ok = $false; Detail = ('left: ' + ($left -join '; ')) }
}

# -----------------------------------------------------------------------------
#  Microsoft Office / Microsoft 365 desktop apps (whole suite: Click-to-Run or MSI)
# -----------------------------------------------------------------------------
function Get-OfficeArp {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $dn = [string]$k.GetValue('DisplayName', '')
            $us = [string]$k.GetValue('UninstallString', '')
            if ((-not $dn) -or (-not $us)) { continue }
            if ($dn -match 'Teams|OneDrive|Edge|WebView') { continue }
            if (($us -match 'OfficeClickToRun\.exe') -or (($dn -match '^Microsoft (Office|365)') -and ($us -match '(?i)msiexec'))) {
                $out.Add([pscustomobject]@{ Name = $dn; Uninstall = $us })
            }
        }
    }
    return $out.ToArray()
}

function Invoke-ApplyOffice {
    param($d)
    if (@(Get-OfficeArp).Count -eq 0) { return 'absent' }
    $procNames = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'MSACCESS', 'MSPUB', 'VISIO', 'WINPROJ')
    if (@(Get-Process -Name $procNames -ErrorAction SilentlyContinue).Count -gt 0) {
        try { [void](Read-Host 'Office apps are running. Save your work and close them, then press Enter') }
        catch { throw 'Office apps are running - save your work and close them, then run again.' }
        Get-Process -Name $procNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    $guard = 0
    while ($guard -lt 6) {
        $entries = @(Get-OfficeArp)
        if ($entries.Count -eq 0) { break }
        $guard++
        $e = $entries[0]
        if ($e.Uninstall -match 'OfficeClickToRun\.exe') {
            $cl = Split-CommandLine $e.Uninstall
            $a = [string]$cl.Arguments
            if ($a -notmatch '(?i)DisplayLevel') { $a = ($a + ' DisplayLevel=False').Trim() }
            if ($a -notmatch '(?i)forceappshutdown') { $a = ($a + ' forceappshutdown=True').Trim() }
            $r = Start-ProcessWait -File $cl.File -Arguments $a -TimeoutSec 1800
        } else {
            $guid = [regex]::Match($e.Uninstall, '\{[0-9A-Fa-f-]{36}\}').Value
            if (-not $guid) { break }
            $r = Start-ProcessWait -File 'msiexec.exe' -Arguments ('/x {0} /qn /norestart' -f $guid) -TimeoutSec 1800
        }
        if ($r.TimedOut) { throw 'Office uninstaller timed out.' }
        Start-Sleep -Seconds 3
    }
    return ('uninstall passes: ' + $guard)
}

function Test-StateOffice {
    param($d)
    $left = @(Get-OfficeArp)
    $exe = New-Object System.Collections.Generic.List[string]
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $pf) { continue }
        foreach ($rel in @('Microsoft Office\root\Office16\WINWORD.EXE', 'Microsoft Office\Office16\WINWORD.EXE')) {
            $f = Join-Path $pf $rel
            if (Test-Path -LiteralPath $f) { $exe.Add($f) }
        }
    }
    if (($left.Count -eq 0) -and ($exe.Count -eq 0)) { return @{ Ok = $true; Detail = 'Office is gone' } }
    return @{ Ok = $false; Detail = ('left: {0} uninstall entr(ies), {1} WINWORD.EXE' -f $left.Count, $exe.Count) }
}

# -----------------------------------------------------------------------------
#  Teams Machine-Wide Installer (classic Teams bootstrapper)
# -----------------------------------------------------------------------------
function Get-TeamsMwi {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            if ([string]$k.GetValue('DisplayName', '') -eq 'Teams Machine-Wide Installer') {
                $out.Add([pscustomobject]@{ Name = 'Teams Machine-Wide Installer'; Guid = $k.PSChildName })
            }
        }
    }
    return $out.ToArray()
}

function Invoke-ApplyTeamsMwi {
    param($d)
    $e = @(Get-TeamsMwi)
    if ($e.Count -eq 0) { return 'absent' }
    foreach ($x in $e) {
        $r = Start-ProcessWait -File 'msiexec.exe' -Arguments ('/x {0} /qn /norestart' -f $x.Guid) -TimeoutSec 600
        if ($r.TimedOut) { throw 'Teams installer removal timed out.' }
    }
    return 'uninstalled'
}

function Test-StateTeamsMwi {
    param($d)
    if (@(Get-TeamsMwi).Count -eq 0) { return @{ Ok = $true; Detail = 'Machine-Wide Installer is gone' } }
    return @{ Ok = $false; Detail = 'Machine-Wide Installer still registered' }
}

# -----------------------------------------------------------------------------
#  Dispatch
# -----------------------------------------------------------------------------
function Invoke-TaskApply {
    param($T)
    $d = $T.Data
    switch ($T.Kind) {
        'Reg'     { return (Invoke-ApplyReg $d) }
        'Service' { return (Invoke-ApplyService $d) }
        'Sched'   { return (Invoke-ApplySched $d) }
        'Appx'    { return (Invoke-ApplyAppx $d) }
        'Cap'     { return (Invoke-ApplyCap $d) }
        'Feature' { return (Invoke-ApplyFeature $d) }
        'Path'    { return (Invoke-ApplyPath $d) }
        'Custom'  { return (& $d.ApplyFn $d) }
        default   { throw ('Unknown task kind: ' + $T.Kind) }
    }
}

function Test-TaskState {
    param($T)
    $d = $T.Data
    switch ($T.Kind) {
        'Reg'     { return (Test-StateReg $d) }
        'Service' { return (Test-StateService $d) }
        'Sched'   { return (Test-StateSched $d) }
        'Appx'    { return (Test-StateAppx $d) }
        'Cap'     { return (Test-StateCap $d) }
        'Feature' { return (Test-StateFeature $d) }
        'Path'    { return (Test-StatePath $d) }
        'Custom'  { return (& $d.VerifyFn $d) }
        default   { throw ('Unknown task kind: ' + $T.Kind) }
    }
}

# =============================================================================
#  9. What is ALWAYS handled (no questions): telemetry, tracking, ads, junk
# =============================================================================
$Script:AlwaysServices = @(
    'DiagTrack',                                  # Connected User Experiences and Telemetry
    'dmwappushservice',                           # WAP push routing (telemetry / MDM plumbing)
    'diagnosticshub.standardcollector.service',   # Diagnostics Hub collector
    'WerSvc',                                     # Windows Error Reporting
    'RetailDemo',                                 # Retail demo mode
    'WMPNetworkSvc',                              # Media Player network sharing
    'MixedRealityOpenXRSvc',                      # Windows Mixed Reality (retired)
    'SharedRealitySvc'                            # Spatial data service (retired)
)

$Script:AlwaysTasks = @(
    '\Microsoft\Windows\Application Experience\|Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\|ProgramDataUpdater',
    '\Microsoft\Windows\Application Experience\|StartupAppTask',
    '\Microsoft\Windows\Application Experience\|MareBackup',
    '\Microsoft\Windows\Autochk\|Proxy',
    '\Microsoft\Windows\Customer Experience Improvement Program\|Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\|KernelCeipTask',
    '\Microsoft\Windows\Customer Experience Improvement Program\|UsbCeip',
    '\Microsoft\Windows\Customer Experience Improvement Program\|BthSQM',
    '\Microsoft\Windows\DiskDiagnostic\|Microsoft-Windows-DiskDiagnosticDataCollector',
    '\Microsoft\Windows\Feedback\Siuf\|DmClient',
    '\Microsoft\Windows\Feedback\Siuf\|DmClientOnScenarioDownload',
    '\Microsoft\Windows\Windows Error Reporting\|QueueReporting',
    '\Microsoft\Windows\NetTrace\|GatherNetworkInfo',
    '\Microsoft\Windows\Device Information\|Device',
    '\Microsoft\Windows\Device Information\|Device User',
    '\Microsoft\Windows\Flighting\OneSettings\|RefreshCache',
    '\Microsoft\Windows\SettingSync\|BackgroundUploadTask',
    '\Microsoft\Windows\SettingSync\|NetworkStateChangeTask',
    '\Microsoft\Office\|OfficeTelemetryAgentFallBack',
    '\Microsoft\Office\|OfficeTelemetryAgentFallBack2016',
    '\Microsoft\Office\|OfficeTelemetryAgentLogOn',
    '\Microsoft\Office\|OfficeTelemetryAgentLogOn2016'
)

$Script:AlwaysFeatures = @(
    'Recall',                                     # Windows Recall (Copilot+ PCs)
    'MicrosoftWindowsPowerShellV2Root',           # PowerShell 2.0 (downgrade-attack surface)
    'MicrosoftWindowsPowerShellV2',
    'WorkFolders-Client',
    'Printing-XPSServices-Features',
    'FaxServicesClientPackage'
)

$Script:AlwaysCaps = @('App.StepsRecorder*', 'Microsoft.Windows.WordPad*', 'MathRecognizer*')

$Script:AlwaysAppx = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.BingFinance', 'Microsoft.BingSports',
    'Microsoft.BingTravel', 'Microsoft.BingFoodAndDrink', 'Microsoft.BingHealthAndFitness', 'Microsoft.549981C3F5F10',
    'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.WindowsFeedbackHub', 'Microsoft.MSPaint', 'Microsoft.Microsoft3DViewer', 'Microsoft.Print3D',
    'Microsoft.MixedReality.Portal', 'Microsoft.SkypeApp', 'Microsoft.Wallet', 'Microsoft.OneConnect', 'Microsoft.Messaging',
    'Microsoft.Office.Sway', 'Microsoft.MicrosoftPowerBIForWindows', 'Microsoft.WindowsReadingList'
)
$Script:AlwaysAppxSoft = @('MicrosoftWindows.Client.WebExperience')   # Widgets host: protected on some builds

# =============================================================================
#  10. Optional items (Y/N per item). Def = default answer. Only items that exist are asked.
# =============================================================================
$Script:Catalog = @(
    @{ Cat = 'Microsoft apps'; Id = 'camera'; Name = 'Camera app'; Def = 'N'
       Desc = 'Only the Camera app. Webcams keep working in browsers, Teams, Zoom ...'
       Appx = @('Microsoft.WindowsCamera') },
    @{ Cat = 'Microsoft apps'; Id = 'photos'; Name = 'Photos'; Def = 'N'
       Desc = 'Default image viewer and editor.'
       Warn = 'Install another image viewer first, otherwise pictures have no default app.'
       Appx = @('Microsoft.Windows.Photos', 'Microsoft.Photos.MediaEngineDLC') },
    @{ Cat = 'Microsoft apps'; Id = 'paint'; Name = 'Paint'; Def = 'N'
       Desc = 'The Paint app.'
       Appx = @('Microsoft.Paint') },
    @{ Cat = 'Microsoft apps'; Id = 'snip'; Name = 'Snipping Tool'; Def = 'N'
       Desc = 'Screenshot tool (Win+Shift+S uses it).'
       Appx = @('Microsoft.ScreenSketch') },
    @{ Cat = 'Microsoft apps'; Id = 'notepad'; Name = 'Notepad'; Def = 'N'
       Desc = 'The Store version of Notepad.'
       Warn = 'Only remove it if you use another text editor.'
       Appx = @('Microsoft.WindowsNotepad') },
    @{ Cat = 'Microsoft apps'; Id = 'calc'; Name = 'Calculator'; Def = 'N'
       Desc = 'The Calculator app.'
       Appx = @('Microsoft.WindowsCalculator') },
    @{ Cat = 'Microsoft apps'; Id = 'clock'; Name = 'Alarms & Clock'; Def = 'N'
       Desc = 'Alarms, timers, world clock, focus sessions.'
       Appx = @('Microsoft.WindowsAlarms') },
    @{ Cat = 'Microsoft apps'; Id = 'sticky'; Name = 'Sticky Notes'; Def = 'N'
       Desc = 'Sticky Notes (syncs to your Microsoft account).'
       Appx = @('Microsoft.MicrosoftStickyNotes') },
    @{ Cat = 'Microsoft apps'; Id = 'media'; Name = 'Media Player + Movies & TV'; Def = 'Y'
       Desc = 'The new Media Player and the Movies & TV app.'
       Appx = @('Microsoft.ZuneMusic', 'Microsoft.ZuneVideo') },
    @{ Cat = 'Microsoft apps'; Id = 'recorder'; Name = 'Sound Recorder'; Def = 'Y'
       Desc = 'The Sound Recorder app.'
       Appx = @('Microsoft.WindowsSoundRecorder') },
    @{ Cat = 'Microsoft apps'; Id = 'todo'; Name = 'Microsoft To Do'; Def = 'Y'
       Desc = 'To Do (syncs to your Microsoft account).'
       Appx = @('Microsoft.Todos') },
    @{ Cat = 'Microsoft apps'; Id = 'mail'; Name = 'Mail & Calendar + People (retired apps)'; Def = 'Y'
       Desc = 'The old Mail, Calendar and People apps plus their sync services.'
       Appx = @('microsoft.windowscommunicationsapps', 'Microsoft.People')
       Services = @('OneSyncSvc:T', 'PimIndexMaintenanceSvc:T') },
    @{ Cat = 'Microsoft apps'; Id = 'outlook'; Name = 'New Outlook'; Def = 'Y'
       Desc = 'The new Outlook for Windows app (not the classic Outlook that comes with Office).'
       Appx = @('Microsoft.OutlookForWindows') },
    @{ Cat = 'Microsoft apps'; Id = 'onenote'; Name = 'OneNote (Store app)'; Def = 'Y'
       Desc = 'The OneNote Store app.'
       Appx = @('Microsoft.Office.OneNote') },
    @{ Cat = 'Microsoft apps'; Id = 'maps'; Name = 'Maps'; Def = 'Y'
       Desc = 'Maps app, offline-maps service and its scheduled tasks.'
       Appx = @('Microsoft.WindowsMaps')
       Services = @('MapsBroker')
       Tasks = @('\Microsoft\Windows\Maps\|MapsToastTask', '\Microsoft\Windows\Maps\|MapsUpdateTask') },
    @{ Cat = 'Microsoft apps'; Id = 'phone'; Name = 'Phone Link / Cross Device'; Def = 'Y'
       Desc = 'Phone Link (mirrors phone notifications, calls and photos to the PC).'
       Appx = @('Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice')
       Services = @('PhoneSvc') },
    @{ Cat = 'Microsoft apps'; Id = 'teams'; Name = 'Microsoft Teams (chat app + machine-wide installer)'; Def = 'Y'
       Desc = 'The built-in Teams chat app and the old Teams bootstrapper.'
       Appx = @('MicrosoftTeams', 'MSTeams')
       Custom = 'teams' },
    @{ Cat = 'Microsoft apps'; Id = 'clipchamp'; Name = 'Clipchamp'; Def = 'Y'
       Desc = 'Video editor (pushes a paid subscription).'
       Appx = @('Clipchamp.Clipchamp') },
    @{ Cat = 'Microsoft apps'; Id = 'devhome'; Name = 'Dev Home'; Def = 'Y'
       Desc = 'Dev Home dashboard (retired by Microsoft).'
       Appx = @('Microsoft.Windows.DevHome') },
    @{ Cat = 'Microsoft apps'; Id = 'pa'; Name = 'Power Automate'; Def = 'Y'
       Desc = 'Power Automate Desktop.'
       Appx = @('Microsoft.PowerAutomateDesktop') },
    @{ Cat = 'Microsoft apps'; Id = 'quickassist'; Name = 'Quick Assist'; Def = 'Y'
       Desc = 'Remote-help tool (also abused by tech-support scammers).'
       Appx = @('MicrosoftCorporationII.QuickAssist')
       Caps = @('App.Support.QuickAssist*') },
    @{ Cat = 'Microsoft apps'; Id = 'family'; Name = 'Microsoft Family Safety'; Def = 'Y'
       Desc = 'Parental controls app and its activity-reporting tasks.'
       Warn = 'Keep it if this PC is used by a child account you supervise.'
       Appx = @('MicrosoftCorporationII.MicrosoftFamily')
       Tasks = @('\Microsoft\Windows\Shell\|FamilySafetyMonitor', '\Microsoft\Windows\Shell\|FamilySafetyRefreshTask') },
    @{ Cat = 'Microsoft apps'; Id = 'misc'; Name = 'Journal, Whiteboard, Network Speed Test'; Def = 'Y'
       Desc = 'Small Store apps most people never open.'
       Appx = @('Microsoft.MicrosoftJournal', 'Microsoft.Whiteboard', 'Microsoft.NetworkSpeedTest') },
    @{ Cat = 'Microsoft apps'; Id = 'copilot'; Name = 'Copilot app'; Def = 'Y'
       Desc = 'The Copilot app (the Recall / Click to Do features are always disabled anyway).'
       Appx = @('Microsoft.Copilot') },
    @{ Cat = 'Gaming'; Id = 'xbox'; Name = 'Xbox app, Game Bar and gaming services'; Def = 'N'
       Desc = 'Xbox app, Game Bar overlay, Xbox sign-in components, Xbox background services, Game DVR.'
       Warn = 'Needed for Game Pass, the Minecraft launcher sign-in and many Microsoft Store games.'
       Appx = @('Microsoft.GamingApp', 'Microsoft.XboxApp', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.Xbox.TCUI', 'Microsoft.GamingServices')
       Services = @('XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc')
       Reg = @(
           (Row 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0),
           (Row 'HKU' 'System\GameConfigStore' 'GameDVR_Enabled' 0),
           (Row 'HKU' 'Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0),
           (Row 'HKU' 'Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0)
       ) },
    @{ Cat = 'Desktop software'; Id = 'office'; Name = 'Microsoft Office / Microsoft 365 desktop apps (Word, Excel, PowerPoint, Outlook ...)'; Def = 'N'
       Desc = 'Removes the WHOLE Office suite (Click-to-Run, MSI or Store edition). Removing only Word is not possible offline.'
       Warn = 'Save and close all Office documents first. Your licence stays in your Microsoft account.'
       Appx = @('Microsoft.Office.Desktop*')
       Custom = 'office' },
    @{ Cat = 'Desktop software'; Id = 'onedrive'; Name = 'OneDrive'; Def = 'N'
       Desc = 'Uninstalls OneDrive, its tasks and its Explorer entry, and blocks the sync client by policy.'
       Warn = 'Refused automatically if Desktop/Documents/Pictures are redirected into OneDrive.'
       Custom = 'onedrive'
       Reg = @(
           (Row 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1),
           (Row 'HKU' 'Software\Microsoft\Windows\CurrentVersion\Run' 'OneDrive' $null -Delete),
           (Row 'HKU' 'Software\Microsoft\Windows\CurrentVersion\Run' 'OneDriveSetup' $null -Delete),
           (Row 'HKU' 'Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' 'System.IsPinnedToNameSpaceTree' 0 -Soft)
       ) },
    @{ Cat = 'Desktop software'; Id = 'edge'; Name = 'Microsoft Edge (browser)'; Def = 'N'
       Desc = 'Uninstalls the Edge browser. The WebView2 runtime stays (apps need it). Needs another browser installed.'
       Warn = 'Not officially supported outside the EEA: a Windows update may bring Edge back. Re-run the script after updates.'
       Custom = 'edge'
       Reg = @(
           (Row 'HKLM' 'SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 0 -Soft),
           (Row 'HKLM' 'SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' 1 -Soft)
       ) },
    @{ Cat = 'Services & features'; Id = 'search_index'; Name = 'Windows Search indexing service'; Def = 'N'
       Desc = 'Stops the background indexer (less disk and CPU use).'
       Warn = 'Start-menu and Explorer search become slower; Outlook search suffers.'
       Services = @('WSearch') },
    @{ Cat = 'Services & features'; Id = 'spooler'; Name = 'Printing (Print Spooler)'; Def = 'N'
       Desc = 'Turns off the print spooler and printer notifications.'
       Warn = 'No printer, no "Microsoft Print to PDF".'
       Services = @('Spooler', 'PrintNotify') },
    @{ Cat = 'Services & features'; Id = 'bluetooth'; Name = 'Bluetooth services'; Def = 'N'
       Desc = 'Turns off Bluetooth support.'
       Warn = 'Bluetooth mice, keyboards, headphones and controllers stop working.'
       Services = @('bthserv', 'BTAGService', 'BthAvctpSvc', 'BluetoothUserService:T') },
    @{ Cat = 'Services & features'; Id = 'location'; Name = 'Location services + Find My Device'; Def = 'Y'
       Desc = 'Turns off the location platform and Find My Device.'
       Warn = 'Automatic time zone, Night light by sunset and weather features stop working.'
       Services = @('lfsvc')
       Reg = @(
           (Row 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1),
           (Row 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableWindowsLocationProvider' 1),
           (Row 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocationScripting' 1),
           (Row 'HKLM' 'SOFTWARE\Policies\Microsoft\FindMyDevice' 'AllowFindMyDevice' 0),
           (Row 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String' -Soft)
       ) },
    @{ Cat = 'Services & features'; Id = 'pca'; Name = 'Program Compatibility Assistant'; Def = 'Y'
       Desc = 'Stops the "this program might not have installed correctly" pop-ups and the compatibility database updates.'
       Services = @('PcaSvc')
       Tasks = @('\Microsoft\Windows\Application Experience\|PcaPatchDbTask')
       Reg = @( (Row 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisablePCA' 1) ) },
    @{ Cat = 'Services & features'; Id = 'webcam'; Name = 'Webcam frame server'; Def = 'N'
       Desc = 'Turns off the Windows Camera Frame Server.'
       Warn = 'Some apps (browsers, Teams, Zoom) can no longer open the webcam.'
       Services = @('FrameServer', 'FrameServerMonitor') },
    @{ Cat = 'Services & features'; Id = 'smartcard'; Name = 'Smart-card services'; Def = 'Y'
       Desc = 'Smart-card reader, enumeration and removal-policy services.'
       Warn = 'Keep them if you log in with a smart card or a hardware token.'
       Services = @('SCardSvr', 'ScDeviceEnum', 'SCPolicySvc') },
    @{ Cat = 'Services & features'; Id = 'cdp'; Name = 'Connected Devices Platform (Nearby sharing, Cast, cross-device)'; Def = 'N'
       Desc = 'Turns off the platform behind Nearby sharing, Cast to device and cross-device experiences.'
       Warn = 'Wireless display (Win+K) and Nearby sharing stop working.'
       Services = @('CDPSvc', 'CDPUserSvc:T')
       Reg = @( (Row 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\System' 'EnableCdp' 0) ) },
    @{ Cat = 'Services & features'; Id = 'wmp'; Name = 'Windows Media Player Legacy'; Def = 'Y'
       Desc = 'The old Windows Media Player (Windows feature).'
       Caps = @('Media.WindowsMediaPlayer*') },
    @{ Cat = 'Services & features'; Id = 'speechlang'; Name = 'Speech and handwriting language features'; Def = 'N'
       Desc = 'Offline speech recognition and handwriting packs (saves disk space).'
       Warn = 'Voice typing and handwriting recognition need them.'
       Caps = @('Language.Speech*', 'Language.Handwriting*') },
    @{ Cat = 'Services & features'; Id = 'hibernate'; Name = 'Hibernation (deletes hiberfil.sys)'; Def = 'N'
       Desc = 'Frees a hidden file roughly the size of your RAM.'
       Warn = 'Also turns off Fast Startup and hibernate.'
       Custom = 'hibernate' },
    @{ Cat = 'Services & features'; Id = 'resetbase'; Name = 'Deep component-store cleanup (DISM /ResetBase)'; Def = 'N'
       Desc = 'Frees more space by dropping the ability to uninstall already-installed updates.'
       Warn = 'Irreversible: installed updates can no longer be uninstalled.'
       Custom = 'resetbase' }
)

# =============================================================================
#  11. Prompts and saved choices
# =============================================================================
function Test-ItemApplicable {
    param($item)
    foreach ($pat in @($item.Appx)) {
        if (-not $pat) { continue }
        if (@(Get-AppxAllCached | Where-Object { $_.Name -like $pat }).Count -gt 0) { return $true }
        if (@(Get-AppxProvCached | Where-Object { $_.DisplayName -like $pat }).Count -gt 0) { return $true }
    }
    foreach ($s in @($item.Services)) {
        if (-not $s) { continue }
        $n = $s -replace ':T$', ''
        if (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $n)) { return $true }
    }
    foreach ($c in @($item.Caps)) {
        if (-not $c) { continue }
        if (@(Get-CapsCached | Where-Object { ($_.Name -like $c) -and ([string]$_.State -eq 'Installed') }).Count -gt 0) { return $true }
    }
    switch ($item.Custom) {
        'edge'      { if (Test-EdgePresent) { return $true } }
        'onedrive'  { if (Test-OneDrivePresent) { return $true } }
        'office'    { if (@(Get-OfficeArp).Count -gt 0) { return $true } }
        'teams'     { if (@(Get-TeamsMwi).Count -gt 0) { return $true } }
        'hibernate' { if (Test-Path -LiteralPath (Join-Path $env:SystemDrive 'hiberfil.sys')) { return $true } }
        'resetbase' { return $true }
    }
    return $false
}

function Get-ItemBlocker {
    param($item)
    switch ($item.Custom) {
        'onedrive' {
            if (@(Get-OneDriveKfm).Count -gt 0) { return 'OneDrive Known Folder Move is active (your Desktop/Documents/Pictures live inside OneDrive). Stop the backup and move the folders back first, then re-run.' }
        }
        'edge' {
            if (@(Get-InstalledBrowsers).Count -eq 0) { return 'no other web browser is installed. Install one first (for example: winget install Mozilla.Firefox), then re-run.' }
        }
    }
    return $null
}

function Read-ItemChoice {
    param($Item)
    $id = [string]$Item.Id
    $defYes = ($Item.Def -eq 'Y')
    if (($null -ne $Script:Saved) -and $Script:Saved.ContainsKey($id)) { return [bool]$Script:Saved[$id] }
    if ($Defaults -or ($null -ne $Script:Saved)) { return $defYes }
    if ($Script:Bulk -eq 'N') { return $false }
    if ($Script:Bulk -eq 'D') { return $defYes }
    Write-Host ''
    Write-Host ('  ' + $Item.Name) -ForegroundColor White
    if ($Item.Desc) { Write-Host ('     ' + $Item.Desc) -ForegroundColor DarkGray }
    if ($Item.Warn) { Write-Host ('     ! ' + $Item.Warn) -ForegroundColor Yellow }
    $hint = 'y/N'
    if ($defYes) { $hint = 'Y/n' }
    while ($true) {
        $a = ([string](Read-Host ('     Remove / disable?  [{0}]  (d = default for ALL remaining, k = keep ALL remaining)' -f $hint))).Trim().ToLowerInvariant()
        switch ($a) {
            ''    { return $defYes }
            'y'   { return $true }
            'yes' { return $true }
            'n'   { return $false }
            'no'  { return $false }
            'd'   { $Script:Bulk = 'D'; return $defYes }
            'k'   { $Script:Bulk = 'N'; return $false }
        }
    }
}

function Get-PromoPackages {
    $rx = '^(SpotifyAB\.SpotifyMusic|4DF9E0F8\.Netflix|Disney\.|BytedancePte\.Ltd\.TikTok|Facebook\.|9E2F88E3\.Twitter|7EE7776C\.LinkedInforWindows|AmazonVideo\.PrimeVideo|Amazon\.com\.Amazon|king\.com\.|Zynga\.|A278AB0D\.|ROBLOXCORPORATION\.|D5EA27B7\.Duolingo|AdobeSystemsIncorporated\.AdobePhotoshopExpress|HuluLLC\.|PandoraMediaInc|NORDCURRENT\.)'
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(Get-AppxAllCached)) { if (($p.Name -match $rx) -and (-not $names.Contains($p.Name))) { $names.Add($p.Name) } }
    foreach ($p in @(Get-AppxProvCached)) { if (($p.DisplayName -match $rx) -and (-not $names.Contains($p.DisplayName))) { $names.Add($p.DisplayName) } }
    return $names.ToArray()
}

function Get-OemPackages {
    $rx = '^(AD2F1837\.|DellInc\.|E046963F\.|LenovoCompanyLimited\.|LenovoCorporation\.|ASUSTeKCOMPUTERINC\.|B9ECED6F\.|AcerIncorporated\.|SAMSUNGELECTRONICSCO|McAfee|NortonLifeLock|Norton|ExpressVPN|DropboxInc|Dropbox|Evernote)'
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(Get-AppxAllCached)) { if (($p.Name -match $rx) -and (-not $names.Contains($p.Name))) { $names.Add($p.Name) } }
    foreach ($p in @(Get-AppxProvCached)) { if (($p.DisplayName -match $rx) -and (-not $names.Contains($p.DisplayName))) { $names.Add($p.DisplayName) } }
    return $names.ToArray()
}

function Import-Choices {
    param([string]$Path)
    $obj = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Path -Raw)
    $h = @{}
    if ($null -ne $obj.choices) {
        foreach ($p in $obj.choices.PSObject.Properties) { $h[[string]$p.Name] = [bool]$p.Value }
    }
    return $h
}

function Save-Choices {
    param([hashtable]$Choice)
    $o = [ordered]@{ version = 1; created = (Get-Date).ToString('s'); choices = $Choice }
    Set-Content -LiteralPath $Script:ChoicesFile -Value (ConvertTo-Json -InputObject $o -Depth 4) -Encoding UTF8
}

function Get-Choices {
    $choice = @{}
    Write-Section 'Optional items (only what is present on this PC is asked)'
    if ($null -ne $Script:Saved) { Write-Log 'Using saved choices; items missing from the saved file use their default.' 'INFO' }
    elseif ($Defaults) { Write-Log 'Using the default answer for every optional item.' 'INFO' }
    else {
        Write-Host '  Telemetry, tracking, ads, AI-snapshot features and junk files are ALWAYS handled - no questions.'
        Write-Host '  Per item:  y = remove/disable   n = keep   Enter = the default (shown in capitals)'
        Write-Host '             d = use the default for ALL remaining items   k = keep ALL remaining items'
    }
    $lastCat = ''
    foreach ($item in $Script:Catalog) {
        if ($SkipCleanup -and (@('hibernate', 'resetbase') -contains $item.Custom)) { $choice[$item.Id] = $false; continue }
        if (-not (Test-ItemApplicable $item)) { $choice[$item.Id] = $false; continue }
        $block = Get-ItemBlocker $item
        if ($block) { Write-Log ('{0}: kept - {1}' -f $item.Name, $block) 'WARN'; $choice[$item.Id] = $false; continue }
        if (($null -eq $Script:Saved) -and (-not $Defaults) -and ($null -eq $Script:Bulk) -and ($item.Cat -ne $lastCat)) {
            Write-Host ''
            Write-Host ('--- {0} ---' -f $item.Cat) -ForegroundColor Cyan
            $lastCat = $item.Cat
        }
        $choice[$item.Id] = [bool](Read-ItemChoice $item)
    }
    $promo = @(Get-PromoPackages)
    if ($promo.Count -gt 0) {
        $it = @{ Id = 'promo'; Name = ('Third-party promo apps found: ' + ($promo -join ', ')); Def = 'Y'; Desc = 'Pre-installed or silently installed promo apps.'; Warn = 'Answer n if you actually use one of them.' }
        $choice['promo'] = [bool](Read-ItemChoice $it)
    } else { $choice['promo'] = $false }
    foreach ($o in @(Get-OemPackages)) {
        $it = @{ Id = ('oem:' + $o); Name = ('OEM / vendor app: ' + $o); Def = 'N'; Desc = 'Preloaded by the PC maker or a trial vendor.'; Warn = 'May be a driver, hotkey or control utility - keep it if unsure.' }
        $choice[$it.Id] = [bool](Read-ItemChoice $it)
    }
    return $choice
}

# =============================================================================
#  12. Build the plan (always-on tasks + the answers above)
# =============================================================================
function Build-Plan {
    param([hashtable]$Choice)
    $Script:Plan.Clear()
    $polRoot = 'SOFTWARE\Policies\Microsoft\Windows'

    Add-RegRows -Group 'Diagnostic data, CEIP, error reporting' -Rows @(
        Row 'HKLM' "$polRoot\DataCollection" 'AllowTelemetry' 0
        Row 'HKLM' "$polRoot\DataCollection" 'DoNotShowFeedbackNotifications' 1
        Row 'HKLM' "$polRoot\DataCollection" 'DisableOneSettingsDownloads' 1
        Row 'HKLM' "$polRoot\DataCollection" 'LimitDiagnosticLogCollection' 1
        Row 'HKLM' "$polRoot\DataCollection" 'LimitDumpCollection' 1
        Row 'HKLM' "$polRoot\DataCollection" 'AllowDeviceNameInTelemetry' 0
        Row 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0 -Soft
        Row 'HKLM' "$polRoot\AppCompat" 'AITEnable' 0
        Row 'HKLM' "$polRoot\AppCompat" 'DisableInventory' 1
        Row 'HKLM' "$polRoot\AppCompat" 'DisableUAR' 1
        Row 'HKLM' 'SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
        Row 'HKLM' 'SOFTWARE\Microsoft\SQMClient\Windows' 'CEIPEnable' 0 -Soft
        Row 'HKLM' "$polRoot\Windows Error Reporting" 'Disabled' 1
        Row 'HKLM' "$polRoot\Windows Error Reporting" 'DontSendAdditionalData' 1
        Row 'HKLM' "$polRoot\Windows Error Reporting" 'LoggingDisabled' 1
        Row 'HKLM' 'SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 -Soft
        Row 'HKLM' 'SOFTWARE\Policies\Microsoft\MRT' 'DontReportInfectionInformation' 1
        Row 'HKU' 'Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0 -Soft
        Row 'HKU' 'Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    )

    Add-RegRows -Group 'Activity history, cloud clipboard, settings sync' -Rows @(
        Row 'HKLM' "$polRoot\System" 'EnableActivityFeed' 0
        Row 'HKLM' "$polRoot\System" 'PublishUserActivities' 0
        Row 'HKLM' "$polRoot\System" 'UploadUserActivities' 0
        Row 'HKLM' "$polRoot\System" 'AllowCrossDeviceClipboard' 0
        Row 'HKLM' "$polRoot\SettingSync" 'DisableSettingSync' 2
        Row 'HKLM' "$polRoot\SettingSync" 'DisableSettingSyncUserOverride' 1
        Row 'HKLM' "$polRoot\Messaging" 'AllowMessageSync' 0
    )

    $cloudNames = @('DisableWindowsConsumerFeatures', 'DisableSoftLanding', 'DisableCloudOptimizedContent', 'DisableWindowsSpotlightFeatures', 'DisableThirdPartySuggestions', 'DisableTailoredExperiencesWithDiagnosticData', 'DisableWindowsSpotlightOnActionCenter', 'DisableWindowsSpotlightOnSettings', 'DisableWindowsSpotlightWindowsWelcomeExperience')
    $cdmPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $cdmNames = @('ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled', 'SilentInstalledAppsEnabled', 'SoftLandingEnabled', 'SlideshowEnabled', 'SystemPaneSuggestionsEnabled', 'SubscribedContent-310093Enabled', 'SubscribedContent-314559Enabled', 'SubscribedContent-314563Enabled', 'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-353698Enabled', 'SubscribedContent-88000326Enabled')
    $adRows = New-Object System.Collections.Generic.List[object]
    $adRows.Add((Row 'HKLM' "$polRoot\AdvertisingInfo" 'DisabledByGroupPolicy' 1))
    $adRows.Add((Row 'HKU' 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0))
    foreach ($n in $cloudNames) { $adRows.Add((Row 'HKLM' "$polRoot\CloudContent" $n 1)) }
    foreach ($n in @('DisableWindowsSpotlightFeatures', 'DisableTailoredExperiencesWithDiagnosticData', 'DisableThirdPartySuggestions')) { $adRows.Add((Row 'HKU' "Software\Policies\Microsoft\Windows\CloudContent" $n 1)) }
    foreach ($n in $cdmNames) { $adRows.Add((Row 'HKU' $cdmPath $n 0)) }
    foreach ($n in @('ShowSyncProviderNotifications', 'Start_IrisRecommendations', 'Start_AccountNotifications', 'Start_TrackProgs')) { $adRows.Add((Row 'HKU' 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' $n 0)) }
    Add-RegRows -Group 'Advertising ID, suggestions, consumer content' -Rows $adRows.ToArray()

    $searchRows = New-Object System.Collections.Generic.List[object]
    foreach ($n in @('AllowCortana', 'AllowCortanaAboveLock', 'AllowCloudSearch', 'AllowSearchToUseLocation', 'ConnectedSearchUseWeb', 'ConnectedSearchUseWebOverMeteredConnections')) { $searchRows.Add((Row 'HKLM' "$polRoot\Windows Search" $n 0)) }
    $searchRows.Add((Row 'HKLM' "$polRoot\Windows Search" 'DisableWebSearch' 1))
    $searchRows.Add((Row 'HKLM' "$polRoot\Explorer" 'DisableSearchBoxSuggestions' 1))
    $searchRows.Add((Row 'HKU' 'Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1))
    foreach ($n in @('IsDynamicSearchBoxEnabled', 'IsAADCloudSearchEnabled', 'IsMSACloudSearchEnabled', 'IsDeviceSearchHistoryEnabled')) { $searchRows.Add((Row 'HKU' 'Software\Microsoft\Windows\CurrentVersion\SearchSettings' $n 0)) }
    $searchRows.Add((Row 'HKU' 'Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0))
    $searchRows.Add((Row 'HKU' 'Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0 -Soft))
    $searchRows.Add((Row 'HKLM' 'SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0))
    $searchRows.Add((Row 'HKLM' "$polRoot\Windows Feeds" 'EnableFeeds' 0))
    $searchRows.Add((Row 'HKLM' "$polRoot\Windows Chat" 'ChatIcon' 3))
    Add-RegRows -Group 'Web search in Start, Widgets, Teams chat icon, news feeds' -Rows $searchRows.ToArray()

    Add-RegRows -Group 'AI features (Recall, Click to Do, Copilot policy)' -Rows @(
        Row 'HKLM' "$polRoot\WindowsAI" 'DisableAIDataAnalysis' 1
        Row 'HKLM' "$polRoot\WindowsAI" 'AllowRecallEnablement' 0
        Row 'HKLM' "$polRoot\WindowsAI" 'DisableClickToDo' 1
        Row 'HKLM' "$polRoot\WindowsCopilot" 'TurnOffWindowsCopilot' 1
        Row 'HKU' 'Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    )

    Add-RegRows -Group 'Input, speech and handwriting personalization' -Rows @(
        Row 'HKLM' 'SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
        Row 'HKLM' 'SOFTWARE\Policies\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
        Row 'HKLM' 'SOFTWARE\Policies\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
        Row 'HKLM' "$polRoot\TabletPC" 'PreventHandwritingDataSharing' 1
        Row 'HKLM' "$polRoot\HandwritingErrorReports" 'PreventHandwritingErrorReports' 1
        Row 'HKU' 'Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
        Row 'HKU' 'Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
        Row 'HKU' 'Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
        Row 'HKU' 'Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0 -Soft
        Row 'HKU' 'Software\Microsoft\Input\TIPC' 'Enabled' 0 -Soft
        Row 'HKU' 'Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0 -Soft
    )

    Add-RegRows -Group 'Delivery Optimization (no peer-to-peer upload)' -Rows @(
        Row 'HKLM' "$polRoot\DeliveryOptimization" 'DODownloadMode' 0
    )

    Add-RegRows -Group 'ETW AutoLogger sessions (telemetry collection from boot)' -Rows @(
        Row 'HKLM' 'SYSTEM\CurrentControlSet\Control\WMI\Autologger\AutoLogger-Diagtrack-Listener' 'Start' 0 -Soft -IfKey
        Row 'HKLM' 'SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener' 'Start' 0 -Soft -IfKey
        Row 'HKLM' 'SYSTEM\CurrentControlSet\Control\WMI\Autologger\SQMLogger' 'Start' 0 -Soft -IfKey
    )

    # ---- Edge: harden if it stays, keep it from coming back if it goes ----
    if (Test-EdgePresent) {
        if (-not $Choice['edge']) {
            $edgePol = 'SOFTWARE\Policies\Microsoft\Edge'
            $edgeRows = New-Object System.Collections.Generic.List[object]
            foreach ($n in @('MetricsReportingEnabled', 'PersonalizationReportingEnabled', 'UserFeedbackAllowed', 'DiagnosticData', 'SendSiteInfoToImproveServices', 'SpotlightExperiencesAndRecommendationsEnabled', 'EdgeShoppingAssistantEnabled', 'ShowRecommendationsEnabled', 'HubsSidebarEnabled', 'StartupBoostEnabled', 'BackgroundModeEnabled', 'PromotionalTabsEnabled', 'ShowMicrosoftRewards', 'EdgeFollowEnabled', 'ResolveNavigationErrorsUseWebService', 'AlternateErrorPagesEnabled', 'NewTabPageContentEnabled')) {
                $edgeRows.Add((Row 'HKLM' $edgePol $n 0))
            }
            $edgeRows.Add((Row 'HKLM' $edgePol 'ConfigureDoNotTrack' 1))
            Add-RegRows -Group 'Edge privacy policies (Edge will say "managed by your organization")' -Rows $edgeRows.ToArray()
        }
    }

    # ---- Office telemetry policies if Office stays ----
    if ((@(Get-OfficeArp).Count -gt 0) -and (-not $Choice['office'])) {
        $op = 'Software\Policies\Microsoft\office\16.0\common'
        Add-RegRows -Group 'Office privacy / telemetry policies' -Rows @(
            Row 'HKU' "$op\privacy" 'DisconnectedState' 2 -Soft
            Row 'HKU' "$op\privacy" 'UserContentDisabled' 2 -Soft
            Row 'HKU' "$op\privacy" 'DownloadContentDisabled' 2 -Soft
            Row 'HKU' "$op\privacy" 'ControllerConnectedServicesEnabled' 2 -Soft
            Row 'HKU' "$op\clienttelemetry" 'SendTelemetry' 3 -Soft
            Row 'HKU' $op 'qmenable' 0 -Soft
            Row 'HKU' $op 'updatereliabilitydata' 0 -Soft
            Row 'HKU' "$op\feedback" 'enabled' 0 -Soft
            Row 'HKU' "$op\feedback" 'includescreenshot' 0 -Soft
            Row 'HKU' "$op\feedback" 'surveyenabled' 0 -Soft
        )
    }

    # ---- services, tasks, features, always-removed apps ----
    foreach ($s in $Script:AlwaysServices) { Add-ServiceSpec $s }
    foreach ($t in $Script:AlwaysTasks) { Add-SchedSpec $t }
    foreach ($f in $Script:AlwaysFeatures) { Add-Task -Phase 'Windows features' -Kind 'Feature' -Title ('Windows feature off: ' + $f) -Data @{ Name = $f } }
    foreach ($c in $Script:AlwaysCaps) { Add-Task -Phase 'Windows features' -Kind 'Cap' -Title ('Windows capability removed: ' + $c) -Data @{ Pattern = $c } }
    foreach ($a in $Script:AlwaysAppx) { Add-Task -Phase 'Apps' -Kind 'Appx' -Title ('App removed: ' + $a) -Data @{ Pattern = $a } }
    foreach ($a in $Script:AlwaysAppxSoft) { Add-Task -Phase 'Apps' -Kind 'Appx' -Title ('App removed: ' + $a) -Soft -Data @{ Pattern = $a } }

    # ---- chosen optional items ----
    foreach ($item in $Script:Catalog) {
        if (-not $Choice[$item.Id]) { continue }
        foreach ($a in @($item.Appx)) { if ($a) { Add-Task -Phase 'Apps' -Kind 'Appx' -Title ('App removed: ' + $a) -Data @{ Pattern = $a } } }
        foreach ($s in @($item.Services)) { if ($s) { Add-ServiceSpec $s } }
        foreach ($t in @($item.Tasks)) { if ($t) { Add-SchedSpec $t } }
        foreach ($c in @($item.Caps)) { if ($c) { Add-Task -Phase 'Windows features' -Kind 'Cap' -Title ('Windows capability removed: ' + $c) -Data @{ Pattern = $c } } }
        if ($item.Reg) { Add-RegRows -Group ('Optional: ' + $item.Name) -Rows $item.Reg }
        switch ($item.Custom) {
            'office'    { Add-Task -Phase 'Desktop software' -Kind 'Custom' -Title 'Microsoft Office: uninstall the suite' -Soft -Data @{ ApplyFn = 'Invoke-ApplyOffice'; VerifyFn = 'Test-StateOffice' } }
            'onedrive'  { Add-Task -Phase 'Desktop software' -Kind 'Custom' -Title 'OneDrive: uninstall and clean up' -Soft -Data @{ ApplyFn = 'Invoke-ApplyOneDrive'; VerifyFn = 'Test-StateOneDrive' } }
            'edge'      { Add-Task -Phase 'Desktop software' -Kind 'Custom' -Title 'Microsoft Edge: uninstall the browser' -Soft -Data @{ ApplyFn = 'Invoke-ApplyEdge'; VerifyFn = 'Test-StateEdge' } }
            'teams'     { if (@(Get-TeamsMwi).Count -gt 0) { Add-Task -Phase 'Desktop software' -Kind 'Custom' -Title 'Teams Machine-Wide Installer: uninstall' -Soft -Data @{ ApplyFn = 'Invoke-ApplyTeamsMwi'; VerifyFn = 'Test-StateTeamsMwi' } } }
            'hibernate' { Add-Task -Phase 'Cleanup' -Kind 'Custom' -Title 'Hibernation off (hiberfil.sys removed)' -Soft -Data @{ ApplyFn = 'Invoke-ApplyHibernate'; VerifyFn = 'Test-StateHibernate' } }
        }
    }

    # ---- promo and OEM apps (exact package names, answered above) ----
    if ($Choice['promo']) { foreach ($n in @(Get-PromoPackages)) { Add-Task -Phase 'Apps' -Kind 'Appx' -Title ('Promo app removed: ' + $n) -Data @{ Pattern = $n } } }
    foreach ($k in @($Choice.Keys)) {
        if (($k -like 'oem:*') -and $Choice[$k]) { $n = $k.Substring(4); Add-Task -Phase 'Apps' -Kind 'Appx' -Title ('OEM app removed: ' + $n) -Data @{ Pattern = $n } }
    }

    # ---- firewall + Defender ----
    Add-Task -Phase 'Firewall & Defender' -Kind 'Custom' -Title 'Outbound firewall blocks for the telemetry binaries' -Data @{ ApplyFn = 'Invoke-ApplyFirewall'; VerifyFn = 'Test-StateFirewall' }
    Add-Task -Phase 'Firewall & Defender' -Kind 'Custom' -Title 'Defender: never send samples, basic cloud reporting' -Soft -Data @{ ApplyFn = 'Invoke-ApplyDefender'; VerifyFn = 'Test-StateDefender' }

    # ---- file clean-up ----
    if (-not $SkipCleanup) {
        $sd = $env:SystemDrive
        $sr = $env:SystemRoot
        if (-not $Script:PendingReboot) {
            Add-PathTask -Path (Join-Path $sd 'Windows.old') -Mode Self
            Add-PathTask -Path (Join-Path $sd '$Windows.~BT') -Mode Self
            Add-PathTask -Path (Join-Path $sd '$Windows.~WS') -Mode Self
            Add-PathTask -Path (Join-Path $sd '$WinREAgent') -Mode Self -Soft
        } else {
            Write-Log 'A reboot is pending: Windows.old and the upgrade-staging folders are skipped in this run.' 'WARN'
        }
        Add-PathTask -Path (Join-Path $sr 'SoftwareDistribution\Download') -Tolerant -Soft -StopServices @('wuauserv', 'bits', 'dosvc')
        Add-PathTask -Path (Join-Path $sr 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache') -Tolerant -Soft -StopServices @('dosvc')
        Add-PathTask -Path (Join-Path $sr 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Logs') -Tolerant -Soft -StopServices @('dosvc')
        Add-PathTask -Path (Join-Path $sr 'Temp') -Tolerant -Soft
        Add-PathTask -Path (Join-Path $sr 'Logs\CBS') -Tolerant -Soft
        Add-PathTask -Path (Join-Path $sr 'Logs\WindowsUpdate') -Tolerant -Soft
        Add-PathTask -Path (Join-Path $sr 'Minidump') -Tolerant -Soft
        Add-PathTask -Path (Join-Path $sr 'LiveKernelReports') -Tolerant -Soft
        Add-PathTask -Path (Join-Path $sr 'MEMORY.DMP') -Mode Self -Tolerant -Soft
        $wer = Join-Path $env:ProgramData 'Microsoft\Windows\WER'
        foreach ($sub in @('ReportArchive', 'ReportQueue', 'Temp')) { Add-PathTask -Path (Join-Path $wer $sub) -Tolerant -Soft }
        $diag = Join-Path $env:ProgramData 'Microsoft\Diagnosis'
        Add-PathTask -Path (Join-Path $diag 'ETLLogs') -Tolerant -Soft -EtsStop @('AutoLogger-Diagtrack-Listener', 'Diagtrack-Listener')
        foreach ($sub in @('Scenarios', 'TenantStorage', 'LocalTraceStore', 'FeedbackHub')) { Add-PathTask -Path (Join-Path $diag $sub) -Tolerant -Soft }
        foreach ($pp in @(Get-ProfilePaths)) {
            Add-PathTask -Path (Join-Path $pp 'AppData\Local\Temp') -Tolerant -Soft
            Add-PathTask -Path (Join-Path $pp 'AppData\Local\CrashDumps') -Tolerant -Soft
            Add-PathTask -Path (Join-Path $pp 'AppData\Local\Microsoft\Windows\WER') -Tolerant -Soft
            Add-PathTask -Path (Join-Path $pp 'AppData\Local\Packages\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy\LocalState\Assets') -Tolerant -Soft
            Add-PathTask -Path (Join-Path $pp 'AppData\Local\Packages\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy\TempState') -Tolerant -Soft
        }
        Add-Task -Phase 'Component store' -Kind 'Custom' -Title 'Windows component store cleanup (DISM)' -Soft -Data @{ ApplyFn = 'Invoke-ApplyComponentCleanup'; VerifyFn = 'Test-StateComponentCleanup'; ResetBase = [bool]$Choice['resetbase']; ExitCode = $null; Freed = [int64]0 }
    }
}

function Show-Plan {
    param([hashtable]$Choice)
    Write-Section 'Plan'
    $remove = New-Object System.Collections.Generic.List[string]
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Script:Catalog) {
        if (-not $Choice.ContainsKey($item.Id)) { continue }
        if ($Choice[$item.Id]) { $remove.Add($item.Name) }
        elseif (Test-ItemApplicable $item) { $keep.Add($item.Name) }
    }
    if ($Choice['promo']) { $remove.Add('Third-party promo apps') }
    foreach ($k in @($Choice.Keys)) { if (($k -like 'oem:*') -and $Choice[$k]) { $remove.Add($k.Substring(4)) } }
    $rt = '-'
    if ($remove.Count -gt 0) { $rt = ($remove -join ', ') }
    $kt = '-'
    if ($keep.Count -gt 0) { $kt = ($keep -join ', ') }
    Write-Log ('Optional items to REMOVE / DISABLE ({0}): {1}' -f $remove.Count, $rt) 'INFO'
    Write-Log ('Optional items you KEEP ({0}): {1}' -f $keep.Count, $kt) 'INFO'
    Write-Log 'Always applied: telemetry / tracking / ads / AI-snapshot / junk (see the phases below).' 'INFO'
    if (-not $SkipCleanup) {
        Write-Log 'File clean-up will delete: Windows.old and upgrade leftovers, Windows Update + Delivery Optimization caches, temp folders (system and every user),' 'INFO'
        Write-Log '  error-report queues, diagnostic traces, CBS / Windows Update logs, crash dumps (Minidump, MEMORY.DMP), Spotlight image cache.' 'INFO'
        Write-Log '  Use -SkipCleanup to leave all of that alone (for example if you still need a crash dump).' 'INFO'
    }
    foreach ($g in @($Script:Plan | Group-Object -Property Phase)) { Write-Log ('  {0,-22} {1,4} item(s)' -f $g.Name, $g.Count) 'DIM' }
    Write-Log ('Total tasks: {0}. Every task is verified after it is applied.' -f $Script:Plan.Count) 'INFO'
}

# =============================================================================
#  13. Banner, preflight, restore point
# =============================================================================
$Script:PendingReboot = $false
$Script:FreeBefore    = [int64]0

function Show-Banner {
    Write-Host ''
    Write-Host ('  Win11-DeepDebloat v{0}' -f $Script:Version) -ForegroundColor Cyan
    Write-Host '  Deep, verified removal of Windows 11 telemetry, tracking, ads, bloat and junk files.' -ForegroundColor Gray
    Write-Host '  Windows Update, Defender protection, the Store and winget are NOT touched.' -ForegroundColor Gray
    Write-Host '  Personal PCs only - do not run this on a work or school managed device.' -ForegroundColor Yellow
    if ($DryRun)     { Write-Host '  MODE: DRY RUN - nothing will be changed.' -ForegroundColor Magenta }
    if ($VerifyOnly) { Write-Host '  MODE: VERIFY ONLY - nothing will be changed.' -ForegroundColor Magenta }
    if ($Restore)    { Write-Host '  MODE: RESTORE the original settings.' -ForegroundColor Magenta }
}

function Test-Preflight {
    Write-Section 'Preflight'
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $Script:Build = [int]$os.BuildNumber
    $Script:EditionId = [string]$cv.EditionID
    Write-Log ('{0} | build {1}.{2} | version {3} | edition {4}' -f $os.Caption, $os.BuildNumber, $cv.UBR, $cv.DisplayVersion, $Script:EditionId) 'INFO'
    if ($Script:Build -lt 22000) { throw 'This script is for Windows 11 only (build 22000 or newer).' }
    if ($Script:EditionId -like 'Core*') {
        Write-Log 'Windows 11 Home: diagnostic data cannot go below "Required" (Microsoft allows "Off" only on Enterprise/Education). The policies are still written.' 'WARN'
    } elseif ($Script:EditionId -notmatch 'Enterprise|Education|IoT') {
        Write-Log 'Edition note: diagnostic data "Off" exists only on Enterprise/Education; on this edition the floor is "Required".' 'INFO'
    }
    $enr = @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
        Where-Object { ($_.PSChildName -match '^[0-9A-Fa-f-]{36}$') -and (Get-RegValue $_.PSPath 'ProviderID') })
    if ($enr.Count -gt 0) {
        Write-Log 'This PC looks MDM-managed (Intune or similar). Disabling telemetry services can break management - stop now if it is a work or school PC.' 'WARN'
    }
    $pend = $false
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $k) { $pend = $true }
    }
    $Script:PendingReboot = $pend
    if ($pend) { Write-Log 'A reboot is pending. Upgrade-leftover folders (Windows.old ...) will NOT be deleted in this run: reboot and run again for a complete result.' 'WARN' }
    $free = Get-FreeBytes
    Write-Log ('Free space on {0}: {1}' -f $env:SystemDrive, (Format-Size $free)) 'INFO'
    if ($free -lt 3GB) { Write-Log 'Less than 3 GB free: the DISM component cleanup may fail.' 'WARN' }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.IsTamperProtected) { Write-Log 'Defender Tamper Protection is ON: the Defender privacy settings may be refused (reported as WARN, not FAIL).' 'WARN' }
    } catch { }
}

function New-SafetyRestorePoint {
    Write-Log 'Creating a System Restore point ...' 'STEP'
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $freq = Get-RegValue $k 'SystemRestorePointCreationFrequency'
    try {
        Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop
        New-ItemProperty -LiteralPath $k -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description ('Win11-DeepDebloat ' + $Script:Stamp) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $rp = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object { $_.Description -like 'Win11-DeepDebloat*' })
        if ($rp.Count -gt 0) { Write-Log 'Restore point created and verified.' 'OK'; return $true }
        Write-Log 'The restore-point command ran but the point was not found.' 'WARN'
        return $false
    } catch {
        Write-Log ('Restore point failed: ' + $_.Exception.Message) 'WARN'
        return $false
    } finally {
        if ($null -eq $freq) { Remove-ItemProperty -LiteralPath $k -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue }
        else { New-ItemProperty -LiteralPath $k -Name 'SystemRestorePointCreationFrequency' -Value $freq -PropertyType DWord -Force | Out-Null }
    }
}

# =============================================================================
#  14. Engine: apply every task of a phase, then verify every task of that phase
# =============================================================================
function Write-Result {
    param($R)
    $lvl = 'OK'
    if ($R.Status -eq 'WARN') { $lvl = 'WARN' } elseif ($R.Status -eq 'FAIL') { $lvl = 'FAIL' }
    $txt = '{0,-4} {1}' -f $R.Status, $R.Title
    if ($R.Detail) { $txt += '  -  ' + $R.Detail }
    Write-Log $txt $lvl
}

function Invoke-Plan {
    $order = @('Policies & settings', 'Services', 'Scheduled tasks', 'Windows features', 'Apps', 'Desktop software', 'Firewall & Defender', 'Cleanup', 'Component store')
    foreach ($ph in $order) {
        $tasks = @($Script:Plan | Where-Object { $_.Phase -eq $ph })
        if ($tasks.Count -eq 0) { continue }
        Write-Section ('{0}  ({1} item(s))' -f $ph, $tasks.Count)

        if ($DryRun) {
            foreach ($g in @($tasks | Where-Object { $_.Group } | Group-Object -Property Group)) { Write-Log ('would set {0} value(s): {1}' -f $g.Count, $g.Name) 'DRY' }
            foreach ($t in @($tasks | Where-Object { -not $_.Group })) { Write-Log ('would do: ' + $t.Title) 'DRY' }
            continue
        }

        if (-not $VerifyOnly) {
            foreach ($t in $tasks) {
                try {
                    $out = @(Invoke-TaskApply $t)
                    $t.ApplyNote = [string]($out | Select-Object -Last 1)
                } catch {
                    $t.ApplyError = (([string]$_.Exception.Message) -split "`r?`n")[0]
                }
            }
            Save-Baseline
            $kinds = @($tasks | ForEach-Object { $_.Kind } | Select-Object -Unique)
            if ($kinds -contains 'Appx')    { Reset-Caches @('Appx', 'Prov') }
            if ($kinds -contains 'Cap')     { Reset-Caches @('Caps') }
            if ($kinds -contains 'Feature') { Reset-Caches @('Feats') }
        }

        $groups = [ordered]@{}
        $quietCount = 0
        foreach ($t in $tasks) {
            $v = $null
            try { $vv = @(Test-TaskState $t); $v = $vv | Select-Object -Last 1 }
            catch { $v = @{ Ok = $false; Detail = ('verify error: ' + $_.Exception.Message) } }
            if ($null -eq $v) { $v = @{ Ok = $false; Detail = 'no verification result' } }
            $status = 'PASS'
            if (-not $v.Ok) { if ($t.Soft) { $status = 'WARN' } else { $status = 'FAIL' } }
            $detail = [string]$v.Detail
            if ($t.ApplyError) { $detail = ($detail + ' [apply: ' + $t.ApplyError + ']').Trim() }
            $note = [string]$t.ApplyNote
            $quiet = ($status -eq 'PASS') -and (($note -eq 'absent') -or ($note -like 'already*'))
            $res = [pscustomobject]@{ Phase = $ph; Group = $t.Group; Title = $t.Title; Status = $status; Detail = $detail; Absent = $quiet }
            $Script:Results.Add($res)
            if ($t.Group) {
                if (-not $groups.Contains($t.Group)) { $groups[$t.Group] = [pscustomobject]@{ Total = 0; Pass = 0; Bad = (New-Object System.Collections.Generic.List[object]) } }
                $g = $groups[$t.Group]
                $g.Total++
                if ($status -eq 'PASS') { $g.Pass++ } else { $g.Bad.Add($res) }
            } elseif ($quiet) {
                $quietCount++
            } else {
                Write-Result $res
            }
        }
        foreach ($name in @($groups.Keys)) {
            $g = $groups[$name]
            $lvl = 'OK'
            if ($g.Bad.Count -gt 0) { $lvl = 'WARN' }
            Write-Log ('{0}: {1}/{2} values verified' -f $name, $g.Pass, $g.Total) $lvl
            foreach ($b in $g.Bad) { Write-Result $b }
        }
        if ($quietCount -gt 0) { Write-Log ('({0} item(s) were already absent / already off - verified)' -f $quietCount) 'DIM' }
    }
}

# =============================================================================
#  15. Report
# =============================================================================
function Show-Report {
    Write-Section 'Verification report'
    $res = @($Script:Results)
    $pass = @($res | Where-Object { $_.Status -eq 'PASS' }).Count
    $warn = @($res | Where-Object { $_.Status -eq 'WARN' }).Count
    $fail = @($res | Where-Object { $_.Status -eq 'FAIL' }).Count
    $absent = @($res | Where-Object { $_.Absent }).Count
    $lvl = 'OK'
    if ($warn -gt 0) { $lvl = 'WARN' }
    if ($fail -gt 0) { $lvl = 'FAIL' }
    Write-Log ('Checked {0} item(s): PASS {1} (already absent/off: {2}) | WARN {3} | FAIL {4}' -f $res.Count, $pass, $absent, $warn, $fail) $lvl
    $bad = @($res | Where-Object { $_.Status -ne 'PASS' })
    if ($bad.Count -gt 0) {
        Write-Log 'Items that did NOT verify:' 'WARN'
        foreach ($r in $bad) { Write-Result $r }
    }
    if (-not $VerifyOnly) {
        $freeAfter = Get-FreeBytes
        Write-Log ('File clean-up verified as freed: {0}' -f (Format-Size $Script:FreedBytes)) 'INFO'
        Write-Log ('Free space on {0}: before {1} -> after {2}' -f $env:SystemDrive, (Format-Size $Script:FreeBefore), (Format-Size $freeAfter)) 'INFO'
        if ($Script:RemovedPkg.Count -gt 0) {
            $rm = Join-Path $StateDir ('logs\removed-apps-{0}.txt' -f $Script:Stamp)
            Set-Content -LiteralPath $rm -Value @($Script:RemovedPkg) -Encoding UTF8
            Write-Log ('{0} Store package(s) removed; list saved to {1}' -f $Script:RemovedPkg.Count, $rm) 'INFO'
        }
    }
    try {
        $rep = [ordered]@{ script = 'Win11-DeepDebloat'; version = $Script:Version; created = (Get-Date).ToString('s'); build = $Script:Build; edition = $Script:EditionId; verifyOnly = [bool]$VerifyOnly; pass = $pass; warn = $warn; fail = $fail; results = $res }
        $jsonPath = Join-Path $StateDir ('reports\report-{0}.json' -f $Script:Stamp)
        $csvPath = Join-Path $StateDir ('reports\report-{0}.csv' -f $Script:Stamp)
        Set-Content -LiteralPath $jsonPath -Value (ConvertTo-Json -InputObject $rep -Depth 5) -Encoding UTF8
        $res | Select-Object Phase, Group, Title, Status, Detail, Absent | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log ('Report: ' + $jsonPath) 'DIM'
        Write-Log ('Log:    ' + $Script:LogFile) 'DIM'
    } catch { Write-Log ('Could not write the report files: ' + $_.Exception.Message) 'WARN' }
    if ($fail -gt 0) { $Script:ExitCode = 1 }
    if (-not $VerifyOnly) {
        Write-Host ''
        Write-Host '  Reboot now so stopped services, ETW sessions and removed components are fully gone.' -ForegroundColor Cyan
        Write-Host '  After the reboot (and after every Windows feature update) run:  .\Win11-DeepDebloat.ps1 -VerifyOnly' -ForegroundColor Cyan
        Write-Host '  Something broke?  .\Win11-DeepDebloat.ps1 -Restore   (or use the System Restore point)' -ForegroundColor Cyan
    }
}

# =============================================================================
#  16. Restore mode (registry values, service start types, tasks, firewall, Defender)
# =============================================================================
function Restore-RegEntry {
    param($e)
    foreach ($t in @(Get-RegTargetsById ([string]$e.RootId))) {
        $full = '{0}\{1}' -f $t.Root, $e.Path
        if (-not $e.Existed) {
            if (Test-Path -LiteralPath $full) { Remove-ItemProperty -LiteralPath $full -Name $e.Name -ErrorAction SilentlyContinue }
            continue
        }
        $kind = [string]$e.Kind
        $val = $e.Value
        switch ($kind) {
            'DWord'       { $val = [int]$val }
            'QWord'       { $val = [int64]$val }
            'Binary'      { $val = [Convert]::FromBase64String([string]$val) }
            'MultiString' { $val = [string[]]@($val) }
            default       { $val = [string]$val; if (-not $kind) { $kind = 'String' } }
        }
        if (-not (Test-Path -LiteralPath $full)) { New-Item -Path $full -Force | Out-Null }
        New-ItemProperty -LiteralPath $full -Name $e.Name -Value $val -PropertyType $kind -Force | Out-Null
    }
}

function Invoke-RestoreMode {
    Write-Section 'Restore original settings'
    if ($Script:Baseline.Count -eq 0) { throw ('No baseline found at ' + $Script:BaselineFile + ' - nothing to restore.') }
    Write-Log ('Baseline entries: {0}' -f $Script:Baseline.Count) 'INFO'
    if (-not $Yes) {
        if (-not (Read-YesNo 'Revert registry values, service start types, scheduled tasks, firewall rules and Defender settings to the original state?' $false)) {
            Write-Log 'Cancelled - nothing was changed.' 'WARN'
            return
        }
    }
    Mount-UserHives
    try {
        $ok = 0
        $bad = 0
        foreach ($e in @($Script:Baseline.Values)) {
            try {
                switch ([string]$e.T) {
                    'reg'  { Restore-RegEntry $e }
                    'svc'  { if ($null -ne $e.Start) { Set-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $e.Name) -Name 'Start' -Value ([int]$e.Start) -Type DWord } }
                    'task' { if ($e.Enabled) { Enable-ScheduledTask -TaskPath $e.Path -TaskName $e.Name -ErrorAction Stop | Out-Null } }
                    'mp'   { Set-MpPreference -SubmitSamplesConsent ([int]$e.Submit) -MAPSReporting ([int]$e.Maps) -ErrorAction Stop }
                }
                $ok++
            } catch {
                $bad++
                Write-Log ('Could not restore {0}: {1}' -f $e.Key, $_.Exception.Message) 'WARN'
            }
        }
        Get-NetFirewallRule -Group 'Win11DeepDebloat' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-Log ('Restored {0} entr(ies), {1} problem(s). The Win11DeepDebloat firewall rules were removed.' -f $ok, $bad) 'OK'
        Write-Log 'Removed apps and deleted files cannot be restored automatically: reinstall apps from the Microsoft Store or with winget.' 'INFO'
        Write-Log 'Reboot to finish.' 'INFO'
    } finally { Dismount-UserHives }
}

# =============================================================================
#  17. Main
# =============================================================================
function Main {
    Show-Banner
    Test-Preflight
    Initialize-State
    if ($Restore) { Invoke-RestoreMode; return }

    Mount-UserHives
    try {
        $cfgPath = $null
        if ($Config) { $cfgPath = $Config } elseif ($VerifyOnly) { $cfgPath = $Script:ChoicesFile }
        if ($cfgPath) {
            if (-not (Test-Path -LiteralPath $cfgPath)) { throw ('Choices file not found: ' + $cfgPath + ' (run the script once without -VerifyOnly first).') }
            $Script:Saved = Import-Choices $cfgPath
            Write-Log ('Loaded saved choices from ' + $cfgPath) 'INFO'
        }

        Write-Log 'Scanning installed apps, Windows capabilities and features (this can take a minute) ...' 'STEP'
        [void](Get-AppxAllCached)
        [void](Get-AppxProvCached)
        [void](Get-CapsCached)
        [void](Get-FeatsCached)

        $choice = Get-Choices
        Build-Plan $choice
        Show-Plan $choice

        if (-not ($DryRun -or $VerifyOnly -or $Yes)) {
            $a = Read-Host 'Type YES to apply these changes (anything else cancels)'
            if ($a -cne 'YES') { Write-Log 'Cancelled - nothing was changed.' 'WARN'; return }
        }
        if ((-not $DryRun) -and (-not $VerifyOnly)) {
            Save-Choices $choice
            if (-not $NoRestorePoint) {
                if (-not (New-SafetyRestorePoint)) {
                    if (-not $Yes) {
                        if (-not (Read-YesNo 'Continue WITHOUT a restore point?' $false)) { Write-Log 'Cancelled - nothing was changed.' 'WARN'; return }
                    }
                }
            }
        }

        $Script:FreeBefore = Get-FreeBytes
        Invoke-Plan
        if ($DryRun) { Write-Log 'Dry run finished - nothing was changed.' 'OK'; return }
        Show-Report
    } finally {
        Save-Baseline
        Dismount-UserHives
    }
}

try { Main }
catch { Write-Log ('FATAL: ' + $_.Exception.Message) 'FAIL'; $Script:ExitCode = 2 }
if ($env:W11DD_RELAUNCHED -eq '1') { try { [void](Read-Host 'Press Enter to close this window') } catch { } }
exit $Script:ExitCode
