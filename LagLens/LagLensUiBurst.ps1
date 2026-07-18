[CmdletBinding()]
param(
    [ValidateRange(3, 86400)]
    [int]$DurationSeconds = 120,

    [ValidateRange(250, 5000)]
    [int]$IntervalMilliseconds = 1000,

    [string]$MarkerTimestamp = '',

    [ValidateSet('Marker', 'Continuous')]
    [string]$CaptureMode = 'Marker',

    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$reports = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { Join-Path $root 'Reports' } else { $OutputDirectory }
if (-not (Test-Path $reports)) { New-Item -ItemType Directory -Path $reports -Force | Out-Null }

if (-not ('LagLensUiBurst.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace LagLensUiBurst
{
    [StructLayout(LayoutKind.Sequential)]
    public struct UNSIGNED_RATIO
    {
        public uint uiNumerator;
        public uint uiDenominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DWM_TIMING_INFO
    {
        public uint cbSize;
        public UNSIGNED_RATIO rateRefresh;
        public ulong qpcRefreshPeriod;
        public UNSIGNED_RATIO rateCompose;
        public ulong qpcVBlank;
        public ulong cRefresh;
        public uint cDXRefresh;
        public ulong qpcCompose;
        public ulong cFrame;
        public uint cDXPresent;
        public ulong cRefreshFrame;
        public ulong cFrameSubmitted;
        public uint cDXPresentSubmitted;
        public ulong cFrameConfirmed;
        public uint cDXPresentConfirmed;
        public ulong cRefreshConfirmed;
        public uint cDXRefreshConfirmed;
        public ulong cFramesLate;
        public uint cFramesOutstanding;
        public ulong cFrameDisplayed;
        public ulong qpcFrameDisplayed;
        public ulong cRefreshFrameDisplayed;
        public ulong cFrameComplete;
        public ulong qpcFrameComplete;
        public ulong cFramePending;
        public ulong qpcFramePending;
        public ulong cFramesDisplayed;
        public ulong cFramesComplete;
        public ulong cFramesPending;
        public ulong cFramesAvailable;
        public ulong cFramesDropped;
        public ulong cFramesMissed;
        public ulong cRefreshNextDisplayed;
        public ulong cRefreshNextPresented;
        public ulong cRefreshesDisplayed;
        public ulong cRefreshesPresented;
        public ulong cRefreshStarted;
        public ulong cPixelsReceived;
        public ulong cPixelsDrawn;
        public ulong cBuffersEmpty;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    public static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr windowHandle, out uint processId);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr windowHandle, uint message, UIntPtr wParam, IntPtr lParam, uint flags, uint timeoutMilliseconds, out UIntPtr result);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

        [DllImport("kernel32.dll")]
        public static extern ulong GetTickCount64();

        public static ulong ReadLastInputMilliseconds(out uint inputTick)
        {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            inputTick = 0;
            if (!GetLastInputInfo(ref info)) return ulong.MaxValue;
            inputTick = info.dwTime;
            uint nowLow = unchecked((uint)GetTickCount64());
            return unchecked((uint)(nowLow - info.dwTime));
        }

        [DllImport("dwmapi.dll", PreserveSig = true)]
        public static extern int DwmGetCompositionTimingInfo(IntPtr windowHandle, ref DWM_TIMING_INFO timingInfo);
    }
}
'@
}

function New-Counter([string]$Category, [string]$Counter, [string]$Instance) {
    try {
        if ([string]::IsNullOrWhiteSpace($Instance)) {
            $pc = New-Object System.Diagnostics.PerformanceCounter -ArgumentList @($Category, $Counter, $true)
        }
        else {
            $pc = New-Object System.Diagnostics.PerformanceCounter -ArgumentList @($Category, $Counter, $Instance, $true)
        }
        [void]$pc.NextValue()
        return $pc
    }
    catch { return $null }
}

function Read-Counter($Counter) {
    if ($null -eq $Counter) { return 0.0 }
    try { return [double]$Counter.NextValue() } catch { return 0.0 }
}

function Get-ForegroundSample {
    $handle = [LagLensUiBurst.NativeMethods]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) {
        return [pscustomobject]@{ Process = ''; ProcessId = 0; ResponseMs = 0.0; Hung = $false; Responding = $true; WorkingSetMB = 0.0; PrivateMemoryMB = 0.0; ThreadCount = 0; HandleCount = 0; CpuSeconds = 0.0 }
    }

    $processId = [uint32]0
    [void][LagLensUiBurst.NativeMethods]::GetWindowThreadProcessId($handle, [ref]$processId)
    $name = ''
    $workingSetMB = 0.0
    $privateMemoryMB = 0.0
    $threadCount = 0
    $handleCount = 0
    $responding = $true
    $cpuSeconds = 0.0
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        $name = $process.ProcessName
        $workingSetMB = [double]$process.WorkingSet64 / 1MB
        $privateMemoryMB = [double]$process.PrivateMemorySize64 / 1MB
        $threadCount = @($process.Threads).Count
        $handleCount = [int]$process.HandleCount
        $responding = [bool]$process.Responding
        if ($null -ne $process.CPU) { $cpuSeconds = [double]$process.CPU }
    }
    catch { }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $messageResult = [UIntPtr]::Zero
    $result = [LagLensUiBurst.NativeMethods]::SendMessageTimeout($handle, 0, [UIntPtr]::Zero, [IntPtr]::Zero, 3, 250, [ref]$messageResult)
    $stopwatch.Stop()
    return [pscustomobject]@{
        Process = $name
        ProcessId = $processId
        ResponseMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
        Hung = ($result -eq [IntPtr]::Zero)
        Responding = $responding
        WorkingSetMB = $workingSetMB
        PrivateMemoryMB = $privateMemoryMB
        ThreadCount = $threadCount
        HandleCount = $handleCount
        CpuSeconds = $cpuSeconds
    }
}

