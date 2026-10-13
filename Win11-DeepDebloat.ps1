#Requires -Version 5.1
#Requires -PSEdition Desktop
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Removes telemetry, ads, preinstalled junk apps and leftover files from Windows 11.

.DESCRIPTION
    Always done (no questions):
      - telemetry and tracking settings, telemetry services and scheduled tasks
      - ads and suggestions (Start, lock screen, Settings, search), Recall / Click to Do / Copilot policies
      - preinstalled junk apps (Bing News, Solitaire, Feedback Hub, ...)
      - junk files (Windows.old, temp files, error reports, crash dumps, update download cache)

    You are asked (y or n, any case) about things only some people use: Camera, Photos, Xbox, Phone Link,
    OneDrive, Edge, Microsoft Office / Word, printing, Bluetooth, search indexing, location, hibernation, ...

    Every change is checked afterwards and reported as [ OK ] or [FAIL]. The summary at the end lists
    everything that failed. Before anything is changed the script creates a restore point and saves
    backups to %ProgramData%\Win11DeepDebloat.

    Not touched: Windows Update, Microsoft Defender protection, the Microsoft Store, winget.

.PARAMETER DryRun
    Show what would be done. Nothing is changed.

.PARAMETER UseDefaults
    Do not ask anything: use the recommended answer for every question and apply without confirmation.

.EXAMPLE
    .\Win11-DeepDebloat.ps1 -DryRun

.EXAMPLE
    .\Win11-DeepDebloat.ps1
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$UseDefaults
)

# Counters and lists used by the summary at the end.
$script:okCount       = 0
$script:failures      = New-Object System.Collections.Generic.List[string]
$script:attemptedApps = New-Object System.Collections.Generic.List[string]

$systemDrive     = $env:SystemDrive    # normally C:
$programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
$logFolder       = Join-Path $env:ProgramData 'Win11DeepDebloat'
$stamp           = Get-Date -Format 'yyyyMMdd-HHmmss'


# =============================================================================
# Output and questions
# =============================================================================

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    $script:okCount++
    Write-Host "  [ OK ] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    $script:failures.Add($Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [ -- ] $Message" -ForegroundColor DarkGray
}

# Asks a yes/no question. Accepts y, yes, n, no in any case. Enter selects the default.
function Read-YesNo {
    param(
        [string]$Question,
        [bool]$Default
    )

    if ($UseDefaults) { return $Default }

    if ($Default) { $hint = 'Y/n' } else { $hint = 'y/N' }

    while ($true) {
        $answer = ([string](Read-Host "$Question [$hint]")).Trim().ToLowerInvariant()

        if ($answer -eq '') { return $Default }
        if ($answer -eq 'y' -or $answer -eq 'yes') { return $true }
        if ($answer -eq 'n' -or $answer -eq 'no') { return $false }

        Write-Host '    Please type y or n (any case), or press Enter for the default.' -ForegroundColor Yellow
    }
}


# =============================================================================
# Registry, services, scheduled tasks
# =============================================================================

# Writes one registry value and reads it back to prove it is there.
function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )

    if ($DryRun) {
        Write-Info "would set $Name = $Value in $Path"
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null

        $actual = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
        if ("$actual" -eq "$Value") {
            $script:okCount++
        } else {
            Write-Fail "$Path\$Name is '$actual' but should be '$Value'"
        }
    } catch {
        Write-Fail "$Path\$Name : $($_.Exception.Message)"
    }
}

# Stops a service and sets its start type to Disabled.
function Disable-WindowsService {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Info "service $Name does not exist on this PC"
        return
    }
    if ($DryRun) {
        Write-Info "would disable service $Name"
        return
    }

    try {
        if ($service.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $Name -Force -ErrorAction Stop
            } catch {
                Write-Info "service $Name cannot be stopped right now; it stays off after the next restart"
            }
        }
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop

        if ((Get-Service -Name $Name).StartType -eq 'Disabled') {
            Write-Ok "service $Name disabled"
        } else {
            Write-Fail "service $Name is not disabled"
        }
    } catch {
        Write-Fail "service ${Name}: $($_.Exception.Message)"
    }
}

# Disables one scheduled task and checks that it is really disabled.
function Disable-TelemetryTask {
    param(
        [string]$Path,
        [string]$Name
    )

    $task = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Info "task $Name does not exist on this PC"
        return
    }
    if ($DryRun) {
        Write-Info "would disable task $Path$Name"
        return
    }

    try {
        Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null

        if ((Get-ScheduledTask -TaskPath $Path -TaskName $Name).State -eq 'Disabled') {
            Write-Ok "task $Name disabled"
        } else {
            Write-Fail "task $Path$Name is not disabled"
        }
    } catch {
        Write-Fail "task ${Path}${Name}: $($_.Exception.Message)"
    }
}

