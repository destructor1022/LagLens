[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$monitorPath = Join-Path $root 'LagLensBackground.ps1'
$markerPath = Join-Path $root 'Mark Lag Now.ps1'
$reportsPath = Join-Path $root 'Reports'
$stopRequest = Join-Path $root 'stop-background-monitor.request'
$startupFolder = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupFolder 'LagLens Background Monitor.lnk'
$desktopFolder = [Environment]::GetFolderPath('Desktop')
$markerShortcutPath = Join-Path $desktopFolder 'Mark Lag Now.lnk'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskName = 'LagLens Background Monitor'
$mutexName = 'Local\LagLensBackgroundMonitor'

if (-not (Test-Path $reportsPath)) { New-Item -ItemType Directory -Path $reportsPath -Force | Out-Null }

function Get-TaskSchedulerRoot {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    return [pscustomobject]@{
        Service = $service
        Root = $service.GetFolder('\')
    }
}

function Get-LagLensScheduledTask {
    try {
        $scheduler = Get-TaskSchedulerRoot
        return $scheduler.Root.GetTask($taskName)
    }
    catch {
        return $null
    }
}

function Test-LagLensMonitorRunning {
    $createdNew = $false
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
        if ($createdNew) {
            try { $mutex.ReleaseMutex() } catch { }
            return $false
        }
        return $true
    }
    catch {
        return $true
    }
    finally {
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Remove-LagLensScheduledTask {
    try { $scheduler = Get-TaskSchedulerRoot } catch { return $false }
    $task = $null
    try { $task = $scheduler.Root.GetTask($taskName) } catch { return $false }

    # A cooperative stop is attempted before this function. If it did not
    # finish, stop the registered instance so removal cannot race a restart.
    try {
        if ($task.State -eq 4) { $task.Stop(0) }
    }
    catch { }
    try {
        $scheduler.Root.DeleteTask($taskName, 0)
        return $true
    }
    catch {
        throw "Could not remove the LagLens scheduled task: $($_.Exception.Message)"
    }
}

function Install-LagLensScheduledTask {
    $scheduler = Get-TaskSchedulerRoot
    $definition = $scheduler.Service.NewTask(0)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $definition.RegistrationInfo.Description = 'LagLens low-overhead responsiveness and battery recorder'
    $definition.RegistrationInfo.Author = $identity
    $definition.Principal.UserId = $identity
    $definition.Principal.LogonType = 3 # TASK_LOGON_INTERACTIVE_TOKEN
    $definition.Principal.RunLevel = 0  # TASK_RUNLEVEL_LUA (standard user)

    $settings = $definition.Settings
    $settings.Enabled = $true
    $settings.StartWhenAvailable = $true
    $settings.DisallowStartIfOnBatteries = $false
    $settings.StopIfGoingOnBatteries = $false
    $settings.ExecutionTimeLimit = 'PT0S'
    $settings.RestartCount = 5
    $settings.RestartInterval = 'PT1M'
    $settings.MultipleInstances = 2 # TASK_INSTANCES_IGNORE_NEW

    $logonTrigger = $definition.Triggers.Create(9) # TASK_TRIGGER_LOGON
    $logonTrigger.Id = 'Logon'
    $logonTrigger.UserId = $identity
    $logonTrigger.Enabled = $true

    # Resume collection after the laptop is unlocked without waiting for a
    # fresh sign-in. The mutex prevents a duplicate instance.
    try {
        $unlockTrigger = $definition.Triggers.Create(11) # TASK_TRIGGER_SESSION_STATE_CHANGE
        $unlockTrigger.Id = 'Unlock'
        $unlockTrigger.UserId = $identity
        $unlockTrigger.StateChange = 8 # TASK_SESSION_UNLOCK
        $unlockTrigger.Enabled = $true
    }
    catch { }

    $action = $definition.Actions.Create(0) # TASK_ACTION_EXEC
    $action.Path = $powershellPath
    $action.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $monitorPath
    $action.WorkingDirectory = $root

    [void]$scheduler.Root.RegisterTaskDefinition($taskName, $definition, 6, $null, $null, 3, $null)
    return $scheduler.Root.GetTask($taskName)
}

function Install-StartupShortcutFallback {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $monitorPath
    $shortcut.WorkingDirectory = $root
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'LagLens low-overhead Windows slowdown recorder'
    $shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\perfmon.exe') + ',0'
    $shortcut.Save()
}

function Start-DetachedInteractiveMonitor {
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $monitorPath
    try {
        # Shell.Application delegates process creation to the interactive
        # Windows shell instead of attaching the recorder to this installer.
        # That lets it survive the Codex/terminal process and keeps access to
        # the real foreground desktop for app-response measurements.
        $shellApplication = New-Object -ComObject Shell.Application
        $shellApplication.ShellExecute($powershellPath, $arguments, $root, 'open', 0)
        return 'interactive Windows shell'
    }
    catch {
        Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        return 'direct fallback launcher'
    }
}

if ($Remove) {
    if (-not (Test-Path $stopRequest)) {
        Set-Content -Path $stopRequest -Value (Get-Date).ToString('o') -Encoding ASCII
    }

    $deadline = (Get-Date).AddSeconds(20)
    while ((Test-LagLensMonitorRunning) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
    }

    $taskRemoved = Remove-LagLensScheduledTask
    if (Test-Path $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
    if (Test-Path $markerShortcutPath) { Remove-Item -LiteralPath $markerShortcutPath -Force }
    if (Test-Path $stopRequest) { Remove-Item -LiteralPath $stopRequest -Force -ErrorAction SilentlyContinue }

    Write-Host 'LagLens startup monitoring has been disabled.' -ForegroundColor Yellow
    if ($taskRemoved) { Write-Host "Removed scheduled task: $taskName" }
    Write-Host 'The background recorder is no longer scheduled to restart.'
    exit 0
}

if (-not (Test-Path $monitorPath)) { throw "Background monitor not found: $monitorPath" }
if (Test-Path $stopRequest) { Remove-Item -LiteralPath $stopRequest -Force }

$scheduledTask = $null
$taskFailure = $null
try {
    $scheduledTask = Install-LagLensScheduledTask
    if (Test-Path $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
}
catch {
    $taskFailure = $_.Exception.Message
    Install-StartupShortcutFallback
}

if (-not (Test-Path $markerPath)) { throw "Lag marker not found: $markerPath" }
$shell = New-Object -ComObject WScript.Shell
$markerShortcut = $shell.CreateShortcut($markerShortcutPath)
$markerShortcut.TargetPath = $powershellPath
$markerShortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $markerPath
$markerShortcut.WorkingDirectory = $root
$markerShortcut.WindowStyle = 7
$markerShortcut.Description = 'Mark a slow app or Windows moment for LagLens'
$markerShortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\perfmon.exe') + ',0'
$markerShortcut.Hotkey = 'CTRL+ALT+L'
$markerShortcut.Save()

if ($null -ne $scheduledTask) {
    Write-Host 'LagLens is registered as a self-restarting Windows scheduled task.' -ForegroundColor Green
    Write-Host "Scheduled task: $taskName (at sign-in and unlock)"
}
else {
    Write-Host 'Windows did not allow scheduled-task registration; the Startup shortcut fallback was installed.' -ForegroundColor Yellow
    Write-Host "Reason: $taskFailure"
    Write-Host "Startup shortcut: $shortcutPath"
}
Write-Host "Lag marker shortcut: $markerShortcutPath (Ctrl+Alt+L)"
Write-Host 'It records system data every 15 seconds, interactive UI timing every second on AC (every two seconds on battery), and keeps 30 days.'

if ($StartNow) {
    if ($null -ne $scheduledTask) {
        [void]$scheduledTask.Run($null)
        Write-Host 'Background monitoring was started by Task Scheduler.' -ForegroundColor Green
    }
    else {
        $launcher = Start-DetachedInteractiveMonitor
        Write-Host "Background monitoring was started through the $launcher." -ForegroundColor Green
    }
}