function Get-DwmSample {
    try {
        $info = New-Object LagLensUiBurst.DWM_TIMING_INFO
        $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][LagLensUiBurst.DWM_TIMING_INFO])
        if ([LagLensUiBurst.NativeMethods]::DwmGetCompositionTimingInfo([IntPtr]::Zero, [ref]$info) -eq 0) {
            $refreshHz = 0.0
            if ($info.rateRefresh.uiDenominator -gt 0) { $refreshHz = [double]$info.rateRefresh.uiNumerator / [double]$info.rateRefresh.uiDenominator }
            return [pscustomobject]@{ Available = $true; RefreshHz = $refreshHz; Displayed = [double]$info.cFramesDisplayed; Dropped = [double]$info.cFramesDropped; Missed = [double]$info.cFramesMissed; Refreshes = [double]$info.cRefreshesDisplayed }
        }
    }
    catch { }
    return [pscustomobject]@{ Available = $false; RefreshHz = 0.0; Displayed = 0.0; Dropped = 0.0; Missed = 0.0; Refreshes = 0.0 }
}

function Get-InputSample {
    $tick = [uint32]0
    $elapsed = [LagLensUiBurst.NativeMethods]::ReadLastInputMilliseconds([ref]$tick)
    if ($elapsed -eq [uint64]::MaxValue) { return [pscustomobject]@{ Tick = 0; MillisecondsAgo = -1 } }
    return [pscustomobject]@{ Tick = $tick; MillisecondsAgo = [Math]::Min([double]$elapsed, [double][int]::MaxValue) }
}

$cpuCounter = New-Counter 'Processor' '% Processor Time' '_Total'
$utilityCounter = New-Counter 'Processor Information' '% Processor Utility' '_Total'
$frequencyCounter = New-Counter 'Processor Information' 'Actual Frequency' '_Total'
$queueCounter = New-Counter 'System' 'Processor Queue Length' ''
$contextSwitchCounter = New-Counter 'System' 'Context Switches/sec' ''
$dpcCounter = New-Counter 'Processor' '% DPC Time' '_Total'
$interruptCounter = New-Counter 'Processor' '% Interrupt Time' '_Total'
$pageReadCounter = New-Counter 'Memory' 'Page Reads/sec' ''
$diskLatencyCounter = New-Counter 'PhysicalDisk' 'Avg. Disk sec/Transfer' '_Total'
$logicalProcessors = [Math]::Max(1, [Environment]::ProcessorCount)
$processCpu = @{}
$start = Get-Date
$previousTime = $start
$previousDwm = Get-DwmSample
$previousInput = Get-InputSample
$stamp = $start.ToString('yyyyMMdd-HHmmssfff')
$outputSuffix = if ($CaptureMode -eq 'Continuous') { 'ui-continuous' } else { 'ui-burst' }
$outputPath = Join-Path $reports "LagLens-$stamp-$outputSuffix.csv"
$nextIntervalMilliseconds = $IntervalMilliseconds
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }

