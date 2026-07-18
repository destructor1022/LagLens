$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$reports = Join-Path $root 'Reports'
$requestPath = Join-Path $root 'lag-marker.request'
$markerLog = Join-Path $reports 'LagMarkers.csv'
$uiBurstPath = Join-Path $root 'LagLensUiBurst.ps1'
if (-not (Test-Path $reports)) { New-Item -ItemType Directory -Path $reports -Force | Out-Null }

if (-not ('LagLensMarker.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace LagLensMarker
{
    public static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr windowHandle, out uint processId);
    }
}
'@
}

$foregroundProcess = ''
try {
    $handle = [LagLensMarker.NativeMethods]::GetForegroundWindow()
    $processId = [uint32]0
    [void][LagLensMarker.NativeMethods]::GetWindowThreadProcessId($handle, [ref]$processId)
    $foregroundProcess = (Get-Process -Id $processId -ErrorAction Stop).ProcessName
}
catch { }

$powerSource = 'Unknown'
$batteryPercent = -1.0
try {
    Add-Type -AssemblyName System.Windows.Forms
    $power = [System.Windows.Forms.SystemInformation]::PowerStatus
    $powerSource = switch ([string]$power.PowerLineStatus) { 'Online' { 'AC' } 'Offline' { 'Battery' } default { 'Unknown' } }
    if ($power.BatteryLifePercent -ge 0) { $batteryPercent = [Math]::Round([double]$power.BatteryLifePercent * 100, 1) }
}
catch { }

$timestamp = (Get-Date).ToString('o')
$marker = [pscustomobject]@{
    Timestamp = $timestamp
    ForegroundProcess = $foregroundProcess
    PowerSource = $powerSource
    BatteryChargePct = $batteryPercent
}

if (Test-Path $markerLog) { $marker | Export-Csv -Path $markerLog -Append -NoTypeInformation -Encoding UTF8 }
else { $marker | Export-Csv -Path $markerLog -NoTypeInformation -Encoding UTF8 }
Set-Content -Path $requestPath -Value $timestamp -Encoding ASCII

try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }

# This companion is launched by the interactive desktop shortcut so it can see
# the foreground app even when the long-running background recorder cannot.
if (Test-Path $uiBurstPath) {
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -MarkerTimestamp "{1}"' -f $uiBurstPath, $timestamp
    Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}