# Blocks outgoing traffic of a service or a program in the Windows firewall.
function Add-FirewallBlockRule {
    param(
        [string]$DisplayName,
        [string]$Program,
        [string]$Service
    )

    if ($DryRun) {
        Write-Info "would add firewall rule: $DisplayName"
        return
    }

    try {
        Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue | Remove-NetFirewallRule

        if ($Service) {
            New-NetFirewallRule -DisplayName $DisplayName -Direction Outbound -Action Block -Service $Service -ErrorAction Stop | Out-Null
        } else {
            New-NetFirewallRule -DisplayName $DisplayName -Direction Outbound -Action Block -Program $Program -ErrorAction Stop | Out-Null
        }

        $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction Stop
        if ($rule.Enabled -eq 'True') {
            Write-Ok "firewall rule: $DisplayName"
        } else {
            Write-Fail "firewall rule exists but is disabled: $DisplayName"
        }
    } catch {
        Write-Fail "firewall rule ${DisplayName}: $($_.Exception.Message)"
    }
}


# =============================================================================
# Store apps
# =============================================================================

function Test-StoreAppPresent {
    param([string]$Name)

    $installed   = @($script:installedApps   | Where-Object { $_.Name -eq $Name }).Count
    $provisioned = @($script:provisionedApps | Where-Object { $_.DisplayName -eq $Name }).Count
    return (($installed + $provisioned) -gt 0)
}

# Removes an app for all users and from the list of apps that new users receive.
function Remove-StoreApp {
    param([string]$Name)

    $installed   = @($script:installedApps   | Where-Object { $_.Name -eq $Name })
    $provisioned = @($script:provisionedApps | Where-Object { $_.DisplayName -eq $Name })

    if (($installed.Count + $provisioned.Count) -eq 0) {
        Write-Info "$Name is not installed"
        return
    }
    if ($DryRun) {
        Write-Info "would remove $Name"
        return
    }

    Write-Info "removing $Name ..."
    $script:attemptedApps.Add($Name)

    foreach ($package in $installed) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
        } catch {
            Write-Fail "$Name (installed copy): $($_.Exception.Message)"
        }
    }
    foreach ($package in $provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
        } catch {
            Write-Fail "$Name (provisioned copy): $($_.Exception.Message)"
        }
    }
}

# Reads the app lists again and reports for every attempted app whether it is really gone.
function Confirm-AppsRemoved {
    if ($script:attemptedApps.Count -eq 0) { return }

    $installedNow   = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    $provisionedNow = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    if ($installedNow.Count -lt 5) {
        Write-Fail 'Could not read the installed apps again, so the removal could not be verified.'
        return
    }

    foreach ($name in $script:attemptedApps) {
        $stillInstalled   = @($installedNow   | Where-Object { $_.Name -eq $name }).Count
        $stillProvisioned = @($provisionedNow | Where-Object { $_.DisplayName -eq $name }).Count

        if (($stillInstalled + $stillProvisioned) -eq 0) {
            Write-Ok "$name removed"
        } else {
            Write-Fail "$name is still there ($stillInstalled installed, $stillProvisioned provisioned)"
        }
    }
}


# =============================================================================
# Files and folders
# =============================================================================

# Deletes everything inside a folder but keeps the folder. Files in use are left alone.
function Clear-FolderContents {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Info "$Path does not exist"
        return
    }
    if ($DryRun) {
        Write-Info "would empty $Path"
        return
    }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $remaining = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count
    if ($remaining -eq 0) {
        Write-Ok "emptied $Path"
    } else {
        Write-Info "emptied $Path except $remaining item(s) that are in use"
    }
}

# Deletes a folder that Windows protects (Windows.old and similar).
function Remove-LockedFolder {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Info "$Path does not exist"
        return
    }
    if ($DryRun) {
        Write-Info "would delete $Path"
        return
    }

    Write-Info "deleting $Path (this can take several minutes) ..."

    # Take ownership, give Administrators full control, then let cmd delete the tree.
    # "rd" does not follow junctions, and Windows.old is full of them.
    takeown.exe /f $Path /r /d y 2>&1 | Out-Null
    icacls.exe $Path /grant '*S-1-5-32-544:F' /t /c /q 2>&1 | Out-Null
    Start-Process -FilePath cmd.exe -ArgumentList ('/c rd /s /q "{0}"' -f $Path) -Wait -WindowStyle Hidden

    if (Test-Path -LiteralPath $Path) {
        Write-Fail "$Path could not be deleted completely"
    } else {
        Write-Ok "deleted $Path"
    }
}


# =============================================================================
# Programs: OneDrive, Edge, Office
# =============================================================================