while (((Get-Date) - $start).TotalSeconds -lt $DurationSeconds) {
    $sleepIntervalMilliseconds = $nextIntervalMilliseconds
    Start-Sleep -Milliseconds $sleepIntervalMilliseconds
    $now = Get-Date
    $intervalSeconds = [Math]::Max(0.1, ($now - $previousTime).TotalSeconds)
    $sampleIntervalMilliseconds = $intervalSeconds * 1000.0
    $recorderDelayMilliseconds = [Math]::Max(0.0, $sampleIntervalMilliseconds - $sleepIntervalMilliseconds)
    $foreground = Get-ForegroundSample
    $dwm = Get-DwmSample
    $input = Get-InputSample

    $foregroundCpuPct = 0.0
    if ($foreground.ProcessId -gt 0 -and $foreground.CpuSeconds -ge 0) {
        $key = [int]$foreground.ProcessId
        if ($processCpu.ContainsKey($key)) {
            $prior = $processCpu[$key]
            $seconds = [Math]::Max(0.1, ($now - $prior.Time).TotalSeconds)
            if ($foreground.CpuSeconds -ge $prior.CpuSeconds) {
                $foregroundCpuPct = (($foreground.CpuSeconds - $prior.CpuSeconds) / $seconds / $logicalProcessors) * 100.0
            }
        }
        $processCpu[$key] = [pscustomobject]@{ CpuSeconds = $foreground.CpuSeconds; Time = $now }
    }

    $dwmMissed = 0.0
    $dwmDropped = 0.0
    $dwmComposedFps = 0.0
    $dwmRefreshFps = 0.0
    if ($dwm.Available -and $previousDwm.Available) {
        if ($dwm.Missed -ge $previousDwm.Missed) { $dwmMissed = $dwm.Missed - $previousDwm.Missed }
        if ($dwm.Dropped -ge $previousDwm.Dropped) { $dwmDropped = $dwm.Dropped - $previousDwm.Dropped }
        if ($dwm.Displayed -ge $previousDwm.Displayed) { $dwmComposedFps = ($dwm.Displayed - $previousDwm.Displayed) / $intervalSeconds }
        if ($dwm.Refreshes -ge $previousDwm.Refreshes) { $dwmRefreshFps = ($dwm.Refreshes - $previousDwm.Refreshes) / $intervalSeconds }
    }

    $powerSource = 'Unknown'
    $batteryPercent = -1.0
    try {
        $power = [System.Windows.Forms.SystemInformation]::PowerStatus
        $powerSource = switch ([string]$power.PowerLineStatus) { 'Online' { 'AC' } 'Offline' { 'Battery' } default { 'Unknown' } }
        if ($power.BatteryLifePercent -ge 0) { $batteryPercent = [Math]::Round([double]$power.BatteryLifePercent * 100, 1) }
    }
    catch { }

    $nextIntervalMilliseconds = if ($CaptureMode -eq 'Continuous' -and $powerSource -eq 'Battery') {
        [Math]::Max(2000, $IntervalMilliseconds)
    }
    else {
        $IntervalMilliseconds
    }

    $inputOccurred = ($input.Tick -ne $previousInput.Tick)
    $cpuPct = [Math]::Max(0, [Math]::Min(100, (Read-Counter $cpuCounter)))
    $cpuUtilityPct = [Math]::Max(0, (Read-Counter $utilityCounter))
    $frequencyMHz = [Math]::Max(0, (Read-Counter $frequencyCounter))
    $queueLength = [Math]::Max(0, (Read-Counter $queueCounter))
    $contextSwitches = [Math]::Max(0, (Read-Counter $contextSwitchCounter))
    $dpcPct = [Math]::Max(0, (Read-Counter $dpcCounter))
    $interruptPct = [Math]::Max(0, (Read-Counter $interruptCounter))
    $pageReads = [Math]::Max(0, (Read-Counter $pageReadCounter))
    $diskLatencyMs = [Math]::Max(0, (Read-Counter $diskLatencyCounter) * 1000.0)

    $stallReasons = New-Object System.Collections.Generic.List[string]
    if ($foreground.Hung -or -not $foreground.Responding) { $stallReasons.Add('ForegroundHung') }
    elseif ($foreground.ResponseMs -ge 100) { $stallReasons.Add('ForegroundResponse100ms') }
    if ($recorderDelayMilliseconds -ge 750) { $stallReasons.Add('RecorderSchedulingDelay750ms') }
    if ($dwmMissed -ge 2) { $stallReasons.Add('DwmMissedFrames') }
    if ($dwmDropped -ge 1) { $stallReasons.Add('DwmDroppedFrames') }
    if ($inputOccurred -and $dwm.RefreshHz -ge 50 -and $dwmRefreshFps -gt 0 -and $dwmRefreshFps -lt ($dwm.RefreshHz * 0.60)) {
        $stallReasons.Add('LowDesktopFpsDuringInput')
    }
    if ($dpcPct -ge 10) { $stallReasons.Add('DpcPressure') }
    if ($diskLatencyMs -ge 100) { $stallReasons.Add('DiskLatency100ms') }

    $row = [pscustomobject]@{
        Timestamp = $now.ToString('o')
        CaptureMode = $CaptureMode
        MarkerTimestamp = $MarkerTimestamp
        ElapsedSeconds = [Math]::Round(($now - $start).TotalSeconds, 2)
        RequestedIntervalMs = $sleepIntervalMilliseconds
        SampleIntervalMs = [Math]::Round($sampleIntervalMilliseconds, 2)
        RecorderDelayMs = [Math]::Round($recorderDelayMilliseconds, 2)
        ForegroundProcess = $foreground.Process
        ForegroundProcessId = $foreground.ProcessId
        ForegroundResponseMs = $foreground.ResponseMs
        ForegroundHung = [bool]$foreground.Hung
        ForegroundResponding = [bool]$foreground.Responding
        ForegroundCpuPct = [Math]::Round([Math]::Max(0, $foregroundCpuPct), 2)
        ForegroundWorkingSetMB = [Math]::Round([Math]::Max(0, $foreground.WorkingSetMB), 1)
        ForegroundPrivateMemoryMB = [Math]::Round([Math]::Max(0, $foreground.PrivateMemoryMB), 1)
        ForegroundThreadCount = $foreground.ThreadCount
        ForegroundHandleCount = $foreground.HandleCount
        InputOccurredSincePriorSample = $inputOccurred
        MillisecondsSinceLastInput = [Math]::Round($input.MillisecondsAgo, 0)
        CpuPct = [Math]::Round($cpuPct, 2)
        CpuUtilityPct = [Math]::Round($cpuUtilityPct, 2)
        ActualFrequencyMHz = [Math]::Round($frequencyMHz, 0)
        ProcessorQueueLength = [Math]::Round($queueLength, 2)
        ContextSwitchesPerSec = [Math]::Round($contextSwitches, 0)
        DpcTimePct = [Math]::Round($dpcPct, 2)
        InterruptTimePct = [Math]::Round($interruptPct, 2)
        PageReadsPerSec = [Math]::Round($pageReads, 2)
        DiskLatencyMs = [Math]::Round($diskLatencyMs, 2)
        DwmAvailable = [bool]$dwm.Available
        DwmConfiguredRefreshHz = [Math]::Round($dwm.RefreshHz, 2)
        DwmObservedRefreshFps = [Math]::Round($dwmRefreshFps, 2)
        DwmComposedFps = [Math]::Round($dwmComposedFps, 2)
        DwmFramesMissed = [Math]::Round($dwmMissed, 0)
        DwmFramesDropped = [Math]::Round($dwmDropped, 0)
        AutoStallDetected = ($stallReasons.Count -gt 0)
        AutoStallReasons = ($stallReasons -join ';')
        PowerSource = $powerSource
        BatteryChargePct = $batteryPercent
    }

    if (Test-Path $outputPath) { $row | Export-Csv -Path $outputPath -Append -NoTypeInformation -Encoding UTF8 }
    else { $row | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8 }

    $previousTime = $now
    $previousDwm = $dwm
    $previousInput = $input
}
