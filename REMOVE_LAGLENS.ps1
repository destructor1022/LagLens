[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$mutexName = 'Local\LagLensBackgroundMonitor'
$outputsRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$installRoot = [IO.Path]::GetFullPath((Join-Path $outputsRoot 'LagLens')).TrimEnd('\')
$startupFolder = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupFolder 'LagLens Background Monitor.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Mark Lag Now.lnk'
$stopRequest = Join-Path $installRoot 'stop-background-monitor.request'
$receiptPath = Join-Path $outputsRoot 'LagLens-removal-receipt.txt'
$taskName = 'LagLens Background Monitor'

# Safety: this remover may only delete a sibling folder named LagLens inside
# the outputs folder containing this script.
if ([IO.Path]::GetFileName($outputsRoot) -ne 'outputs') {
    throw "Safety check failed: removal script is not inside an outputs folder: $outputsRoot"
}
if ([IO.Path]::GetFileName($installRoot) -ne 'LagLens') {
    throw "Safety check failed: unexpected target name: $installRoot"
}
if ([IO.Directory]::GetParent($installRoot).FullName.TrimEnd('\') -ne $outputsRoot) {
    throw "Safety check failed: LagLens is not a direct child of $outputsRoot"
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
        # Be conservative: an inaccessible mutex may still represent a monitor.
        return $true
    }
    finally {
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Get-LagLensScheduledTask {
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        return $service.GetFolder('\').GetTask($taskName)
    }
    catch {
        return $null
    }
}

function Remove-LagLensScheduledTask {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $root = $service.GetFolder('\')
    $task = $null
    try { $task = $root.GetTask($taskName) } catch { return $false }
    try {
        if ($task.State -eq 4) { $task.Stop(0) }
    }
    catch { }
    $root.DeleteTask($taskName, 0)
    return $true
}

$monitorRunning = Test-LagLensMonitorRunning
$scheduledTaskPresent = ($null -ne (Get-LagLensScheduledTask))
$scheduledTaskWasPresent = $scheduledTaskPresent

Write-Host 'LagLens complete removal' -ForegroundColor Cyan
Write-Host "Monitor currently running: $monitorRunning"
Write-Host "Scheduled task installed: $scheduledTaskPresent ($taskName)"
Write-Host "Startup shortcut: $startupShortcut"
Write-Host "Desktop lag-marker shortcut: $desktopShortcut"
Write-Host "Installation and logs: $installRoot"
Write-Host "Removal receipt: $receiptPath"

if ($WhatIf) {
    Write-Host "`nWHAT-IF only: nothing was changed." -ForegroundColor Yellow
    exit 0
}

if (-not $Force) {
    Write-Host "`nThis permanently deletes LagLens and every collected diagnostic log." -ForegroundColor Yellow
    $answer = Read-Host 'Type REMOVE to continue'
    if ($answer -cne 'REMOVE') {
        Write-Host 'Removal cancelled. Nothing was changed.'
        exit 0
    }
}

if ($monitorRunning) {
    if (-not (Test-Path $installRoot)) {
        throw 'The background monitor appears active, but its installation folder is missing. Nothing was deleted.'
    }
    Set-Content -Path $stopRequest -Value (Get-Date).ToString('o') -Encoding ASCII
    Write-Host 'Stopping the background monitor...'
    $deadline = (Get-Date).AddSeconds(35)
    while ((Test-LagLensMonitorRunning) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
    }
    if (Test-LagLensMonitorRunning) {
        if ($scheduledTaskPresent) {
            Write-Host 'The cooperative stop timed out; stopping and unregistering the scheduled task.' -ForegroundColor Yellow
            [void](Remove-LagLensScheduledTask)
            $scheduledTaskPresent = $false
            Start-Sleep -Seconds 3
        }
        if (Test-LagLensMonitorRunning) {
            throw 'LagLens did not stop within 35 seconds. Nothing was deleted; try again after signing out and back in.'
        }
    }
}

if ($scheduledTaskPresent) {
    [void](Remove-LagLensScheduledTask)
    Write-Host 'Removed the LagLens scheduled task.'
}

if (Test-Path $stopRequest) { Remove-Item -LiteralPath $stopRequest -Force }
if (Test-Path $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut -Force
    Write-Host 'Removed the Windows Startup shortcut.'
}
if (Test-Path $desktopShortcut) {
    Remove-Item -LiteralPath $desktopShortcut -Force
    Write-Host 'Removed the Mark Lag Now desktop shortcut and hotkey.'
}

if (Test-Path $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
    Write-Host 'Removed the LagLens program and all diagnostic logs.'
}

$receipt = @(
    'LagLens removal completed successfully.'
    "Removed at: $((Get-Date).ToString('o'))"
    "Removed startup shortcut: $startupShortcut"
    "Scheduled task was present and removed: $scheduledTaskWasPresent ($taskName)"
    "Removed desktop shortcut: $desktopShortcut"
    "Removed installation and logs: $installRoot"
    'No other output folders or files were targeted.'
)
Set-Content -Path $receiptPath -Value $receipt -Encoding UTF8

Write-Host "`nLagLens was completely removed." -ForegroundColor Green
Write-Host "Receipt: $receiptPath"
