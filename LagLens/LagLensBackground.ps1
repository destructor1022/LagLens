[CmdletBinding()]
param(
    [ValidateRange(15, 1440)]
    [int]$SessionMinutes = 120,

    [ValidateRange(5, 60)]
    [int]$IntervalSeconds = 15,

    [ValidateRange(1, 30)]
    [int]$RetentionDays = 30
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$recorder = Join-Path $root 'LagLens.ps1'
$reports = Join-Path $root 'Reports'
$stopRequest = Join-Path $root 'stop-background-monitor.request'
$statusPath = Join-Path $reports 'LagLens-background-status.txt'
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
        "Sampling interval: $IntervalSeconds seconds"
        "Retention: $RetentionDays days"
        "Last status: $line"
    ) -Encoding UTF8
}

try {
    Write-MonitorStatus 'Started. Waiting to begin the first recording session.'
    while ($true) {
        if (Test-Path $stopRequest) { break }

        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -LiteralPath $reports -File -Filter 'LagLens-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'LagLens-background-status.txt' -and $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

        Write-MonitorStatus 'Recording is active.'
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DurationMinutes {1} -IntervalSeconds {2} -OutputDirectory "{3}" -NoOpen -Quiet' -f $recorder, $SessionMinutes, $IntervalSeconds, $reports
        $child = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru

        $stopWasRequested = $false
        while (-not $child.HasExited) {
            if (Test-Path $stopRequest) {
                $stopWasRequested = $true
                try { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } catch { }
                break
            }
            Start-Sleep -Seconds 10
            try { $child.Refresh() } catch { break }
        }
        try { $child.Dispose() } catch { }

        if ($stopWasRequested -or (Test-Path $stopRequest)) { break }
        Write-MonitorStatus 'A recording session finished; the next session starts in 30 seconds.'
        Start-Sleep -Seconds 30
    }
}
finally {
    Write-MonitorStatus 'Stopped. Startup monitoring is not currently active.'
    if (Test-Path $stopRequest) { Remove-Item -LiteralPath $stopRequest -Force -ErrorAction SilentlyContinue }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
