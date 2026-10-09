# Win11-DeepDebloat

**Deep, verified debloat of Windows 11 - telemetry, tracking, ads, AI-snapshot features, bloatware and junk files - with a Y/N choice for everything people actually use.**

![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue)
![Windows 11](https://img.shields.io/badge/Windows-11_build_22000%2B-0078D4)
![Single file](https://img.shields.io/badge/single%20file-no%20downloads-success)
![Status](https://img.shields.io/badge/status-v1.0.0-informational)

> [!WARNING]
> **Read this first.** This tool changes many system settings, removes apps and deletes files.
> v1.0.0 has been written and statically reviewed (syntax balance, ASCII-only, function cross-references) but has **not yet been validated end-to-end on every Windows 11 build**.
> Treat your first run as a test: use `-DryRun`, a virtual machine, or at least a System Restore point (created automatically). Do **not** run it on a work or school managed PC.

---

## Contents

- [Why this exists](#why-this-exists)
- [At a glance](#at-a-glance)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Parameters](#parameters)
- [Walkthrough](#walkthrough)
- [What is always applied](#what-is-always-applied)
- [Optional items (Y/N)](#optional-items-yn)
- [How verification works](#how-verification-works)
- [Safety model](#safety-model)
- [Undo / restore](#undo--restore)
- [State directory, logs and reports](#state-directory-logs-and-reports)
- [Keeping it clean after Windows updates](#keeping-it-clean-after-windows-updates)
- [Limits - what this tool cannot do](#limits---what-this-tool-cannot-do)
- [FAQ and troubleshooting](#faq-and-troubleshooting)
- [Compatibility](#compatibility)
- [Development guide](#development-guide)
- [Security and auditability](#security-and-auditability)
- [Changelog](#changelog)
- [License](#license)
- [References](#references)

---

## Why this exists

Windows 11 ships with a lot you did not ask for: diagnostic-data collection, advertising and "suggestions" in Start, Settings and the lock screen, web results in local search, cloud-synced clipboard and activity history, consumer apps, AI features that snapshot your screen, and gigabytes of leftover installer, log and cache files.

Most debloat scripts run a long list of commands and hope for the best. They never check whether a change stuck, they cannot be undone, and they remove things you may use.

Win11-DeepDebloat works differently:

1. **Every change is a task with an Apply step and a Verify step.** After applying, the script reads the system again (registry value, service start type, task state, package presence, file on disk) and reports `PASS`, `WARN` or `FAIL`. Nothing is assumed to have worked.
2. **Telemetry, tracking, ads and junk are never optional.** Things that only *some* people use - Camera, Photos, Notepad, Xbox, Phone Link, Office/Word, OneDrive, Edge, Bluetooth, printing, search indexing - are asked one by one (Y/N), and only if they are actually present on the PC.
3. **It is reversible where reversibility is possible.** The original value of every registry value, service start type, scheduled-task state and Defender preference is recorded once, before the first change, and `-Restore` puts it back.
4. **It refuses dangerous actions.** For example it will not uninstall OneDrive while your Documents folder lives inside it, and will not uninstall Edge when no other browser is installed.
5. **It is auditable.** One readable ASCII script, no obfuscation, no downloads, no network access of its own.

## At a glance

| | Behaviour |
|---|---|
| **Always applied** (no questions) | Telemetry / diagnostic-data / CEIP / error-reporting policies, services and scheduled tasks; the ETW AutoLogger sessions that start the telemetry pipeline at boot; outbound firewall blocks for the telemetry binaries; Defender sample sharing off; Recall / Click to Do / Copilot policies; advertising ID, Start / lock-screen / Settings suggestions; web results in Start search; Widgets and news feeds; cloud clipboard, activity history, settings sync; consumer junk apps; legacy Windows features; junk and leftover files |
| **You decide** (Y/N per item) | 40 catalog items (apps, desktop software, services, features), plus detected third-party promo apps and OEM apps - see [Optional items](#optional-items-yn) |
| **Never touched** | Windows Update, Microsoft Defender protection, SmartScreen, the Windows Firewall itself (it only *adds* rules), Microsoft Store, winget, Windows Terminal, the WebView2 runtime, drivers. Files under `System32` / `WinSxS` are never deleted by hand (only DISM touches the component store) |

## Requirements

- Windows 11, build 22000 or newer (Home, Pro, Enterprise, Education).
- **Windows PowerShell 5.1** (built into Windows). If you start it from PowerShell 7 it relaunches itself in 5.1.
- Local administrator rights. The script elevates itself (UAC prompt) when needed.
- About 3 GB of free disk space is recommended for the component-store cleanup.
- A **personal, unmanaged PC**. A warning is shown if MDM/Intune enrollment is detected.

## Quick start

```powershell
# 1. Save Win11-DeepDebloat.ps1 to a local folder (for example C:\Tools), then unblock it
Unblock-File .\Win11-DeepDebloat.ps1

# 2. Preview: reads the system, changes nothing (-Defaults skips the questions)
powershell.exe -ExecutionPolicy Bypass -File .\Win11-DeepDebloat.ps1 -DryRun -Defaults

# 3. Run it for real: questions -> plan -> type YES -> restore point -> apply + verify -> report
powershell.exe -ExecutionPolicy Bypass -File .\Win11-DeepDebloat.ps1

# 4. Reboot, then confirm that everything stuck
powershell.exe -ExecutionPolicy Bypass -File .\Win11-DeepDebloat.ps1 -VerifyOnly
```

Run it from a normal console; the script opens an elevated window if it is not already elevated and keeps that window open at the end so you can read the report.

## Parameters

| Parameter | Description |
|---|---|
| `-DryRun` | Show what would be done. Nothing is modified (only a log file is written; other users' registry hives are loaded temporarily to read them). It asks the same questions as a real run so the preview matches your answers - add `-Defaults` to skip them. |
| `-VerifyOnly` | Re-check the result of a previous run, using `-Config` or the last saved `choices.json`. Nothing is modified. Run it after every Windows feature update. |
| `-Restore` | Revert registry values, service start types, scheduled tasks, firewall rules and Defender preferences to what they were before the **first** run. See [Undo / restore](#undo--restore). |
| `-Config <path>` | Use a `choices.json` written by a previous run. Skips all questions. Items missing from the file use their default. |
| `-Defaults` | Answer every optional question with its default. Skips all questions. |
| `-Yes` | Skip the final "type YES" confirmation (unattended use). |
| `-NoRestorePoint` | Do not create a System Restore point first. |
| `-SkipCleanup` | Skip file clean-up and the component-store cleanup (also hides the hibernation and `/ResetBase` questions). Use it if you still need crash dumps or `Windows.old`. |
| `-StateDir <path>` | Where baseline, choices, logs and reports are kept. Default: `%ProgramData%\Win11DeepDebloat`. |

Exit codes: `0` = finished, no `FAIL`; `1` = at least one item did not verify (`FAIL`); `2` = fatal error (nothing more was attempted).

### Examples

```powershell
# Interactive run
.\Win11-DeepDebloat.ps1

# Preview with every default answer
.\Win11-DeepDebloat.ps1 -DryRun -Defaults

# Repeat a previous run unattended (for example after a feature update)
.\Win11-DeepDebloat.ps1 -Config C:\ProgramData\Win11DeepDebloat\choices.json -Yes

# Only check that everything is still applied
.\Win11-DeepDebloat.ps1 -VerifyOnly

# Telemetry / ads / bloat only: keep my crash dumps and Windows.old
.\Win11-DeepDebloat.ps1 -SkipCleanup

# Undo the settings changes
.\Win11-DeepDebloat.ps1 -Restore
```

## Walkthrough

1. **Preflight** - Windows 11 build, edition notes (see [Limits](#limits---what-this-tool-cannot-do)), MDM warning, pending-reboot detection, free disk space, Defender Tamper Protection state.
2. **Scan** - installed Store apps, provisioned apps, Windows capabilities and optional features are read once (this can take a minute).
3. **Questions** - only for items that are present. At each prompt:
   - `y` remove / disable, `n` keep, **Enter** accepts the default shown in capitals (`[Y/n]` means default yes, `[y/N]` default no)
   - `d` use the default for **all remaining** items, `k` keep **all remaining** items
   - Items that cannot be removed safely (OneDrive with Known Folder Move, Edge without another browser) are skipped with an explanation.
4. **Plan** - what will be removed, what you keep, what the file clean-up will delete and how many tasks run per phase. You must type `YES` (case-sensitive) to continue.
5. **Restore point** - created and verified. If it cannot be created you are asked whether to continue.
6. **Phases** - each phase applies all of its tasks and then verifies all of them:
   `Policies & settings` -> `Services` -> `Scheduled tasks` -> `Windows features` -> `Apps` -> `Desktop software` -> `Firewall & Defender` -> `Cleanup` -> `Component store`
7. **Report** - totals, every item that did not verify, disk space freed, JSON and CSV reports.

Illustrative output (abridged):

```text
==============================================================================
 Policies & settings  (156 item(s))
==============================================================================
[04:12:20] [OK  ] Diagnostic data, CEIP, error reporting: 19/19 values verified
[04:12:21] [OK  ] Advertising ID, suggestions, consumer content: 52/52 values verified
[04:12:21] [DIM ] (3 item(s) were already absent / already off - verified)

==============================================================================
 Services  (8 item(s))
==============================================================================
[04:12:31] [OK  ] PASS Service disabled: DiagTrack  -  Start=4
[04:12:32] [OK  ] PASS Service disabled: WerSvc  -  Start=4

==============================================================================
 Cleanup  (24 item(s))
==============================================================================
[04:19:48] [OK  ] PASS Clean: C:\Windows.old  -  gone, freed 11.82 GB
[04:19:50] [WARN] WARN Clean: C:\Windows\Temp  -  3 item(s) / 41.2 MB left (in use or protected), freed 912.4 MB

==============================================================================
 Verification report
==============================================================================
[04:31:02] [OK  ] Checked 312 item(s): PASS 311 (already absent/off: 118) | WARN 1 | FAIL 0
```

## What is always applied

### Policies and settings

Registry values are written to `HKLM` and, for per-user settings, to **every user profile on the PC plus the Default profile** (so new users inherit them). Each value is read back afterwards.

| Group | What it does |
|---|---|
| Diagnostic data, CEIP, error reporting | Sets `AllowTelemetry` to 0, stops notifications about feedback, limits log/dump collection, stops OneSettings downloads, stops sending the device name, turns off application-impact telemetry, program inventory and the Steps Recorder, turns off the Customer Experience Improvement Program, disables Windows Error Reporting, stops Malicious Software Removal Tool infection reports, resets feedback frequency, turns off tailored experiences |
| Activity history, cloud clipboard, settings sync | Disables the activity feed and its upload, clipboard sync across devices, settings sync and message sync |
| Advertising ID, suggestions, consumer content | Turns off the advertising ID, Windows Spotlight and consumer features, third-party suggestions, the whole `ContentDeliveryManager` family (silent app installs, lock-screen tips, Settings and Start suggestions), Start promotions and account notifications, sync-provider (OneDrive) ads in File Explorer, app-launch tracking |
| Web search in Start, Widgets, Teams chat icon, news feeds | Disables web results and cloud search in Start, Cortana, search highlights, the Widgets board, the Teams chat icon on the taskbar and legacy news feeds |
| AI features | Disables Recall snapshots (`DisableAIDataAnalysis`, `AllowRecallEnablement`), Click to Do, and sets the Copilot policy |
| Input, speech and handwriting personalization | Disables input personalization, implicit ink/text collection, handwriting data sharing and error reports, contact harvesting, online speech privacy consent |
| Delivery Optimization | Peer-to-peer upload off (`DODownloadMode = 0`: HTTP only) |
| ETW AutoLogger sessions | Sets `Start = 0` on `AutoLogger-Diagtrack-Listener`, `Diagtrack-Listener` and `SQMLogger` (only if present) so the telemetry collection session is not created at boot |
| *Conditional:* Edge policies | If Edge stays: privacy / personalization / shopping / sidebar / startup-boost / background-mode policies (Edge then shows "managed by your organization"). If Edge is removed: Edge Update install is blocked so it does not return |
| *Conditional:* Office policies | If Office stays: connected-experiences, telemetry, CEIP and feedback policies |

### Services (disabled)

| Service | Purpose / reason |
|---|---|
| `DiagTrack` | Connected User Experiences and Telemetry - the upload component of the diagnostic-data pipeline |
| `dmwappushservice` | WAP push routing - telemetry and device-management plumbing (do not use this tool on MDM-managed PCs) |
| `diagnosticshub.standardcollector.service` | Diagnostics Hub collector |
| `WerSvc` | Windows Error Reporting |
| `RetailDemo` | Retail demo mode |
| `WMPNetworkSvc` | Media Player network sharing |
| `MixedRealityOpenXRSvc`, `SharedRealitySvc` | Retired mixed-reality services |

### Scheduled tasks (disabled)

| Area | Tasks |
|---|---|
| Application Experience | `Microsoft Compatibility Appraiser`, `ProgramDataUpdater`, `StartupAppTask`, `MareBackup` |
| Autochk | `Proxy` |
| Customer Experience Improvement Program | `Consolidator`, `KernelCeipTask`, `UsbCeip`, `BthSQM` |
| Disk diagnostics | `Microsoft-Windows-DiskDiagnosticDataCollector` |
| Feedback | `DmClient`, `DmClientOnScenarioDownload` |
| Error reporting | `QueueReporting` |
| Network / device info | `GatherNetworkInfo`, `Device`, `Device User` |
| Flighting | `OneSettings\RefreshCache` |
| Settings sync | `BackgroundUploadTask`, `NetworkStateChangeTask` |
| Office telemetry agent | `OfficeTelemetryAgentFallBack`, `...FallBack2016`, `...LogOn`, `...LogOn2016` |

### Windows features and capabilities (removed)

- Optional features: `Recall`, PowerShell 2.0 (`MicrosoftWindowsPowerShellV2Root`, `MicrosoftWindowsPowerShellV2`), Work Folders client, XPS Services, Fax and Scan client.
- Capabilities: Steps Recorder, WordPad, Math Input (`MathRecognizer`).

### Store apps removed without asking

Bing News, Weather, Search, Finance, Sports, Travel, Food & Drink, Health & Fitness; Cortana; Get Help; Tips; Microsoft 365 (Office hub); Solitaire Collection; Feedback Hub; Paint 3D; 3D Viewer; Print 3D; Mixed Reality Portal; Skype; Wallet; OneConnect; Messaging; Sway; Power BI; Reading List; and the Widgets host (`MicrosoftWindows.Client.WebExperience`, reported as `WARN` rather than `FAIL` if the build protects it).

Each package is removed for **all users** and from the **provisioned** list, so it does not come back for new profiles.

### Firewall and Defender

- Outbound **block** rules (group `Win11DeepDebloat`) for the `DiagTrack` service and for `CompatTelRunner.exe`, `DeviceCensus.exe` and `wsqmcons.exe` (when they exist). They keep working even if Windows re-enables the service later.
- Defender: automatic sample submission set to **never send**, cloud reporting set to **basic**. Real-time protection and cloud lookups stay on. If Tamper Protection refuses the change you get a `WARN`, not a failure.

### File clean-up

Every target is measured before and checked after. Anything that cannot be deleted is reported with its remaining size.

| Target | Notes |
|---|---|
| `C:\Windows.old`, `C:\$Windows.~BT`, `C:\$Windows.~WS`, `C:\$WinREAgent` | Skipped in this run if a reboot is pending. Ownership is taken when needed |
| `SoftwareDistribution\Download`, Delivery Optimization cache and logs | `wuauserv`, `bits` and `dosvc` are stopped for the clean-up and restarted if they were running |
| `C:\Windows\Temp`, `Logs\CBS`, `Logs\WindowsUpdate` | In-use files are left alone |
| Crash dumps: `Minidump`, `LiveKernelReports`, `MEMORY.DMP` | Use `-SkipCleanup` if you need them for BSOD analysis |
| `ProgramData\Microsoft\Windows\WER\*` | Error-report archive, queue and temp |
| `ProgramData\Microsoft\Diagnosis\*` | `ETLLogs` (the active ETW session is stopped first), `Scenarios`, `TenantStorage`, `LocalTraceStore`, `FeedbackHub` |
| Per user: `AppData\Local\Temp`, `CrashDumps`, `Microsoft\Windows\WER`, Spotlight `Assets` and `TempState` | Every profile on the PC |
| Component store | `DISM /Online /Cleanup-Image /StartComponentCleanup` (never deletes `WinSxS` by hand) |

## Optional items (Y/N)

An item is asked **only if it is present**. *Default* is what Enter does; `-Defaults` uses it for everything.

### Microsoft apps

| ID | Item | Default | Notes |
|---|---|:---:|---|
| `camera` | Camera app | N | Only the app; webcams keep working in other apps |
| `photos` | Photos | N | Install another image viewer first |
| `paint` | Paint | N | |
| `snip` | Snipping Tool | N | Win+Shift+S uses it |
| `notepad` | Notepad (Store version) | N | Only if you use another editor |
| `calc` | Calculator | N | |
| `clock` | Alarms & Clock | N | |
| `sticky` | Sticky Notes | N | |
| `media` | Media Player + Movies & TV | Y | |
| `recorder` | Sound Recorder | Y | |
| `todo` | Microsoft To Do | Y | |
| `mail` | Mail & Calendar + People (retired) | Y | Also disables `OneSyncSvc`, `PimIndexMaintenanceSvc` |
| `outlook` | New Outlook | Y | Not the classic Outlook from Office |
| `onenote` | OneNote (Store app) | Y | |
| `maps` | Maps | Y | Also disables `MapsBroker` and the Maps tasks |
| `phone` | Phone Link / Cross Device | Y | Also disables `PhoneSvc` |
| `teams` | Microsoft Teams chat app + machine-wide installer | Y | |
| `clipchamp` | Clipchamp | Y | |
| `devhome` | Dev Home | Y | |
| `pa` | Power Automate | Y | |
| `quickassist` | Quick Assist (app + capability) | Y | Often abused by tech-support scammers |
| `family` | Microsoft Family Safety | Y | Keep it if a child account is supervised here |
| `misc` | Journal, Whiteboard, Network Speed Test | Y | |
| `copilot` | Copilot app | Y | Recall / Click to Do are disabled regardless |

### Gaming

| ID | Item | Default | Notes |
|---|---|:---:|---|
| `xbox` | Xbox app, Game Bar, Xbox sign-in components, Xbox services, Game DVR | N | Needed for Game Pass, Minecraft launcher sign-in and many Store games |

### Desktop software

| ID | Item | Default | Notes |
|---|---|:---:|---|
| `office` | Microsoft Office / Microsoft 365 desktop apps (Word, Excel, PowerPoint, Outlook ...) | N | Removes the **whole** suite (Click-to-Run, MSI or Store edition); per-app removal is not possible offline. You are asked to save and close Office first |
| `onedrive` | OneDrive | N | Refused automatically if Desktop / Documents / Pictures are redirected into OneDrive (Known Folder Move). The `OneDrive` folder is deleted only if it contains no files |
| `edge` | Microsoft Edge (browser) | N | Needs another browser installed. WebView2 runtime and Edge Update stay. Not officially supported outside the EEA; Windows may bring Edge back - re-run after updates |

### Services and features

| ID | Item | Default | Notes |
|---|---|:---:|---|
| `search_index` | Windows Search indexing (`WSearch`) | N | Search gets slower |
| `spooler` | Printing (`Spooler`, `PrintNotify`) | N | No printers, no "Microsoft Print to PDF" |
| `bluetooth` | Bluetooth services | N | Bluetooth devices stop working |
| `location` | Location services + Find My Device | Y | Auto time zone, Night light by sunset and weather features stop working |
| `pca` | Program Compatibility Assistant | Y | Also disables its database task |
| `webcam` | Webcam frame server | N | Some apps can no longer open the webcam |
| `smartcard` | Smart-card services | Y | Keep if you use a smart card or hardware token |
| `cdp` | Connected Devices Platform | N | Nearby sharing and wireless display (Win+K) stop working |
| `wmp` | Windows Media Player Legacy | Y | |
| `speechlang` | Speech and handwriting language features | N | Voice typing and handwriting need them |
| `hibernate` | Hibernation (deletes `hiberfil.sys`) | N | Also turns off Fast Startup |
| `resetbase` | Deep component-store cleanup (`/ResetBase`) | N | **Irreversible**: installed updates can no longer be uninstalled |

### Detected at run time

| ID | Item | Default | Notes |
|---|---|:---:|---|
| `promo` | Third-party promo apps that were found (Spotify, Netflix, Disney+, TikTok, Facebook/Instagram, X/Twitter, LinkedIn, Prime Video, Candy Crush and similar) | Y | The names found are listed in the prompt - answer `n` if you actually use one |
| `oem:<PackageName>` | One question per OEM / vendor package (HP, Dell, Lenovo, ASUS, Acer, Samsung, McAfee, Norton, ExpressVPN, Dropbox, Evernote) | N | May be a driver, hotkey or control utility - keep it if unsure |

## How verification works

| Task type | What is checked after applying |
|---|---|
| Registry value | The value is read back in `HKLM` and in every loaded and Default user hive; mismatches are listed per hive |
| Service | Start type is `Disabled` (registry `Start = 4`); a note is added if the service is still running until reboot |
| Scheduled task | State is `Disabled` (or the task does not exist) |
| Store app | No installed package (any user) **and** no provisioned package remains |
| Windows feature / capability | State is queried again from DISM after the change |
| File or folder | The path is checked on disk again; sizes before and after are compared |
| Firewall | Each rule exists and is enabled |
| Defender | `Get-MpPreference` shows the expected values |
| Edge / OneDrive / Office / Teams | Uninstall entries, executables and processes are gone |
| Component store | DISM exit code is 0 or 3010 (reboot required) |

Result states:

- **PASS** - the desired state was confirmed. Items that were already in the desired state are counted separately ("already absent/off") and summarised in one line.
- **WARN** - a *soft* item did not verify. Soft items are things Windows may legitimately protect or restore: some scheduled tasks, per-user service templates, in-use temp files, Defender settings under Tamper Protection, Edge/Office/OneDrive uninstalls.
- **FAIL** - a hard item did not verify (for example a telemetry service that is still enabled, or `Windows.old` still on disk).

## Safety model

- **Restore point** first (verified). Skip with `-NoRestorePoint`.
- **Baseline**: the original state of every registry value, service start type, scheduled task and Defender preference is saved once, before its first change, to `baseline.json`. Re-running never overwrites the original.
- **Confirmation**: you see the full plan and must type `YES`.
- **Guards**: Windows 11 only; OneDrive refused under Known Folder Move; Edge refused without another browser; Office removal first asks you to save and close your documents (anything still open is then closed); upgrade-staging folders skipped while a reboot is pending.
- **Protected paths**: the deleter refuses system roots (`C:\`, `Windows`, `System32`, `Users`, `Program Files`, `ProgramData` ...), never follows junctions or symlinks, and supports long paths.
- **Multi-user aware**: other users' registry hives are loaded temporarily so their per-user settings are applied too. A profile that cannot be loaded is skipped with a warning. Per-user uninstalls (OneDrive) run for the current user; other users are flagged in the report.
- **No hosts-file edits**: Windows Defender has been reported to flag hosts-file blocking of Microsoft telemetry domains as a threat, and the hosts file cannot use wildcards. Blocking is done with firewall rules for the telemetry binaries instead.
- **Left alone on purpose**: Windows Update, Defender protection, SmartScreen, the Store, winget, Terminal, WebView2, Edge Update, drivers.

## Undo / restore

```powershell
.\Win11-DeepDebloat.ps1 -Restore
```

| Restored | Not restored automatically |
|---|---|
| Registry values (written or deleted by the tool, in HKLM and user hives) | Removed Store apps - reinstall from the Microsoft Store or `winget` (a list of what was removed is saved to `logs\removed-apps-*.txt`) |
| Service start types | Uninstalled software (Edge, OneDrive, Office, Teams installer) |
| Scheduled tasks that were enabled before | Removed Windows features / capabilities (re-add in *Settings > System > Optional features* or *Windows features*) |
| Defender sample-submission and cloud-reporting preferences | Deleted files (`Windows.old`, caches, dumps) |
| Firewall rules in group `Win11DeepDebloat` are deleted | Component-store cleanup (especially `/ResetBase`) |

For anything else use the System Restore point created before the run. Reboot after restoring.

## State directory, logs and reports

Default: `%ProgramData%\Win11DeepDebloat\`

```text
Win11DeepDebloat\
  baseline.json                     original values, written once - used by -Restore
  choices.json                      your answers from the last run - used by -Config / -VerifyOnly
  logs\
    run-<timestamp>.log             full log of the run
    removed-apps-<timestamp>.txt    full names of the Store packages that were removed
  reports\
    report-<timestamp>.json         every checked item with status and detail
    report-<timestamp>.csv          the same, for a spreadsheet
```

`choices.json` is plain JSON; edit it to change an answer and pass it with `-Config`:

```json
{
  "version": 1,
  "created": "2026-10-09T04:12:00",
  "choices": {
    "camera": false,
    "xbox": false,
    "edge": false,
    "onedrive": false,
    "office": false,
    "promo": true,
    "oem:AD2F1837.HPSupportAssistant": false
  }
}
```

## Keeping it clean after Windows updates

Cumulative and feature updates can re-enable services, tasks or settings and can re-provision apps. The tool is idempotent, so:

1. After each feature update run `.\Win11-DeepDebloat.ps1 -VerifyOnly` - it lists exactly what drifted.
2. Re-apply with `.\Win11-DeepDebloat.ps1 -Config <path to choices.json> -Yes`.

The script deliberately installs **no scheduled task or background service of its own**.

## Limits - what this tool cannot do

It reduces and blocks Windows data collection; it does not make Windows "telemetry-free", and you should not expect that from any script.

- **Diagnostic-data floor.** On Windows 11 Home and Pro the lowest level is *Required diagnostic data*. "Off" exists only on Enterprise, Education and Server. The policy is written on every edition, but on Home/Pro Windows treats 0 as *Required*.
- **How the pipeline is built.** Windows telemetry is event tracing (ETW): kernel-mode and user-mode components emit events, trace sessions started at boot buffer them, and the `DiagTrack` service uploads them. This tool stops both ends - it prevents the telemetry trace sessions from being created at boot and disables the upload service, then blocks the binaries at the firewall. It cannot remove kernel components or ETW providers that Microsoft ships; those stay part of the OS even when nothing consumes their events.
- **Windows can change its mind.** Updates may restore settings, re-provision apps or reinstall Edge. Use `-VerifyOnly` regularly.
- **Protected objects.** A few scheduled tasks and service keys are owned by SYSTEM/TrustedInstaller and may refuse changes from an administrator. These are reported as `WARN`.
- **Network-level control is stronger.** For hard guarantees add DNS or firewall filtering on your router. Microsoft documents the diagnostic endpoints (for example `v10.events.data.microsoft.com`, `v10c.events.data.microsoft.com`, `v10.vortex-win.data.microsoft.com`, `watson.telemetry.microsoft.com`, `oca.telemetry.microsoft.com`) and notes that `settings-win.data.microsoft.com` only configures diagnostics and uploads no diagnostic data. Blocking endpoints that Windows Update or the Store need will break those features - read Microsoft's list first.
- **Third-party telemetry** (browsers, drivers, vendor utilities, games) is out of scope except for the OEM apps you choose to remove.
- **Scope.** This is a privacy and debloat tool, not a tweak pack: it does not change themes, taskbar layout or performance settings.

## FAQ and troubleshooting

**Does it break Windows Update or the Store?**
No. Update services are left alone (they are only paused briefly while their download cache is cleared) and Delivery Optimization is set to HTTP-only. The Store and winget are never removed.

**Settings shows "Some settings are managed by your organization".**
Expected. The tool uses the same policy keys an administrator would use. `-Restore` removes them.

**Edge came back after an update.**
Outside the EEA the Edge removal is not officially supported. Re-run the script; keep another browser installed.

**Something I need is gone.**
Reinstall the app from the Microsoft Store (or `winget search <name> --source msstore`). For services run `-Restore`, or set the service back to Manual in `services.msc`. Items that were never selected are not touched.

**Bluetooth / printing / webcam / search stopped working.**
You answered `y` to the matching optional item. Run `-Restore` or re-enable the service named in the table above.

**Some items show `WARN`.**
Read the detail on the line. Typical causes: a file in use (will clear after reboot), a task owned by TrustedInstaller, Tamper Protection. A reboot followed by `-VerifyOnly` shows what remains.

**The script says execution is disabled.**
Start it with `-ExecutionPolicy Bypass` as shown in [Quick start](#quick-start); this applies to that process only. Alternatively `Unblock-File` the downloaded file.

**Antivirus or SmartScreen warns about the script.**
It changes system settings, removes software and edits policies, which can trigger heuristics. Read the source (it is one plain-text file) and run it from a local folder you control.

**Can I run it on PowerShell 7?**
It must run in Windows PowerShell 5.1 (the Appx, DISM and scheduled-task modules are used). If you start it from PowerShell 7 it relaunches itself in 5.1 automatically.

**Is it language dependent?**
No. It addresses services, tasks, packages, SIDs and registry keys by their invariant names and does not parse localized command output. Its own messages are in English.

## Compatibility

| | |
|---|---|
| Required | Windows 11 build 22000+, Windows PowerShell 5.1, administrator |
| Written against | The behaviour of Windows 11 24H2 / 25H2 |
| Newer builds (26H1 / 26H2) | Same documented mechanisms (policies, services, tasks, DISM, Appx); not yet validated - run `-DryRun` first |
| Policies for features a build does not have (Recall, Click to Do) | Written anyway; they have no effect there. Optional features that are absent are reported as "absent" |
| Windows 10 | Not supported (the script stops at preflight) |

## Development guide

The script is a single file organised in numbered sections (elevation, logging, utilities, baseline, user hives, registry helpers, cached inventories, safe deletion, task registry and handlers, catalogs, prompts, plan builder, engine, report, restore, main).

**The task model.** Every change is a task `{ Phase, Kind, Title, Data, Group, Soft }` created with `Add-Task` and executed by the engine. Each `Kind` has an `Invoke-Apply<Kind>` and a `Test-State<Kind>` function; custom tasks name their own `ApplyFn` / `VerifyFn`. A new change is not accepted unless it has a verifier.

**Add a registry value**

```powershell
# Row <Hive> <Path> <Name> <Value> [<Type>] [-Soft] [-IfKey] [-Delete]
# HKLM = machine; HKU = applied to every user profile and the Default profile
Row 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
Row 'HKU'  'Software\Microsoft\Windows\CurrentVersion\Privacy'    'TailoredExperiencesWithDiagnosticDataEnabled' 0
```

**Add an optional item** (an entry in `$Script:Catalog`)

```powershell
@{ Cat = 'Microsoft apps'; Id = 'sticky'; Name = 'Sticky Notes'; Def = 'N'
   Desc = 'Sticky Notes (syncs to your Microsoft account).'
   Warn = 'Optional warning shown at the prompt.'
   Appx = @('Microsoft.MicrosoftStickyNotes')        # Store packages (wildcards allowed)
   Services = @('SomeService', 'PerUserSvc:T')       # ':T' = per-user service template
   Tasks = @('\Microsoft\Windows\Folder\|TaskName')  # path|name
   Caps = @('Some.Capability*')                      # Windows capabilities
   Reg = @( (Row 'HKLM' 'SOFTWARE\...' 'Name' 1) ) }
```

**Coding rules**

- **ASCII only.** Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI; curly quotes would break parsing.
- PowerShell 5.1 syntax only (no ternary, no `?.`, no `-AsHashtable`).
- Every native executable goes through `Invoke-Native`; never let stderr trigger `$ErrorActionPreference = 'Stop'`.
- Anything that deletes goes through `Remove-PathForce` (protected-path guard, no symlink following).
- Mark an item `-Soft` only when Windows can legitimately refuse or revert it.

**Test recipe**

1. Make a VM snapshot (or use a spare PC).
2. `-DryRun -Defaults`, then a real run, then reboot.
3. `-VerifyOnly` must report no `FAIL`.
4. `-Restore`, reboot, `-VerifyOnly` must now report the changes as reverted.
5. Optional: `Invoke-ScriptAnalyzer -Path .\Win11-DeepDebloat.ps1` (`Write-Host` findings are intentional - the script is interactive).

**Ideas / roadmap**

- Per-app Office removal through the Office Deployment Tool (needs a download, so deliberately out of scope for v1).
- Export of a DNS blocklist built from Microsoft's documented diagnostic endpoints.
- Pester tests for the planner and the verifiers.
- Optional, opt-in scheduled `-VerifyOnly` reminder.

## Security and auditability

- The script makes **no network connections of its own**, downloads nothing and sends nothing anywhere.
- External programs it can start: `reg.exe`, `takeown.exe`, `icacls.exe`, `schtasks.exe`, `logman.exe`, `dism.exe`, `powercfg.exe`, `msiexec.exe`, `powershell.exe` (self-elevation), and the vendors' own uninstallers for Edge, OneDrive, Office and the Teams installer when you choose to remove them.
- It is plain ASCII text without obfuscation. Review it before running, as with any script that needs administrator rights.
- Changes are written to a local log, `baseline.json` and the JSON/CSV report so you can audit exactly what happened.

## Changelog

### 1.0.0

- Initial release: task engine with per-task verification, baseline and `-Restore`, `-DryRun`, `-VerifyOnly`, saved choices (`-Config`), per-user registry handling for every profile and the Default profile, 40 optional catalog items plus promo/OEM detection, ETW AutoLogger neutralisation, firewall blocks for telemetry binaries, Defender sample-sharing off, Recall / Click to Do / Copilot policies, file clean-up with before/after verification, JSON/CSV reports.

## License

MIT - `LICENSE'The software is provided "as is", without warranty of any kind; you are responsible for what you run on your own systems.

## References

- Microsoft Learn - [Configure Windows diagnostic data in your organization](https://learn.microsoft.com/en-us/windows/privacy/configure-windows-diagnostic-data-in-your-organization) (diagnostic-data levels, "Off" limited to Enterprise/Education/Server, diagnostic endpoints)
- Microsoft Learn - [Manage connections from Windows operating system components to Microsoft services](https://learn.microsoft.com/en-us/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services) (settings, policies and the Windows Restricted Traffic Limited Functionality Baseline)
- Microsoft Learn - [Windows 11 connection endpoints](https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints)
- ERNW / Insinuator - [Windows Insight: the Windows telemetry ETW monitor](https://insinuator.net/2020/01/windows-insight-the-windows-telemetry-etw-monitor/) and the [Windows-Insight repository](https://github.com/ernw/Windows-Insight) (how telemetry events flow through ETW sessions to the DiagTrack service)
- Windows Latest - [Windows 10 Defender flags hosts-file telemetry blocking](https://windowslatest.com/2020/09/07/windows-10-defender-flags-hosts-file-telemetry-blocking) (why this tool does not edit the hosts file)
