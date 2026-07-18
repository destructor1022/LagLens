[CmdletBinding()]
param(
    [ValidateRange(15, 1440)]
    [int]$SessionMinutes = 120,

    [ValidateRange(5, 60)]
    [int]$IntervalSeconds = 15,

    [ValidateRange(500, 5000)]
    [int]$UiIntervalMilliseconds = 1000,

    [ValidateRange(1, 30)]
    [int]$RetentionDays = 30
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$recorder = Join-Path $root 'LagLens.ps1'
$uiRecorder = Join-Path $root 'LagLensUiBurst.ps1'
$reports = Join-Path $root 'Reports'
$stopRequest = Join-Path $root 'stop-background-monitor.request'
$statusPath = Join-Path $reports 'LagLens-background-status.txt'
$errorPath = Join-Path $reports 'LagLens-background-errors.log'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path $reports)) { New-Item -ItemType Directory -Path $reports -Force | Out-Null }
if (Test-Path $stopRequest) { Remove-Item -LiteralPath $stopRequest -Force -ErrorAction SilentlyContinue }

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\LagLensBackgroundMonitor', [ref]$createdNew)
if (-not $createdNew) {
    Add-Content -Path $statusPath -Value ("{0:o} A second startup monitor was prevented from running." -f (Get-Date)) -Encoding UTF8
    $mutex.Dispose()
    exit 0
}

function Write-MonitorStatus([string]$Text) {
    $line = "{0:o} {1}" -f (Get-Date), $Text
    Set-Content -Path $statusPath -Value @(
        'LagLens background monitor'
        "Process ID: $PID"
        "Session length: $SessionMinutes minutes"
        "System sampling interval: $IntervalSeconds seconds"
        "Interactive UI interval: $UiIntervalMilliseconds ms on AC; at least 2000 ms on battery"
        "Retention: $RetentionDays days"
        "Last status: $line"
    ) -Encoding UTF8
}

function Write-MonitorError([string]$Text) {
    Add-Content -Path $errorPath -Value ("{0:o} {1}" -f (Get-Date), $Text) -Encoding UTF8
}

function Start-HiddenPowerShell([string]$Arguments) {
    $process = Start-Process -FilePath $powershellPath -ArgumentList $Arguments -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
    if ($null -eq $process) { throw 'PowerShell child process could not be started.' }
    return $process
}

function Stop-ChildProcess($Process) {
    if ($null -eq $Process) { return }
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
    }
    catch { }
    try { $Process.Dispose() } catch { }
}

$exitCode = 0
$stoppedByRequest = $false
try {
    if (-not (Test-Path $recorder)) { throw "Recorder not found: $recorder" }
    if (-not (Test-Path $uiRecorder)) { throw "UI recorder not found: $uiRecorder" }

    Write-MonitorStatus 'Started. Waiting to begin the first recording session.'
    while ($true) {
        if (Test-Path $stopRequest) {
            $stoppedByRequest = $true
            break
        }

        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -LiteralPath $reports -File -Filter 'LagLens-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'LagLens-background-status.txt' -and $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

        Write-MonitorStatus 'Recording is active: system resources plus continuous interactive UI timing.'
        $mainArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DurationMinutes {1} -IntervalSeconds {2} -OutputDirectory "{3}" -NoOpen -Quiet' -f $recorder, $SessionMinutes, $IntervalSeconds, $reports
        $uiDurationSeconds = [Math]::Min(86400, ($SessionMinutes * 60) + 30)
        $uiArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DurationSeconds {1} -IntervalMilliseconds {2} -CaptureMode Continuous -OutputDirectory "{3}"' -f $uiRecorder, $uiDurationSeconds, $UiIntervalMilliseconds, $reports

        $mainChild = $null
        $uiChild = $null
        try {
            $mainChild = Start-HiddenPowerShell $mainArguments
            $uiChild = Start-HiddenPowerShell $uiArguments
            $uiRestartCount = 0
            $sessionDeadline = (Get-Date).AddMinutes($SessionMinutes).AddSeconds(45)

            while (-not $mainChild.HasExited) {
                if (Test-Path $stopRequest) {
                    $stoppedByRequest = $true
                    Stop-ChildProcess $uiChild
                    Stop-ChildProcess $mainChild
                    break
                }

                # The system recorder is the authoritative session clock. If
                # the lightweight UI sensor exits early, restart it up to three
                # times and record the event instead of silently losing detail.
                try { $uiChild.Refresh() } catch { }
                if ($uiChild.HasExited -and $uiRestartCount -lt 3 -and (Get-Date) -lt $sessionDeadline) {
                    $uiExitCode = $uiChild.ExitCode
                    Write-MonitorError "Continuous UI recorder exited early with code $uiExitCode; restarting."
                    try { $uiChild.Dispose() } catch { }
                    $remainingSeconds = [Math]::Max(30, [Math]::Min(86400, [int][Math]::Ceiling(($sessionDeadline - (Get-Date)).TotalSeconds)))
                    $uiArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DurationSeconds {1} -IntervalMilliseconds {2} -CaptureMode Continuous -OutputDirectory "{3}"' -f $uiRecorder, $remainingSeconds, $UiIntervalMilliseconds, $reports
                    $uiChild = Start-HiddenPowerShell $uiArguments
                    $uiRestartCount++
                }

                Start-Sleep -Seconds 5
                try { $mainChild.Refresh() } catch { break }
            }

            if (-not $stoppedByRequest) {
                try {
                    $mainExitCode = $mainChild.ExitCode
                    if ($mainExitCode -ne 0) { Write-MonitorError "System recorder exited with code $mainExitCode." }
                }
                catch { }
            }
        }
        finally {
            Stop-ChildProcess $uiChild
            Stop-ChildProcess $mainChild
        }

        if ($stoppedByRequest -or (Test-Path $stopRequest)) {
            $stoppedByRequest = $true
            break
        }
        Write-MonitorStatus 'A recording session finished; the next session starts in 30 seconds.'
        Start-Sleep -Seconds 30
    }
}
catch {
    $exitCode = 1
    $message = "Background monitor failure: $($_.Exception.Message)"
    Write-MonitorError $message
    Write-MonitorStatus "$message Task Scheduler will retry it."
}
finally {
    if ($stoppedByRequest) {
        Write-MonitorStatus 'Stopped by request. Startup monitoring is not currently active.'
    }
    elseif ($exitCode -eq 0) {
        Write-MonitorStatus 'Stopped. Startup monitoring is not currently active.'
    }
    if (Test-Path $stopRequest) { Remove-Item -LiteralPath $stopRequest -Force -ErrorAction SilentlyContinue }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}

exit $exitCode