function Remove-OneDrive {
    # Desktop, Documents or Pictures may live inside OneDrive. Uninstalling would then hide your files.
    $shellFolders = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $insideOneDrive = @($shellFolders.PSObject.Properties |
        Where-Object { ($_.Name -notlike 'PS*') -and ("$($_.Value)" -match 'OneDrive') })
    if ($insideOneDrive.Count -gt 0) {
        Write-Fail 'OneDrive was NOT removed: Desktop, Documents or Pictures are stored in OneDrive. Move them back first.'
        return
    }
    if ($DryRun) {
        Write-Info 'would uninstall OneDrive'
        return
    }

    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue

    $setup = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'
    if (-not (Test-Path -LiteralPath $setup)) {
        $setup = Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'
    }
    if (-not (Test-Path -LiteralPath $setup)) {
        Write-Fail 'OneDriveSetup.exe was not found'
        return
    }

    try {
        Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -ErrorAction Stop
    } catch {
        Write-Fail "OneDrive uninstall: $($_.Exception.Message)"
        return
    }

    $leftovers = @(
        "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
        "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ }

    if (@($leftovers).Count -eq 0) {
        Write-Ok 'OneDrive removed'
    } else {
        Write-Fail "OneDrive is still installed: $(@($leftovers) -join ', ')"
    }
}

function Remove-Edge {
    $edgeExe = Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe'

    # Never remove the only browser.
    $otherBrowsers = @(Get-ChildItem -Path 'HKLM:\SOFTWARE\Clients\StartMenuInternet' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -notmatch 'Edge|IEXPLORE' })
    if ($otherBrowsers.Count -eq 0) {
        Write-Fail 'Edge was NOT removed: no other web browser is installed. Install one first.'
        return
    }
    if ($DryRun) {
        Write-Info 'would uninstall Microsoft Edge'
        return
    }

    $uninstallKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
    $entry = Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction SilentlyContinue
    if (-not $entry) {
        Write-Info 'Microsoft Edge has no uninstall entry'
        return
    }

    Stop-Process -Name msedge -Force -ErrorAction SilentlyContinue

    try {
        # The command looks like:  "C:\...\setup.exe" --uninstall --msedge --system-level --verbose-logging
        $parts = $entry.UninstallString -split '"', 3
        $setupExe = $parts[1]
        $setupArguments = $parts[2].Trim() + ' --force-uninstall'
        Start-Process -FilePath $setupExe -ArgumentList $setupArguments -Wait -ErrorAction Stop
    } catch {
        Write-Fail "Edge uninstall: $($_.Exception.Message)"
        return
    }

    if (Test-Path -LiteralPath $edgeExe) {
        Write-Fail 'Edge is still installed. Outside the EEA, Windows can block removing it.'
    } else {
        Write-Ok 'Edge removed (the WebView2 runtime stays on purpose; other apps need it)'
    }
}

function Get-OfficeUninstallEntries {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    return @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.UninstallString -like '*OfficeClickToRun.exe*' })
}

function Remove-Office {
    if ($DryRun) {
        Write-Info 'would uninstall Microsoft Office'
        return
    }

    [void](Read-Host 'Save your work and close Word, Excel, PowerPoint and Outlook, then press Enter')

    for ($pass = 1; $pass -le 3; $pass++) {
        $entries = @(Get-OfficeUninstallEntries)
        if ($entries.Count -eq 0) { break }

        try {
            # The command looks like:  "C:\...\OfficeClickToRun.exe" scenario=install scenariosubtype=ARP ...
            $parts = $entries[0].UninstallString -split '"', 3
            $officeArguments = $parts[2].Trim() + ' DisplayLevel=False forceappshutdown=True'
            Start-Process -FilePath $parts[1] -ArgumentList $officeArguments -Wait -ErrorAction Stop
        } catch {
            Write-Fail "Office uninstall: $($_.Exception.Message)"
            return
        }
    }

    if (@(Get-OfficeUninstallEntries).Count -eq 0) {
        Write-Ok 'Microsoft Office removed'
    } else {
        Write-Fail 'Microsoft Office is still installed'
    }
}


# =============================================================================
# Safety net: restore point and backups
# =============================================================================

function New-SafetyRestorePoint {
    $frequencyKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'

    try {
        Enable-ComputerRestore -Drive "$systemDrive\" -ErrorAction Stop

        # Windows normally allows one restore point per 24 hours. Allow one right now.
        New-ItemProperty -LiteralPath $frequencyKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description 'Win11-DeepDebloat (before changes)' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop

        $created = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
            Where-Object { $_.Description -like 'Win11-DeepDebloat*' })
        if ($created.Count -eq 0) { throw 'The restore point was not found after creating it.' }

        Write-Ok 'restore point created'
    } catch {
        Write-Fail "restore point: $($_.Exception.Message)"
        if (-not (Read-YesNo 'No restore point could be created. Continue anyway?' $false)) {
            throw 'Stopped because there is no restore point. Nothing was changed.'
        }
    } finally {
        Remove-ItemProperty -LiteralPath $frequencyKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
    }
}

function Save-Backups {
    $backupFolder = Join-Path $logFolder "backup-$stamp"
    New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null

    Get-Service | Select-Object Name, DisplayName, StartType, Status |
        Export-Csv -Path (Join-Path $backupFolder 'services-before.csv') -NoTypeInformation
    Get-ScheduledTask | Select-Object TaskPath, TaskName, State |
        Export-Csv -Path (Join-Path $backupFolder 'tasks-before.csv') -NoTypeInformation

    $registryKeys = @(
        'HKLM\SOFTWARE\Policies\Microsoft',
        'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Search',
        'HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings'
    )
    foreach ($key in $registryKeys) {
        $file = Join-Path $backupFolder (($key -replace '[\\:]', '_') + '.reg')
        reg.exe export $key $file /y 2>&1 | Out-Null
    }

    Write-Ok "backups saved in $backupFolder"
}


