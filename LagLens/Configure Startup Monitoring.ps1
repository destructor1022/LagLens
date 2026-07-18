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

if (-not (Test-Path $reportsPath)) { New-Item -ItemType Directory -Path $reportsPath -Force | Out-Null }

if ($Remove) {
    if (Test-Path $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
    if (Test-Path $markerShortcutPath) { Remove-Item -LiteralPath $markerShortcutPath -Force }
    Set-Content -Path $stopRequest -Value (Get-Date).ToString('o') -Encoding ASCII
    Write-Host 'LagLens startup monitoring has been disabled.' -ForegroundColor Yellow
    Write-Host 'Any active background recorder will stop within about 10 seconds.'
    exit 0
}

if (-not (Test-Path $monitorPath)) { throw "Background monitor not found: $monitorPath" }
if (Test-Path $stopRequest) { Remove-Item -LiteralPath $stopRequest -Force }

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $monitorPath
$shortcut.WorkingDirectory = $root
$shortcut.WindowStyle = 7
$shortcut.Description = 'LagLens low-overhead Windows slowdown recorder'
$shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\perfmon.exe') + ',0'
$shortcut.Save()

if (-not (Test-Path $markerPath)) { throw "Lag marker not found: $markerPath" }
$markerShortcut = $shell.CreateShortcut($markerShortcutPath)
$markerShortcut.TargetPath = $powershellPath
$markerShortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $markerPath
$markerShortcut.WorkingDirectory = $root
$markerShortcut.WindowStyle = 7
$markerShortcut.Description = 'Mark a slow app or Windows moment for LagLens'
$markerShortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\perfmon.exe') + ',0'
$markerShortcut.Hotkey = 'CTRL+ALT+L'
$markerShortcut.Save()

Write-Host 'LagLens will now start quietly whenever you sign in.' -ForegroundColor Green
Write-Host "Startup shortcut: $shortcutPath"
Write-Host "Lag marker shortcut: $markerShortcutPath (Ctrl+Alt+L)"
Write-Host 'It samples every 15 seconds, creates a report every two hours, and keeps 30 days.'

if ($StartNow) {
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $monitorPath
    Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    Write-Host 'Background monitoring was also started now.' -ForegroundColor Green
}