# =============================================================================
# Start
# =============================================================================

Write-Host ''
Write-Host 'Win11-DeepDebloat 2.0' -ForegroundColor Cyan
if ($DryRun) { Write-Host 'DRY RUN: nothing will be changed.' -ForegroundColor Magenta }

New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
try {
    Start-Transcript -Path (Join-Path $logFolder "log-$stamp.txt") | Out-Null
} catch {
    Write-Info "Could not start the log file: $($_.Exception.Message)"
}

Write-Section 'Checking this PC'

$build = [int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber
if ($build -lt 22000) {
    throw "This script is for Windows 11 (build 22000 or newer). This PC has build $build."
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Open the 64-bit Windows PowerShell (not the x86 one) and run the script again.'
}

$script:installedApps   = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
$script:provisionedApps = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
if ($script:installedApps.Count -lt 5) {
    throw 'Cannot list the installed Store apps. Run this script in Windows PowerShell 5.1 started as Administrator.'
}
Write-Info "Windows build $build, $($script:installedApps.Count) Store packages, $($script:provisionedApps.Count) provisioned packages"

$rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                 (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($rebootPending) {
    Write-Info 'A restart is pending: leftover upgrade folders will be skipped. Restart and run again to remove them.'
}


# =============================================================================
# Questions
# =============================================================================

# Apps that only some people use. Default = the recommended answer.
$optionalApps = @(
    @{ Name = 'Camera'; Default = $false; Packages = @('Microsoft.WindowsCamera') },
    @{ Name = 'Photos'; Default = $false; Packages = @('Microsoft.Windows.Photos', 'Microsoft.Photos.MediaEngineDLC');
       Note = 'Without Photos, pictures have no default viewer until you install one.' },
    @{ Name = 'Paint'; Default = $false; Packages = @('Microsoft.Paint') },
    @{ Name = 'Snipping Tool'; Default = $false; Packages = @('Microsoft.ScreenSketch') },
    @{ Name = 'Notepad'; Default = $false; Packages = @('Microsoft.WindowsNotepad');
       Note = 'Only remove Notepad if you use another text editor.' },
    @{ Name = 'Calculator'; Default = $false; Packages = @('Microsoft.WindowsCalculator') },
    @{ Name = 'Alarms & Clock'; Default = $false; Packages = @('Microsoft.WindowsAlarms') },
    @{ Name = 'Sticky Notes'; Default = $false; Packages = @('Microsoft.MicrosoftStickyNotes') },
    @{ Name = 'Media Player and Movies & TV'; Default = $true; Packages = @('Microsoft.ZuneMusic', 'Microsoft.ZuneVideo') },
    @{ Name = 'Sound Recorder'; Default = $true; Packages = @('Microsoft.WindowsSoundRecorder') },
    @{ Name = 'Microsoft To Do'; Default = $true; Packages = @('Microsoft.Todos') },
    @{ Name = 'Mail, Calendar and People (retired apps)'; Default = $true;
       Packages = @('microsoft.windowscommunicationsapps', 'Microsoft.People') },
    @{ Name = 'New Outlook'; Default = $true; Packages = @('Microsoft.OutlookForWindows') },
    @{ Name = 'OneNote (Store app)'; Default = $true; Packages = @('Microsoft.Office.OneNote') },
    @{ Name = 'Maps'; Default = $true; Packages = @('Microsoft.WindowsMaps') },
    @{ Name = 'Phone Link'; Default = $true; Packages = @('Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice') },
    @{ Name = 'Microsoft Teams (chat app)'; Default = $true; Packages = @('MicrosoftTeams', 'MSTeams') },
    @{ Name = 'Clipchamp'; Default = $true; Packages = @('Clipchamp.Clipchamp') },
    @{ Name = 'Dev Home'; Default = $true; Packages = @('Microsoft.Windows.DevHome') },
    @{ Name = 'Power Automate'; Default = $true; Packages = @('Microsoft.PowerAutomateDesktop') },
    @{ Name = 'Quick Assist'; Default = $true; Packages = @('MicrosoftCorporationII.QuickAssist') },
    @{ Name = 'Family Safety'; Default = $true; Packages = @('MicrosoftCorporationII.MicrosoftFamily');
       Note = 'Keep it if a child account on this PC is supervised.' },
    @{ Name = 'Journal, Whiteboard, Network Speed Test'; Default = $true;
       Packages = @('Microsoft.MicrosoftJournal', 'Microsoft.Whiteboard', 'Microsoft.NetworkSpeedTest') },
    @{ Name = 'Copilot app'; Default = $true; Packages = @('Microsoft.Copilot') },
    @{ Name = 'Xbox app and Game Bar'; Default = $false;
       Packages = @('Microsoft.GamingApp', 'Microsoft.XboxApp', 'Microsoft.XboxGameOverlay',
                    'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider',
                    'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.Xbox.TCUI', 'Microsoft.GamingServices');
       Note = 'Needed for Game Pass, the Minecraft launcher sign-in and many Store games.' }
)

# Services that only some people need.
$optionalServices = @(
    @{ Name = 'Windows Search indexing'; Default = $false; Services = @('WSearch');
       Note = 'Start menu and File Explorer search become slower.' },
    @{ Name = 'Printing (Print Spooler)'; Default = $false; Services = @('Spooler', 'PrintNotify');
       Note = 'No printers and no "Microsoft Print to PDF".' },
    @{ Name = 'Bluetooth'; Default = $false; Services = @('bthserv', 'BTAGService', 'BthAvctpSvc');
       Note = 'Bluetooth mice, keyboards, headphones and controllers stop working.' },
    @{ Name = 'Location services'; Default = $true; Services = @('lfsvc');
       Note = 'Automatic time zone, Night light by sunset and weather features stop working.' },
    @{ Name = 'Smart-card services'; Default = $true; Services = @('SCardSvr', 'ScDeviceEnum', 'SCPolicySvc');
       Note = 'Keep them if you log in with a smart card or a hardware token.' },
    @{ Name = 'Webcam frame server'; Default = $false; Services = @('FrameServer', 'FrameServerMonitor');
       Note = 'Some apps (browsers, Teams, Zoom) can no longer open the webcam.' }
)

Write-Section 'Questions'
if ($UseDefaults) {
    Write-Info 'Using the recommended answer for every question.'
} else {
    Write-Host '  Answer y or n (any case). Enter accepts the answer shown in capitals.'
}

$appsToRemove = New-Object System.Collections.Generic.List[string]
foreach ($app in $optionalApps) {
    $present = @($app.Packages | Where-Object { Test-StoreAppPresent $_ })
    if ($present.Count -eq 0) { continue }

    if ($app.Note) { Write-Host "  Note: $($app.Note)" -ForegroundColor Yellow }
    if (Read-YesNo "Remove $($app.Name)?" $app.Default) {
        foreach ($package in $app.Packages) { $appsToRemove.Add($package) }
    }
}

# Promo apps that Windows or the PC maker installs (Spotify, Netflix, TikTok, Candy Crush, ...).
$promoPattern = '^(SpotifyAB\.|4DF9E0F8\.Netflix|Disney\.|BytedancePte\.|Facebook\.|9E2F88E3\.Twitter|7EE7776C\.LinkedIn|AmazonVideo\.|king\.com\.|Zynga\.|A278AB0D\.|ROBLOXCORPORATION\.|D5EA27B7\.Duolingo|HuluLLC\.|PandoraMediaInc|NORDCURRENT\.)'
$promoApps = @($script:installedApps | Where-Object { $_.Name -match $promoPattern } |
    Select-Object -ExpandProperty Name -Unique)
if ($promoApps.Count -gt 0) {
    Write-Host "  Promo apps found: $($promoApps -join ', ')"
    if (Read-YesNo 'Remove these promo apps?' $true) {
        foreach ($name in $promoApps) { $appsToRemove.Add($name) }
    }
}

$servicesToDisable = New-Object System.Collections.Generic.List[string]
foreach ($item in $optionalServices) {
    $present = @($item.Services | Where-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue })
    if ($present.Count -eq 0) { continue }

    Write-Host "  Note: $($item.Note)" -ForegroundColor Yellow
    if (Read-YesNo "Turn off $($item.Name)?" $item.Default) {
        foreach ($service in $item.Services) { $servicesToDisable.Add($service) }
    }
}

$removeOneDrive = $false
if ((Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe") -or
    (Test-Path "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe")) {
    $removeOneDrive = Read-YesNo 'Uninstall OneDrive?' $false
}

$removeEdge = $false
if (Test-Path (Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe')) {
    Write-Host '  Note: needs another browser installed. Outside the EEA Windows may bring Edge back after updates.' -ForegroundColor Yellow
    $removeEdge = Read-YesNo 'Uninstall Microsoft Edge?' $false
}

$removeOffice = $false
if (@(Get-OfficeUninstallEntries).Count -gt 0) {
    Write-Host '  Note: this removes the whole Office suite (Word, Excel, PowerPoint, Outlook, ...).' -ForegroundColor Yellow
    $removeOffice = Read-YesNo 'Uninstall Microsoft Office (Word, Excel, PowerPoint, ...)?' $false
}

$turnOffHibernation = $false
if (Test-Path -LiteralPath "$systemDrive\hiberfil.sys") {
    Write-Host '  Note: this also turns off Fast Startup.' -ForegroundColor Yellow
    $turnOffHibernation = Read-YesNo 'Turn off hibernation and delete hiberfil.sys?' $false
}


# =============================================================================
# Confirmation
# =============================================================================

Write-Section 'Ready to apply'

$appsText = 'none'
if ($appsToRemove.Count -gt 0) { $appsText = $appsToRemove -join ', ' }
$servicesText = 'none'
if ($servicesToDisable.Count -gt 0) { $servicesText = $servicesToDisable -join ', ' }

Write-Host '  Always: telemetry and ads settings, telemetry services and tasks, junk apps, junk files.'
Write-Host "  Optional apps to remove : $appsText"
Write-Host "  Optional services to off: $servicesText"
Write-Host "  OneDrive: $removeOneDrive   Edge: $removeEdge   Office: $removeOffice   Hibernation off: $turnOffHibernation"

if (-not $DryRun) {
    if (-not (Read-YesNo 'Apply these changes now?' $true)) {
        Write-Host '  Nothing was changed.'
        return
    }
}


# =============================================================================
# Apply
# =============================================================================

if (-not $DryRun) {
    Write-Section 'Safety net'
    New-SafetyRestorePoint
    Save-Backups
}

$freeBefore = (Get-PSDrive -Name $systemDrive.Substring(0, 1)).Free


Write-Section 'Telemetry and diagnostics settings'
$policies = 'HKLM:\SOFTWARE\Policies\Microsoft'
Set-RegistryValue "$policies\Windows\DataCollection" 'AllowTelemetry' 0
Set-RegistryValue "$policies\Windows\DataCollection" 'DoNotShowFeedbackNotifications' 1
Set-RegistryValue "$policies\Windows\DataCollection" 'DisableOneSettingsDownloads' 1
Set-RegistryValue "$policies\Windows\DataCollection" 'LimitDiagnosticLogCollection' 1
Set-RegistryValue "$policies\Windows\DataCollection" 'LimitDumpCollection' 1
Set-RegistryValue "$policies\Windows\DataCollection" 'AllowDeviceNameInTelemetry' 0
Set-RegistryValue "$policies\Windows\AppCompat" 'AITEnable' 0
Set-RegistryValue "$policies\Windows\AppCompat" 'DisableInventory' 1
Set-RegistryValue "$policies\Windows\AppCompat" 'DisableUAR' 1
Set-RegistryValue "$policies\SQMClient\Windows" 'CEIPEnable' 0
Set-RegistryValue "$policies\Windows\Windows Error Reporting" 'Disabled' 1
Set-RegistryValue "$policies\Windows\Windows Error Reporting" 'DontSendAdditionalData' 1
Set-RegistryValue "$policies\MRT" 'DontReportInfectionInformation' 1
Set-RegistryValue 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
Set-RegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0

# The telemetry trace session that Windows starts at boot.
foreach ($session in 'AutoLogger-Diagtrack-Listener', 'SQMLogger') {
    $sessionKey = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$session"
    if (Test-Path -LiteralPath $sessionKey) {
        Set-RegistryValue $sessionKey 'Start' 0
    } else {
        Write-Info "trace session $session does not exist on this PC"
    }
}

Write-Section 'Activity history, clipboard sync, settings sync'
Set-RegistryValue "$policies\Windows\System" 'EnableActivityFeed' 0
Set-RegistryValue "$policies\Windows\System" 'PublishUserActivities' 0
Set-RegistryValue "$policies\Windows\System" 'UploadUserActivities' 0
Set-RegistryValue "$policies\Windows\System" 'AllowCrossDeviceClipboard' 0
Set-RegistryValue "$policies\Windows\SettingSync" 'DisableSettingSync' 2
Set-RegistryValue "$policies\Windows\SettingSync" 'DisableSettingSyncUserOverride' 1
Set-RegistryValue "$policies\Windows\DeliveryOptimization" 'DODownloadMode' 0

Write-Section 'Ads and suggestions'
Set-RegistryValue "$policies\Windows\AdvertisingInfo" 'DisabledByGroupPolicy' 1
Set-RegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
foreach ($name in 'DisableWindowsConsumerFeatures', 'DisableSoftLanding', 'DisableCloudOptimizedContent',
                  'DisableWindowsSpotlightFeatures', 'DisableThirdPartySuggestions',
                  'DisableTailoredExperiencesWithDiagnosticData') {
    Set-RegistryValue "$policies\Windows\CloudContent" $name 1
}
$contentDelivery = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($name in 'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled',
                  'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'RotatingLockScreenEnabled',
                  'RotatingLockScreenOverlayEnabled', 'SilentInstalledAppsEnabled', 'SoftLandingEnabled',
                  'SlideshowEnabled', 'SystemPaneSuggestionsEnabled', 'SubscribedContent-310093Enabled',
                  'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
                  'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled',
                  'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
                  'SubscribedContent-353698Enabled') {
    Set-RegistryValue $contentDelivery $name 0
}
$explorerAdvanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-RegistryValue $explorerAdvanced 'ShowSyncProviderNotifications' 0
Set-RegistryValue $explorerAdvanced 'Start_IrisRecommendations' 0
Set-RegistryValue $explorerAdvanced 'Start_AccountNotifications' 0
Set-RegistryValue $explorerAdvanced 'Start_TrackProgs' 0

Write-Section 'Web search in Start, Widgets, Teams chat icon'
Set-RegistryValue "$policies\Windows\Windows Search" 'AllowCortana' 0
Set-RegistryValue "$policies\Windows\Windows Search" 'AllowCloudSearch' 0
Set-RegistryValue "$policies\Windows\Windows Search" 'ConnectedSearchUseWeb' 0
Set-RegistryValue "$policies\Windows\Windows Search" 'DisableWebSearch' 1
Set-RegistryValue "$policies\Windows\Explorer" 'DisableSearchBoxSuggestions' 1
Set-RegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
Set-RegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0
Set-RegistryValue "$policies\Dsh" 'AllowNewsAndInterests' 0
Set-RegistryValue "$policies\Windows\Windows Feeds" 'EnableFeeds' 0
Set-RegistryValue "$policies\Windows\Windows Chat" 'ChatIcon' 3

Write-Section 'Recall, Click to Do, Copilot'
Set-RegistryValue "$policies\Windows\WindowsAI" 'DisableAIDataAnalysis' 1
Set-RegistryValue "$policies\Windows\WindowsAI" 'AllowRecallEnablement' 0
Set-RegistryValue "$policies\Windows\WindowsAI" 'DisableClickToDo' 1
Set-RegistryValue "$policies\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1

Write-Section 'Typing, speech and handwriting data'
Set-RegistryValue "$policies\InputPersonalization" 'AllowInputPersonalization' 0
Set-RegistryValue "$policies\InputPersonalization" 'RestrictImplicitInkCollection' 1
Set-RegistryValue "$policies\InputPersonalization" 'RestrictImplicitTextCollection' 1
Set-RegistryValue "$policies\Windows\TabletPC" 'PreventHandwritingDataSharing' 1
Set-RegistryValue "$policies\Windows\HandwritingErrorReports" 'PreventHandwritingErrorReports' 1
Set-RegistryValue 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
Set-RegistryValue 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
Set-RegistryValue 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0

Write-Section 'Telemetry services'
foreach ($name in 'DiagTrack', 'dmwappushservice', 'WerSvc', 'diagnosticshub.standardcollector.service', 'RetailDemo') {
    Disable-WindowsService $name
}

Write-Section 'Telemetry scheduled tasks'
$telemetryTasks = @(
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
    @('\Microsoft\Windows\Application Experience\', 'StartupAppTask'),
    @('\Microsoft\Windows\Autochk\', 'Proxy'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'KernelCeipTask'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload'),
    @('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting'),
    @('\Microsoft\Windows\NetTrace\', 'GatherNetworkInfo'),
    @('\Microsoft\Windows\Device Information\', 'Device'),
    @('\Microsoft\Windows\SettingSync\', 'BackgroundUploadTask'),
    @('\Microsoft\Windows\SettingSync\', 'NetworkStateChangeTask'),
    @('\Microsoft\Office\', 'OfficeTelemetryAgentFallBack2016'),
    @('\Microsoft\Office\', 'OfficeTelemetryAgentLogOn2016')
)
foreach ($task in $telemetryTasks) {
    Disable-TelemetryTask -Path $task[0] -Name $task[1]
}

Write-Section 'Firewall: block the telemetry programs'
Add-FirewallBlockRule -DisplayName 'Win11-DeepDebloat: block DiagTrack service' -Service 'DiagTrack'
$compatTelRunner = Join-Path $env:SystemRoot 'System32\CompatTelRunner.exe'
if (Test-Path -LiteralPath $compatTelRunner) {
    Add-FirewallBlockRule -DisplayName 'Win11-DeepDebloat: block CompatTelRunner' -Program $compatTelRunner
}

Write-Section 'Windows Security: stop sending file samples'
if ($DryRun) {
    Write-Info 'would set sample submission to "never send" and cloud reporting to "basic"'
} else {
    try {
        Set-MpPreference -SubmitSamplesConsent NeverSend -MAPSReporting Basic -ErrorAction Stop
        $defender = Get-MpPreference -ErrorAction Stop
        if ($defender.SubmitSamplesConsent -eq 2) {
            Write-Ok 'Defender no longer sends file samples (protection stays on)'
        } else {
            Write-Fail "Defender sample submission is still $($defender.SubmitSamplesConsent)"
        }
    } catch {
        Write-Fail "Defender settings: $($_.Exception.Message)"
    }
}

Write-Section 'Windows features'
foreach ($feature in 'Recall', 'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2') {
    $state = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
    if (-not $state) {
        Write-Info "feature $feature does not exist on this PC"
        continue
    }
    if ($state.State -like 'Disabled*') {
        Write-Info "feature $feature is already off"
        continue
    }
    if ($DryRun) {
        Write-Info "would turn off feature $feature"
        continue
    }

    try {
        Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -ErrorAction Stop | Out-Null
        if ((Get-WindowsOptionalFeature -Online -FeatureName $feature).State -like 'Disabled*') {
            Write-Ok "feature $feature turned off"
        } else {
            Write-Fail "feature $feature is still on"
        }
    } catch {
        Write-Fail "feature ${feature}: $($_.Exception.Message)"
    }
}

Write-Section 'Removing apps'
$junkApps = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.BingFinance',
    'Microsoft.BingSports', 'Microsoft.549981C3F5F10', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.WindowsFeedbackHub',
    'Microsoft.MSPaint', 'Microsoft.Microsoft3DViewer', 'Microsoft.Print3D', 'Microsoft.MixedReality.Portal',
    'Microsoft.SkypeApp', 'Microsoft.Wallet', 'Microsoft.OneConnect', 'Microsoft.Messaging',
    'Microsoft.Office.Sway', 'MicrosoftWindows.Client.WebExperience'
)
foreach ($name in $junkApps) { Remove-StoreApp $name }
foreach ($name in $appsToRemove) { Remove-StoreApp $name }
Confirm-AppsRemoved

if ($removeOneDrive -or $removeEdge -or $removeOffice) {
    Write-Section 'Removing programs'
    if ($removeOneDrive) { Remove-OneDrive }
    if ($removeEdge)     { Remove-Edge }
    if ($removeOffice)   { Remove-Office }
}

if ($servicesToDisable.Count -gt 0) {
    Write-Section 'Turning off the services you chose'
    foreach ($name in $servicesToDisable) { Disable-WindowsService $name }
}

if ($turnOffHibernation) {
    Write-Section 'Hibernation'
    if ($DryRun) {
        Write-Info 'would turn off hibernation'
    } else {
        powercfg.exe /hibernate off
        if (Test-Path -LiteralPath "$systemDrive\hiberfil.sys") {
            Write-Fail 'hiberfil.sys is still there'
        } else {
            Write-Ok 'hibernation off, hiberfil.sys deleted'
        }
    }
}

Write-Section 'Junk files'
if (-not $rebootPending) {
    Remove-LockedFolder "$systemDrive\Windows.old"
    Remove-LockedFolder "$systemDrive\`$Windows.~BT"
    Remove-LockedFolder "$systemDrive\`$Windows.~WS"
}

# The update download cache is in use by Windows Update: stop those services while we empty it.
$stoppedServices = @()
if (-not $DryRun) {
    foreach ($name in 'wuauserv', 'bits') {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            $stoppedServices += $name
        }
    }
}
Clear-FolderContents "$env:SystemRoot\SoftwareDistribution\Download"
foreach ($name in $stoppedServices) { Start-Service -Name $name -ErrorAction SilentlyContinue }

# The telemetry trace session writes into ETLLogs: stop it first so the files are not locked.
if (-not $DryRun) {
    logman.exe stop 'AutoLogger-Diagtrack-Listener' -ets 2>&1 | Out-Null
}
Clear-FolderContents "$env:ProgramData\Microsoft\Diagnosis\ETLLogs"

Clear-FolderContents "$env:SystemRoot\Temp"
Clear-FolderContents $env:TEMP
Clear-FolderContents "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
Clear-FolderContents "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
Clear-FolderContents "$env:SystemRoot\Minidump"
Clear-FolderContents "$env:SystemRoot\LiveKernelReports"

$memoryDump = Join-Path $env:SystemRoot 'MEMORY.DMP'
if (Test-Path -LiteralPath $memoryDump) {
    if ($DryRun) {
        Write-Info "would delete $memoryDump"
    } else {
        try {
            Remove-Item -LiteralPath $memoryDump -Force -ErrorAction Stop
            Write-Ok "deleted $memoryDump"
        } catch {
            Write-Fail "$memoryDump : $($_.Exception.Message)"
        }
    }
}

Write-Section 'Windows Update leftovers (component store)'
if ($DryRun) {
    Write-Info 'would run: DISM /Online /Cleanup-Image /StartComponentCleanup'
} else {
    Write-Info 'running DISM (this can take several minutes) ...'
    dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {
        Write-Ok 'component store cleaned'
    } else {
        Write-Fail "DISM failed with exit code $LASTEXITCODE"
    }
}


# =============================================================================
# Summary
# =============================================================================

Write-Section 'Summary'

if ($DryRun) {
    Write-Host '  Dry run finished. Nothing was changed.' -ForegroundColor Magenta
} else {
    $freeAfter = (Get-PSDrive -Name $systemDrive.Substring(0, 1)).Free
    Write-Host ('  Changes that worked : {0}' -f $script:okCount) -ForegroundColor Green
    Write-Host ('  Disk space freed    : {0:N2} GB' -f (($freeAfter - $freeBefore) / 1GB))

    if ($script:failures.Count -eq 0) {
        Write-Host '  Nothing failed.' -ForegroundColor Green
    } else {
        Write-Host ('  Changes that FAILED : {0}' -f $script:failures.Count) -ForegroundColor Red
        foreach ($message in $script:failures) {
            Write-Host "    - $message" -ForegroundColor Red
        }
    }
    Write-Host "  Log and backups     : $logFolder"
    Write-Host '  Restart the PC to finish.'
}

try {
    Stop-Transcript | Out-Null
} catch {
    # No transcript was running; nothing to stop.
    $null = $_
}
