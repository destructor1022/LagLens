[CmdletBinding()]
param(
    [ValidateRange(0.1, 1440)]
    [double]$DurationMinutes = 5,

    [ValidateRange(1, 30)]
    [int]$IntervalSeconds = 2,

    [string]$OutputDirectory = '',

    [switch]$NoOpen,

    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'Continue'
$script:QuietMode = [bool]$Quiet
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Reports'
}

function Write-Section([string]$Text) {
    if (-not $script:QuietMode) { Write-Host "`n$Text" -ForegroundColor Cyan }
}

function ConvertTo-HtmlText($Value) {
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-Number($Value, [int]$Decimals = 1) {
    if ($null -eq $Value -or [double]::IsNaN([double]$Value)) { return 'n/a' }
    return ([double]$Value).ToString("N$Decimals")
}

function Get-AverageValue($Values) {
    $items = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($items.Count -eq 0) { return 0.0 }
    return [double](($items | Measure-Object -Average).Average)
}

function Get-PeakValue($Values) {
    $items = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($items.Count -eq 0) { return 0.0 }
    return [double](($items | Measure-Object -Maximum).Maximum)
}

function Get-MinValue($Values) {
    $items = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($items.Count -eq 0) { return 0.0 }
    return [double](($items | Measure-Object -Minimum).Minimum)
}

function Get-Percentile($Values, [double]$Percentile) {
    $items = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($items.Count -eq 0) { return 0.0 }
    $index = [Math]::Ceiling(($Percentile / 100.0) * $items.Count) - 1
    $index = [Math]::Max(0, [Math]::Min($items.Count - 1, $index))
    return [double]$items[$index]
}

function Get-FractionAtOrAbove($Values, [double]$Threshold) {
    $items = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($items.Count -eq 0) { return 0.0 }
    $matching = @($items | Where-Object { $_ -ge $Threshold }).Count
    return [double]$matching / [double]$items.Count
}

function New-PerformanceCounter([string]$Category, [string]$Counter, [string]$Instance) {
    try {
        if (-not [System.Diagnostics.PerformanceCounterCategory]::Exists($Category)) { return $null }
        if ([string]::IsNullOrWhiteSpace($Instance)) {
            $pc = New-Object System.Diagnostics.PerformanceCounter -ArgumentList @($Category, $Counter, $true)
        }
        else {
            $pc = New-Object System.Diagnostics.PerformanceCounter -ArgumentList @($Category, $Counter, $Instance, $true)
        }
        [void]$pc.NextValue()
        return $pc
    }
    catch {
        return $null
    }
}

function Read-PerformanceCounter($Counter) {
    if ($null -eq $Counter) { return $null }
    try { return [double]$Counter.NextValue() } catch { return $null }
}

function Add-Finding(
    [System.Collections.Generic.List[object]]$List,
    [string]$Level,
    [string]$Area,
    [string]$Title,
    [string]$Evidence,
    [string]$NextStep
) {
    $rank = switch ($Level) {
        'critical' { 4 }
        'warning'  { 3 }
        'good'     { 2 }
        default    { 1 }
    }
    $List.Add([pscustomobject]@{
        Level = $Level
        Rank = $rank
        Area = $Area
        Title = $Title
        Evidence = $Evidence
        NextStep = $NextStep
    })
}

function Get-ProcessLeaderText($Groups, [string]$Property, [int]$Count = 5) {
    if ($null -eq $Groups -or $Groups.Count -eq 0) { return '' }
    $leaders = @($Groups.GetEnumerator() |
        Where-Object { [double]$_.Value.$Property -gt 0 } |
        Sort-Object @{ Expression = { [double]$_.Value.$Property }; Descending = $true } |
        Select-Object -First $Count |
        ForEach-Object { '{0}={1:N2}' -f $_.Key, ([double]$_.Value.$Property) })
    return ($leaders -join '; ')
}

function New-Sparkline($Values, [string]$Color, [double]$FixedMaximum = 0) {
    $items = @($Values | ForEach-Object { if ($null -eq $_) { 0.0 } else { [double]$_ } })
    if ($items.Count -eq 0) { return '<div class="no-data">No counter data was available.</div>' }

    $width = 720.0
    $height = 150.0
    $maximum = if ($FixedMaximum -gt 0) { $FixedMaximum } else { [Math]::Max(1.0, (Get-PeakValue $items) * 1.1) }
    $points = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $items.Count; $i++) {
        $x = if ($items.Count -le 1) { 0 } else { ($i / [double]($items.Count - 1)) * $width }
        $clamped = [Math]::Max(0, [Math]::Min($maximum, $items[$i]))
        $y = $height - (($clamped / $maximum) * $height)
        $points.Add(('{0:N1},{1:N1}' -f $x, $y))
    }
    $joined = $points -join ' '
    return "<svg class='spark' viewBox='0 0 720 150' preserveAspectRatio='none' role='img'><line x1='0' y1='149' x2='720' y2='149' class='axis'/><polyline points='$joined' fill='none' stroke='$Color' stroke-width='4' vector-effect='non-scaling-stroke'/></svg>"
}

function Get-RecentRelevantEvents([datetime]$StartTime) {
    $result = New-Object System.Collections.Generic.List[object]
    try {
        $systemEvents = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $StartTime.AddMinutes(-1); Level = 1,2,3 } -MaxEvents 150 -ErrorAction Stop
        $relevantProviders = @('disk','Ntfs','storahci','stornvme','iaStorA','iaStorAC','Display','WHEA-Logger','Microsoft-Windows-Resource-Exhaustion-Detector','Microsoft-Windows-Kernel-Power')
        foreach ($event in $systemEvents) {
            if (($relevantProviders -contains $event.ProviderName) -or ($event.Id -in @(7, 11, 15, 41, 51, 55, 129, 153, 2004, 4101))) {
                $message = ([string]$event.Message -replace '\s+', ' ').Trim()
                if ($message.Length -gt 260) { $message = $message.Substring(0, 260) + '...' }
                $result.Add([pscustomobject]@{ Time = $event.TimeCreated; Log = 'System'; Provider = $event.ProviderName; Id = $event.Id; Message = $message })
            }
        }
    }
    catch { }

    try {
        $appEvents = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $StartTime.AddMinutes(-1); Id = 1000,1001,1002 } -MaxEvents 120 -ErrorAction Stop
        foreach ($event in $appEvents) {
            $fullMessage = ([string]$event.Message -replace '\s+', ' ').Trim()
            if ($event.Id -eq 1001 -and $fullMessage -notmatch 'LiveKernelEvent|AppCrash|AppHang|BlueScreen') { continue }
            $message = $fullMessage
            if ($message.Length -gt 260) { $message = $message.Substring(0, 260) + '...' }
            $result.Add([pscustomobject]@{ Time = $event.TimeCreated; Log = 'Application'; Provider = $event.ProviderName; Id = $event.Id; Message = $message })
        }
    }
    catch { }

    # GPU watchdogs and similar live-kernel failures can be intermittent and may
    # be processed by Reliability Monitor after the actual visible freeze.
    try {
        $historyEvents = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Windows Error Reporting'; Id = 1001; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 300 -ErrorAction Stop
        foreach ($event in $historyEvents) {
            $fullMessage = ([string]$event.Message -replace '\s+', ' ').Trim()
            if ($fullMessage -notmatch 'Event Name:\s*LiveKernelEvent') { continue }
            $message = $fullMessage
            if ($message.Length -gt 260) { $message = $message.Substring(0, 260) + '...' }
            $result.Add([pscustomobject]@{ Time = $event.TimeCreated; Log = 'Reliability history (30d)'; Provider = $event.ProviderName; Id = $event.Id; Message = $message })
        }
    }
    catch { }

    return @($result | Sort-Object Time -Descending | Group-Object { "$($_.Provider)|$($_.Id)|$($_.Time.Ticks)" } | ForEach-Object { $_.Group | Select-Object -First 1 })
}

# Native APIs provide total memory and per-process disk I/O without admin rights.
if (-not ('LagLensInterop.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace LagLensInterop
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MEMORYSTATUSEX
    {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

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

    public static class NativeMethods
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetProcessIoCounters(IntPtr processHandle, out IO_COUNTERS ioCounters);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr windowHandle, out uint processId);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr windowHandle,
            uint message,
            UIntPtr wParam,
            IntPtr lParam,
            uint flags,
            uint timeoutMilliseconds,
            out UIntPtr result);

        [DllImport("dwmapi.dll", PreserveSig = true)]
        public static extern int DwmGetCompositionTimingInfo(IntPtr windowHandle, ref DWM_TIMING_INFO timingInfo);
    }
}
'@
}

function Get-MemoryStatus {
    $status = New-Object LagLensInterop.MEMORYSTATUSEX
    if ([LagLensInterop.NativeMethods]::GlobalMemoryStatusEx($status)) {
        return [pscustomobject]@{
            TotalMB = [double]$status.ullTotalPhys / 1MB
            AvailableMB = [double]$status.ullAvailPhys / 1MB
            MemoryLoad = [double]$status.dwMemoryLoad
        }
    }
    return [pscustomobject]@{ TotalMB = 0.0; AvailableMB = 0.0; MemoryLoad = 0.0 }
}

try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }

function Get-BatteryHealthSummary {
    $summary = [ordered]@{
        Present = $false
        DesignCapacityMWh = 0.0
        FullChargeCapacityMWh = 0.0
        HealthPercent = 0.0
        CycleCount = 0
    }
    $temporaryReport = Join-Path ([IO.Path]::GetTempPath()) ("LagLens-battery-{0}.xml" -f $PID)
    try {
        & powercfg.exe /batteryreport /xml /output $temporaryReport 2>$null | Out-Null
        if (Test-Path $temporaryReport) {
            $xml = [xml](Get-Content -LiteralPath $temporaryReport -Raw -ErrorAction Stop)
            $battery = $xml.SelectSingleNode("//*[local-name()='Battery']")
            if ($null -ne $battery) {
                $designNode = $battery.SelectSingleNode("./*[local-name()='DesignCapacity']")
                $fullNode = $battery.SelectSingleNode("./*[local-name()='FullChargeCapacity']")
                $cycleNode = $battery.SelectSingleNode("./*[local-name()='CycleCount']")
                $design = if ($null -ne $designNode) { [double]$designNode.InnerText } else { 0.0 }
                $full = if ($null -ne $fullNode) { [double]$fullNode.InnerText } else { 0.0 }
                $cycles = if ($null -ne $cycleNode -and $cycleNode.InnerText -match '^\d+$') { [int]$cycleNode.InnerText } else { 0 }
                $summary.Present = $true
                $summary.DesignCapacityMWh = $design
                $summary.FullChargeCapacityMWh = $full
                $summary.CycleCount = $cycles
                if ($design -gt 0) { $summary.HealthPercent = [Math]::Round(($full / $design) * 100, 1) }
            }
        }
    }
    catch { }
    finally {
        if (Test-Path $temporaryReport) { Remove-Item -LiteralPath $temporaryReport -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]$summary
}

function Get-BatteryTelemetry {
    $powerSource = 'Unknown'
    $chargePercent = -1.0
    $remainingSeconds = -1
    $chargeFlags = ''
    try {
        $power = [System.Windows.Forms.SystemInformation]::PowerStatus
        $powerSource = switch ([string]$power.PowerLineStatus) { 'Online' { 'AC' } 'Offline' { 'Battery' } default { 'Unknown' } }
        if ($power.BatteryLifePercent -ge 0) { $chargePercent = [Math]::Round([double]$power.BatteryLifePercent * 100, 1) }
        $remainingSeconds = [int]$power.BatteryLifeRemaining
        $chargeFlags = [string]$power.BatteryChargeStatus
    }
    catch { }

    $dischargeRate = 0.0
    $chargeRate = 0.0
    $remainingCapacity = 0.0
    $voltage = 0.0
    try {
        $status = Get-WmiObject -Namespace root\wmi -Class BatteryStatus -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $status) {
            if ([double]$status.DischargeRate -ge 0 -and [double]$status.DischargeRate -lt 10000000) { $dischargeRate = [double]$status.DischargeRate }
            if ([double]$status.ChargeRate -ge 0 -and [double]$status.ChargeRate -lt 10000000) { $chargeRate = [double]$status.ChargeRate }
            if ([double]$status.RemainingCapacity -ge 0 -and [double]$status.RemainingCapacity -lt 10000000) { $remainingCapacity = [double]$status.RemainingCapacity }
            if ([double]$status.Voltage -ge 0 -and [double]$status.Voltage -lt 100000) { $voltage = [double]$status.Voltage }
            if ($status.PowerOnline -eq $true) { $powerSource = 'AC' }
            elseif ($status.Discharging -eq $true) { $powerSource = 'Battery' }
        }
    }
    catch { }

    $brightness = -1.0
    try {
        $brightnessInfo = Get-WmiObject -Namespace root\wmi -Class WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $brightnessInfo) { $brightness = [double]$brightnessInfo.CurrentBrightness }
    }
    catch { }

    $thermalC = -1.0
    try {
        $temperatures = @(Get-WmiObject -Namespace root\wmi -Class MSAcpi_ThermalZoneTemperature -ErrorAction Stop | ForEach-Object { ([double]$_.CurrentTemperature / 10.0) - 273.15 } | Where-Object { $_ -gt 0 -and $_ -lt 125 })
        if ($temperatures.Count -gt 0) { $thermalC = [Math]::Round((Get-PeakValue $temperatures), 1) }
    }
    catch { }

    return [pscustomobject]@{
        PowerSource = $powerSource
        ChargePercent = $chargePercent
        EstimatedRemainingSeconds = $remainingSeconds
        ChargeFlags = $chargeFlags
        DischargeRateMW = $dischargeRate
        ChargeRateMW = $chargeRate
        RemainingCapacityMWh = $remainingCapacity
        VoltageMV = $voltage
        BrightnessPercent = $brightness
        ThermalZoneC = $thermalC
    }
}

function Get-WifiTelemetry {
    $signal = -1.0
    $receiveRate = 0.0
    $transmitRate = 0.0
    $radioType = ''
    try {
        $lines = @(& netsh.exe wlan show interfaces 2>$null)
        foreach ($line in $lines) {
            if ($line -match '^\s*Signal\s*:\s*(\d+)\s*%') { $signal = [double]$matches[1] }
            elseif ($line -match '^\s*Receive rate[^:]*:\s*([0-9.]+)') { $receiveRate = [double]$matches[1] }
            elseif ($line -match '^\s*Transmit rate[^:]*:\s*([0-9.]+)') { $transmitRate = [double]$matches[1] }
            elseif ($line -match '^\s*Radio type\s*:\s*(.+)$') { $radioType = $matches[1].Trim() }
        }
    }
    catch { }
    return [pscustomobject]@{ SignalPercent = $signal; ReceiveLinkMbps = $receiveRate; TransmitLinkMbps = $transmitRate; RadioType = $radioType }
}

function Get-WindowResponse([IntPtr]$WindowHandle, [int]$TimeoutMilliseconds = 250) {
    if ($WindowHandle -eq [IntPtr]::Zero) { return [pscustomobject]@{ Available = $false; Hung = $false; ResponseMs = 0.0 } }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $messageResult = [UIntPtr]::Zero
    try {
        $result = [LagLensInterop.NativeMethods]::SendMessageTimeout($WindowHandle, 0, [UIntPtr]::Zero, [IntPtr]::Zero, 3, [uint32]$TimeoutMilliseconds, [ref]$messageResult)
        $stopwatch.Stop()
        return [pscustomobject]@{ Available = $true; Hung = ($result -eq [IntPtr]::Zero); ResponseMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2) }
    }
    catch {
        $stopwatch.Stop()
        return [pscustomobject]@{ Available = $false; Hung = $false; ResponseMs = 0.0 }
    }
}

function Get-ForegroundResponse {
    $handle = [LagLensInterop.NativeMethods]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { return [pscustomobject]@{ Process = ''; Available = $false; Hung = $false; ResponseMs = 0.0 } }
    $processId = [uint32]0
    [void][LagLensInterop.NativeMethods]::GetWindowThreadProcessId($handle, [ref]$processId)
    $processName = ''
    try { $processName = (Get-Process -Id $processId -ErrorAction Stop).ProcessName } catch { }
    $response = Get-WindowResponse $handle 250
    return [pscustomobject]@{ Process = $processName; Available = $response.Available; Hung = $response.Hung; ResponseMs = $response.ResponseMs }
}

function Get-VisibleWindowSurvey {
    $worstMs = 0.0
    $slowNames = New-Object System.Collections.Generic.List[string]
    $hungNames = New-Object System.Collections.Generic.List[string]
    $tested = 0
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 20)) {
        try {
            $response = Get-WindowResponse $process.MainWindowHandle 150
            if (-not $response.Available) { continue }
            $tested += 1
            if ($response.ResponseMs -gt $worstMs) { $worstMs = $response.ResponseMs }
            if ($response.Hung) { $hungNames.Add($process.ProcessName) }
            elseif ($response.ResponseMs -ge 75) { $slowNames.Add($process.ProcessName) }
        }
        catch { }
    }
    return [pscustomobject]@{
        Tested = $tested
        WorstResponseMs = [Math]::Round($worstMs, 2)
        SlowProcesses = (@($slowNames | Sort-Object -Unique) -join '; ')
        HungProcesses = (@($hungNames | Sort-Object -Unique) -join '; ')
    }
}

function Get-DwmSnapshot {
    try {
        $info = New-Object LagLensInterop.DWM_TIMING_INFO
        $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][LagLensInterop.DWM_TIMING_INFO])
        $result = [LagLensInterop.NativeMethods]::DwmGetCompositionTimingInfo([IntPtr]::Zero, [ref]$info)
        if ($result -eq 0) {
            $refreshHz = 0.0
            if ($info.rateRefresh.uiDenominator -gt 0) { $refreshHz = [double]$info.rateRefresh.uiNumerator / [double]$info.rateRefresh.uiDenominator }
            return [pscustomobject]@{ Available = $true; RefreshHz = $refreshHz; FramesDisplayed = [double]$info.cFramesDisplayed; FramesDropped = [double]$info.cFramesDropped; FramesMissed = [double]$info.cFramesMissed; RefreshesDisplayed = [double]$info.cRefreshesDisplayed }
        }
    }
    catch { }
    return [pscustomobject]@{ Available = $false; RefreshHz = 0.0; FramesDisplayed = 0.0; FramesDropped = 0.0; FramesMissed = 0.0; RefreshesDisplayed = 0.0 }
}

function Get-ProcessSnapshot {
    $snapshot = @{}
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $cpuSeconds = if ($null -eq $process.CPU) { 0.0 } else { [double]$process.CPU }
            $readBytes = 0.0
            $writeBytes = 0.0
            try {
                $io = New-Object LagLensInterop.IO_COUNTERS
                if ([LagLensInterop.NativeMethods]::GetProcessIoCounters($process.Handle, [ref]$io)) {
                    $readBytes = [double]$io.ReadTransferCount
                    $writeBytes = [double]$io.WriteTransferCount
                }
            }
            catch { }

            $snapshot[[int]$process.Id] = [pscustomobject]@{
                Id = [int]$process.Id
                Name = [string]$process.ProcessName
                CpuSeconds = $cpuSeconds
                WorkingSetMB = [double]$process.WorkingSet64 / 1MB
                ReadBytes = $readBytes
                WriteBytes = $writeBytes
            }
        }
        catch { }
    }
    return $snapshot
}

function Get-StaticSystemInfo {
    $memory = Get-MemoryStatus
    $batteryHealth = Get-BatteryHealthSummary
    $osName = [Environment]::OSVersion.VersionString
    $osBuild = [Environment]::OSVersion.Version.Build
    try {
        $windows = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $osName = "$($windows.ProductName) $($windows.DisplayVersion)"
        $osBuild = "$($windows.CurrentBuild).$($windows.UBR)"
    }
    catch { }

    $cimOs = $null
    $computer = $null
    $processor = $null
    $memoryModules = @()
    $videoControllers = @()
    try { $cimOs = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $processor = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { }
    try {
        $memoryModules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                CapacityGB = [Math]::Round([double]$_.Capacity / 1GB, 1)
                SpeedMHz = if ($_.ConfiguredClockSpeed) { [int]$_.ConfiguredClockSpeed } else { [int]$_.Speed }
                Manufacturer = ([string]$_.Manufacturer).Trim()
                PartNumber = ([string]$_.PartNumber).Trim()
            }
        })
    }
    catch { }
    try {
        $videoControllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; DriverVersion = [string]$_.DriverVersion; DriverDate = '' }
        })
    }
    catch { }
    if ($videoControllers.Count -eq 0) {
        try {
            $pnpText = (& pnputil.exe /enum-devices /class Display /drivers 2>$null | Out-String)
            $videoControllers = @([regex]::Split($pnpText, '(?m)^Instance ID:\s*') | Select-Object -Skip 1 | ForEach-Object {
                $section = $_
                $nameMatch = [regex]::Match($section, '(?m)^\s*Device Description:\s*(.+)$')
                $driverMatch = [regex]::Match($section, '(?m)^\s*Driver Version:\s*([0-9/]+)\s+([0-9.]+)')
                if ($nameMatch.Success) {
                    [pscustomobject]@{
                        Name = $nameMatch.Groups[1].Value.Trim()
                        DriverVersion = if ($driverMatch.Success) { $driverMatch.Groups[2].Value.Trim() } else { '' }
                        DriverDate = if ($driverMatch.Success) { $driverMatch.Groups[1].Value.Trim() } else { '' }
                    }
                }
            })
        }
        catch { }
    }

    $physicalDisks = @()
    try {
        $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            $disk = $_
            $reliability = $null
            try { $reliability = $disk | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
            [pscustomobject]@{
                FriendlyName = [string]$disk.FriendlyName
                MediaType = [string]$disk.MediaType
                HealthStatus = [string]$disk.HealthStatus
                SizeGB = [Math]::Round([double]$disk.Size / 1GB, 0)
                TemperatureC = if ($null -ne $reliability) { [double]$reliability.Temperature } else { -1.0 }
                WearPercent = if ($null -ne $reliability) { [double]$reliability.Wear } else { -1.0 }
                PowerOnHours = if ($null -ne $reliability) { [double]$reliability.PowerOnHours } else { -1.0 }
                ReadErrorsTotal = if ($null -ne $reliability) { [double]$reliability.ReadErrorsTotal } else { -1.0 }
                WriteErrorsTotal = if ($null -ne $reliability) { [double]$reliability.WriteErrorsTotal } else { -1.0 }
            }
        })
    }
    catch { }

    $displays = @()
    try {
        $displays = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            [pscustomobject]@{ Width = $_.Bounds.Width; Height = $_.Bounds.Height; Primary = $_.Primary }
        })
    }
    catch { }

    $systemDriveName = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd(':') } else { 'C' }
    $systemDrive = Get-PSDrive -Name $systemDriveName -ErrorAction SilentlyContinue
    $driveFreeGB = 0.0
    $driveSizeGB = 0.0
    $driveFreePercent = 0.0
    if ($null -ne $systemDrive) {
        $driveFreeGB = [double]$systemDrive.Free / 1GB
        $driveSizeGB = ([double]$systemDrive.Free + [double]$systemDrive.Used) / 1GB
        if ($driveSizeGB -gt 0) { $driveFreePercent = ($driveFreeGB / $driveSizeGB) * 100 }
    }
    if ($driveSizeGB -le 0) {
        try {
            $driveInfo = New-Object System.IO.DriveInfo -ArgumentList "$systemDriveName`:\"
            $driveFreeGB = [double]$driveInfo.AvailableFreeSpace / 1GB
            $driveSizeGB = [double]$driveInfo.TotalSize / 1GB
            if ($driveSizeGB -gt 0) { $driveFreePercent = ($driveFreeGB / $driveSizeGB) * 100 }
        }
        catch { }
    }

    $powerPlan = 'Unknown'
    try {
        $powerText = (& powercfg.exe /GETACTIVESCHEME 2>$null | Out-String).Trim()
        if ($powerText -match '\((.+)\)') { $powerPlan = $matches[1] }
    }
    catch { }

    $startupCount = 0
    foreach ($runKey in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
        try {
            $props = (Get-ItemProperty $runKey -ErrorAction Stop).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
            $startupCount += @($props).Count
        }
        catch { }
    }
    foreach ($startupFolder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if ($startupFolder -and (Test-Path $startupFolder)) {
            $startupCount += @(Get-ChildItem $startupFolder -File -ErrorAction SilentlyContinue).Count
        }
    }

    $bootTime = $null
    if ($null -ne $cimOs) { $bootTime = $cimOs.LastBootUpTime }
    $uptimeDays = if ($null -ne $bootTime) { ((Get-Date) - $bootTime).TotalDays } else { 0.0 }

    $processorName = if ($null -ne $processor) { [string]$processor.Name } else { [string]$env:PROCESSOR_IDENTIFIER }
    $manufacturer = if ($null -ne $computer) { [string]$computer.Manufacturer } else { '' }
    $model = if ($null -ne $computer) { [string]$computer.Model } else { '' }
    try {
        $bios = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($manufacturer)) { $manufacturer = [string]$bios.SystemManufacturer }
        if ([string]::IsNullOrWhiteSpace($model)) { $model = [string]$bios.SystemProductName }
    }
    catch { }
    if ($processorName -match '^Intel64 Family') {
        try { $processorName = [string](Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).ProcessorNameString } catch { }
    }

    return [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        Manufacturer = $manufacturer
        Model = $model
        OS = $osName
        OSBuild = $osBuild
        Processor = $processorName.Trim()
        LogicalProcessors = [Environment]::ProcessorCount
        TotalMemoryGB = [Math]::Round($memory.TotalMB / 1024, 1)
        MemoryModules = $memoryModules
        VideoControllers = $videoControllers
        Displays = $displays
        PhysicalDisks = $physicalDisks
        Battery = $batteryHealth
        SystemDrive = "$systemDriveName`:"
        SystemDriveFreeGB = [Math]::Round($driveFreeGB, 1)
        SystemDriveSizeGB = [Math]::Round($driveSizeGB, 1)
        SystemDriveFreePercent = [Math]::Round($driveFreePercent, 1)
        ActivePowerPlan = $powerPlan
        StartupItemCount = $startupCount
        UptimeDays = [Math]::Round($uptimeDays, 1)
    }
}

function Initialize-DiskCounters {
    $sets = New-Object System.Collections.Generic.List[object]
    try {
        $category = New-Object System.Diagnostics.PerformanceCounterCategory('PhysicalDisk')
        $instances = @($category.GetInstanceNames() | Where-Object { $_ -ne '_Total' })
        if ($instances.Count -eq 0) { $instances = @('_Total') }
        foreach ($instance in $instances) {
            $sets.Add([pscustomobject]@{
                Name = $instance
                Active = New-PerformanceCounter 'PhysicalDisk' '% Disk Time' $instance
                Queue = New-PerformanceCounter 'PhysicalDisk' 'Current Disk Queue Length' $instance
                Latency = New-PerformanceCounter 'PhysicalDisk' 'Avg. Disk sec/Transfer' $instance
                Bytes = New-PerformanceCounter 'PhysicalDisk' 'Disk Bytes/sec' $instance
            })
        }
    }
    catch { }
    return $sets
}

function Read-DiskCounters($CounterSets) {
    $active = 0.0
    $queue = 0.0
    $latency = 0.0
    $bytes = 0.0
    $busiest = 'Unavailable'
    foreach ($set in $CounterSets) {
        $thisActive = Read-PerformanceCounter $set.Active
        $thisQueue = Read-PerformanceCounter $set.Queue
        $thisLatency = Read-PerformanceCounter $set.Latency
        $thisBytes = Read-PerformanceCounter $set.Bytes
        if ($null -ne $thisActive -and $thisActive -gt $active) {
            $active = $thisActive
            $busiest = $set.Name
        }
        if ($null -ne $thisQueue -and $thisQueue -gt $queue) { $queue = $thisQueue }
        if ($null -ne $thisLatency -and $thisLatency -gt $latency) { $latency = $thisLatency }
        if ($null -ne $thisBytes) { $bytes += $thisBytes }
    }
    return [pscustomobject]@{
        ActivePct = [Math]::Max(0, [Math]::Min(100, $active))
        Queue = [Math]::Max(0, $queue)
        LatencyMs = [Math]::Max(0, $latency * 1000)
        MBps = [Math]::Max(0, $bytes / 1MB)
        Busiest = $busiest
    }
}

function Initialize-CoreCounters {
    $sets = New-Object System.Collections.Generic.List[object]
    try {
        $category = New-Object System.Diagnostics.PerformanceCounterCategory('Processor')
        $instances = @($category.GetInstanceNames() | Where-Object { $_ -ne '_Total' } | Sort-Object { [int]$_ })
        foreach ($instance in $instances) {
            $counter = New-PerformanceCounter 'Processor' '% Processor Time' $instance
            if ($null -ne $counter) {
                $sets.Add([pscustomobject]@{ Name = $instance; Usage = $counter })
            }
        }
    }
    catch { }
    return $sets
}

function Read-CoreCounters($CounterSets) {
    $maximum = 0.0
    $busyCount = 0
    foreach ($set in $CounterSets) {
        $value = Read-PerformanceCounter $set.Usage
        if ($null -eq $value) { continue }
        $value = [Math]::Max(0, [Math]::Min(100, $value))
        if ($value -gt $maximum) { $maximum = $value }
        if ($value -ge 90) { $busyCount += 1 }
    }
    return [pscustomobject]@{ MaximumPct = $maximum; BusyCount = $busyCount; Available = ($CounterSets.Count -gt 0) }
}

$script:GpuCounters = @{}

function Update-GpuCounters {
    try {
        if (-not [System.Diagnostics.PerformanceCounterCategory]::Exists('GPU Engine')) { return }
        $category = New-Object System.Diagnostics.PerformanceCounterCategory('GPU Engine')
        foreach ($instance in $category.GetInstanceNames()) {
            if (-not $script:GpuCounters.ContainsKey($instance)) {
                $counter = New-PerformanceCounter 'GPU Engine' 'Utilization Percentage' $instance
                if ($null -ne $counter) { $script:GpuCounters[$instance] = $counter }
            }
        }
    }
    catch { }
}

function Read-GpuCounters {
    $byEngine = @{}
    $byPid = @{}
    $dead = New-Object System.Collections.Generic.List[string]
    foreach ($instance in @($script:GpuCounters.Keys)) {
        try {
            $value = [double]$script:GpuCounters[$instance].NextValue()
            if ($value -lt 0) { $value = 0 }
            $engineKey = $instance
            if ($instance -match 'phys_(\d+)_eng_(\d+)_engtype_([^_]+)') {
                $engineKey = "phys_$($matches[1])_eng_$($matches[2])_$($matches[3])"
            }
            if (-not $byEngine.ContainsKey($engineKey)) { $byEngine[$engineKey] = 0.0 }
            $byEngine[$engineKey] += $value

            if ($instance -match 'pid_(\d+)') {
                $pidNumber = [int]$matches[1]
                if (-not $byPid.ContainsKey($pidNumber)) { $byPid[$pidNumber] = 0.0 }
                $byPid[$pidNumber] += $value
            }
        }
        catch {
            $dead.Add($instance)
        }
    }
    foreach ($instance in $dead) {
        try { $script:GpuCounters[$instance].Dispose() } catch { }
        $script:GpuCounters.Remove($instance)
    }
    $usage = 0.0
    foreach ($value in $byEngine.Values) { if ($value -gt $usage) { $usage = $value } }
    foreach ($pidNumber in @($byPid.Keys)) { $byPid[$pidNumber] = [Math]::Min(100, $byPid[$pidNumber]) }
    return [pscustomobject]@{ Usage = [Math]::Min(100, $usage); ByPid = $byPid; Available = ($script:GpuCounters.Count -gt 0) }
}

if (-not $Quiet) {
    Write-Host @'

  LagLens - Windows slowdown recorder
  ===================================
'@ -ForegroundColor Cyan
    Write-Host "Recording for up to $DurationMinutes minute(s), every $IntervalSeconds second(s)."
    Write-Host 'Use the computer normally, especially the thing that feels slow.'
    Write-Host 'Press S to stop early and create the report.' -ForegroundColor Yellow
}

$sessionStart = Get-Date
Write-Section 'Reading basic system information...'
$systemInfo = Get-StaticSystemInfo
if (-not $Quiet) { Write-Host ("Detected {0} GB RAM, {1} logical CPU threads, Windows build {2}." -f $systemInfo.TotalMemoryGB, $systemInfo.LogicalProcessors, $systemInfo.OSBuild) }

Write-Section 'Starting performance counters...'
$counters = [ordered]@{
    Cpu = New-PerformanceCounter 'Processor' '% Processor Time' '_Total'
    CpuUser = New-PerformanceCounter 'Processor' '% User Time' '_Total'
    CpuPrivileged = New-PerformanceCounter 'Processor' '% Privileged Time' '_Total'
    CpuUtility = New-PerformanceCounter 'Processor Information' '% Processor Utility' '_Total'
    CpuQueue = New-PerformanceCounter 'System' 'Processor Queue Length' $null
    AvailableMB = New-PerformanceCounter 'Memory' 'Available MBytes' $null
    CommittedPct = New-PerformanceCounter 'Memory' '% Committed Bytes In Use' $null
    PagesPerSec = New-PerformanceCounter 'Memory' 'Pages/sec' $null
    PageReadsPerSec = New-PerformanceCounter 'Memory' 'Page Reads/sec' $null
    MaxFrequencyPct = New-PerformanceCounter 'Processor Information' '% of Maximum Frequency' '_Total'
    ProcessorFrequencyMHz = New-PerformanceCounter 'Processor Information' 'Processor Frequency' '_Total'
    ActualFrequencyMHz = New-PerformanceCounter 'Processor Information' 'Actual Frequency' '_Total'
    ProcessorPerformancePct = New-PerformanceCounter 'Processor Information' '% Processor Performance' '_Total'
    ProcessorPerformanceLimitPct = New-PerformanceCounter 'Processor Information' '% Performance Limit' '_Total'
    DpcPct = New-PerformanceCounter 'Processor' '% DPC Time' '_Total'
    InterruptPct = New-PerformanceCounter 'Processor' '% Interrupt Time' '_Total'
    DpcRate = New-PerformanceCounter 'Processor' 'DPC Rate' '_Total'
    InterruptsPerSec = New-PerformanceCounter 'Processor' 'Interrupts/sec' '_Total'
    ContextSwitchesPerSec = New-PerformanceCounter 'System' 'Context Switches/sec' $null
    SystemProcessCount = New-PerformanceCounter 'System' 'Processes' $null
    SystemThreadCount = New-PerformanceCounter 'System' 'Threads' $null
}
$diskCounters = Initialize-DiskCounters
$coreCounters = Initialize-CoreCounters
Update-GpuCounters

$sessionStart = Get-Date
if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
$stamp = $sessionStart.ToString('yyyyMMdd-HHmmss')
$reportPath = Join-Path $OutputDirectory "LagLens-$stamp.html"
$samplesPath = Join-Path $OutputDirectory "LagLens-$stamp-samples.csv"
$liveSamplesPath = Join-Path $OutputDirectory "LagLens-$stamp-live.csv"
$processPath = Join-Path $OutputDirectory "LagLens-$stamp-processes.csv"
$systemPath = Join-Path $OutputDirectory "LagLens-$stamp-system.json"
$latestSystemPath = Join-Path $OutputDirectory 'LagLens-latest-system.json'
$batteryHistoryPath = Join-Path $OutputDirectory 'BatteryHealthHistory.csv'
$systemJson = $systemInfo | ConvertTo-Json -Depth 6
$systemJson | Set-Content -Path $systemPath -Encoding UTF8
$systemJson | Set-Content -Path $latestSystemPath -Encoding UTF8
if ($systemInfo.Battery.Present) {
    $initialPower = Get-BatteryTelemetry
    $batteryHistoryRow = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        DesignCapacityMWh = $systemInfo.Battery.DesignCapacityMWh
        FullChargeCapacityMWh = $systemInfo.Battery.FullChargeCapacityMWh
        HealthPercent = $systemInfo.Battery.HealthPercent
        CycleCount = $systemInfo.Battery.CycleCount
        PowerSource = $initialPower.PowerSource
        ChargePercent = $initialPower.ChargePercent
    }
    if (Test-Path $batteryHistoryPath) { $batteryHistoryRow | Export-Csv -Path $batteryHistoryPath -Append -NoTypeInformation -Encoding UTF8 }
    else { $batteryHistoryRow | Export-Csv -Path $batteryHistoryPath -NoTypeInformation -Encoding UTF8 }
}
$previousProcesses = Get-ProcessSnapshot
$previousCapture = Get-Date
$processTotals = @{}
$samples = New-Object System.Collections.Generic.List[object]
$targetSeconds = [Math]::Max(6, $DurationMinutes * 60)
$nextGpuRefresh = 30.0
$nextSlowTelemetryRefresh = 60.0
$nextUiSurveyRefresh = 60.0
$batteryTelemetry = Get-BatteryTelemetry
$wifiTelemetry = Get-WifiTelemetry
$uiSurvey = Get-VisibleWindowSurvey
$previousDwm = Get-DwmSnapshot
$markerRequestPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'lag-marker.request'
$burstUntil = [datetime]::MinValue
$stoppedEarly = $false

while (((Get-Date) - $sessionStart).TotalSeconds -lt $targetSeconds) {
    $beforeSleep = Get-Date
    $sleepSeconds = if ($beforeSleep -lt $burstUntil) { [Math]::Min(2, $IntervalSeconds) } else { $IntervalSeconds }
    Start-Sleep -Seconds $sleepSeconds
    $captureTime = Get-Date
    $captureInterval = [Math]::Max(0.1, ($captureTime - $previousCapture).TotalSeconds)
    $markerDetected = $false
    $markerTimestamp = ''
    if (Test-Path $markerRequestPath) {
        try { $markerTimestamp = (Get-Content -LiteralPath $markerRequestPath -Raw -ErrorAction Stop).Trim() } catch { }
        try { Remove-Item -LiteralPath $markerRequestPath -Force -ErrorAction SilentlyContinue } catch { }
        $markerDetected = $true
        $burstUntil = $captureTime.AddMinutes(2)
    }
    $captureMode = if ($captureTime -lt $burstUntil) { 'Burst' } else { 'Normal' }

    if (($captureTime - $sessionStart).TotalSeconds -ge $nextGpuRefresh) {
        Update-GpuCounters
        $nextGpuRefresh += 30.0
    }
    if (($captureTime - $sessionStart).TotalSeconds -ge $nextSlowTelemetryRefresh) {
        $batteryTelemetry = Get-BatteryTelemetry
        $wifiTelemetry = Get-WifiTelemetry
        $nextSlowTelemetryRefresh += 60.0
    }
    if (($captureTime - $sessionStart).TotalSeconds -ge $nextUiSurveyRefresh) {
        $uiSurvey = Get-VisibleWindowSurvey
        $nextUiSurveyRefresh += 60.0
    }

    $memoryFallback = Get-MemoryStatus
    $cpu = Read-PerformanceCounter $counters.Cpu
    $cpuUser = Read-PerformanceCounter $counters.CpuUser
    $cpuPrivileged = Read-PerformanceCounter $counters.CpuPrivileged
    $cpuUtility = Read-PerformanceCounter $counters.CpuUtility
    $cpuQueue = Read-PerformanceCounter $counters.CpuQueue
    $availableMB = Read-PerformanceCounter $counters.AvailableMB
    $committedPct = Read-PerformanceCounter $counters.CommittedPct
    $pagesPerSec = Read-PerformanceCounter $counters.PagesPerSec
    $pageReadsPerSec = Read-PerformanceCounter $counters.PageReadsPerSec
    $maxFrequencyPct = Read-PerformanceCounter $counters.MaxFrequencyPct
    $processorFrequencyMHz = Read-PerformanceCounter $counters.ProcessorFrequencyMHz
    $actualFrequencyMHz = Read-PerformanceCounter $counters.ActualFrequencyMHz
    $processorPerformancePct = Read-PerformanceCounter $counters.ProcessorPerformancePct
    $processorPerformanceLimitPct = Read-PerformanceCounter $counters.ProcessorPerformanceLimitPct
    $dpcPct = Read-PerformanceCounter $counters.DpcPct
    $interruptPct = Read-PerformanceCounter $counters.InterruptPct
    $dpcRate = Read-PerformanceCounter $counters.DpcRate
    $interruptsPerSec = Read-PerformanceCounter $counters.InterruptsPerSec
    $contextSwitchesPerSec = Read-PerformanceCounter $counters.ContextSwitchesPerSec
    $systemProcessCount = Read-PerformanceCounter $counters.SystemProcessCount
    $systemThreadCount = Read-PerformanceCounter $counters.SystemThreadCount
    if ($null -eq $availableMB) { $availableMB = $memoryFallback.AvailableMB }
    if ($null -eq $committedPct) { $committedPct = $memoryFallback.MemoryLoad }
    if ($null -eq $cpu) { $cpu = 0.0 }
    if ($null -eq $cpuUser) { $cpuUser = 0.0 }
    if ($null -eq $cpuPrivileged) { $cpuPrivileged = 0.0 }
    if ($null -eq $cpuUtility) { $cpuUtility = 0.0 }
    if ($null -eq $cpuQueue) { $cpuQueue = 0.0 }
    if ($null -eq $pagesPerSec) { $pagesPerSec = 0.0 }
    if ($null -eq $pageReadsPerSec) { $pageReadsPerSec = 0.0 }
    if ($null -eq $maxFrequencyPct) { $maxFrequencyPct = 0.0 }
    if ($null -eq $processorFrequencyMHz) { $processorFrequencyMHz = 0.0 }
    if ($null -eq $actualFrequencyMHz) { $actualFrequencyMHz = 0.0 }
    if ($null -eq $processorPerformancePct) { $processorPerformancePct = 0.0 }
    if ($null -eq $processorPerformanceLimitPct) { $processorPerformanceLimitPct = 0.0 }
    if ($null -eq $dpcPct) { $dpcPct = 0.0 }
    if ($null -eq $interruptPct) { $interruptPct = 0.0 }
    if ($null -eq $dpcRate) { $dpcRate = 0.0 }
    if ($null -eq $interruptsPerSec) { $interruptsPerSec = 0.0 }
    if ($null -eq $contextSwitchesPerSec) { $contextSwitchesPerSec = 0.0 }
    if ($null -eq $systemProcessCount) { $systemProcessCount = 0.0 }
    if ($null -eq $systemThreadCount) { $systemThreadCount = 0.0 }

    $disk = Read-DiskCounters $diskCounters
    $cores = Read-CoreCounters $coreCounters
    $gpu = Read-GpuCounters
    $foreground = Get-ForegroundResponse
    $dwm = Get-DwmSnapshot
    $dwmMissedDelta = 0.0
    $dwmDroppedDelta = 0.0
    $dwmDisplayedFps = 0.0
    $dwmRefreshFps = 0.0
    if ($dwm.Available -and $previousDwm.Available) {
        if ($dwm.FramesMissed -ge $previousDwm.FramesMissed) { $dwmMissedDelta = $dwm.FramesMissed - $previousDwm.FramesMissed }
        if ($dwm.FramesDropped -ge $previousDwm.FramesDropped) { $dwmDroppedDelta = $dwm.FramesDropped - $previousDwm.FramesDropped }
        if ($dwm.FramesDisplayed -ge $previousDwm.FramesDisplayed) { $dwmDisplayedFps = ($dwm.FramesDisplayed - $previousDwm.FramesDisplayed) / $captureInterval }
        if ($dwm.RefreshesDisplayed -ge $previousDwm.RefreshesDisplayed) { $dwmRefreshFps = ($dwm.RefreshesDisplayed - $previousDwm.RefreshesDisplayed) / $captureInterval }
    }
    if (($foreground.Hung -or $foreground.ResponseMs -ge 100) -and $IntervalSeconds -gt 2 -and $captureTime -ge $burstUntil) {
        $burstUntil = $captureTime.AddMinutes(2)
        $captureMode = 'Burst'
    }
    $currentProcesses = Get-ProcessSnapshot
    $processGroups = @{}

    foreach ($process in $currentProcesses.Values) {
        if ($process.Name -eq 'Idle') { continue }
        $cpuPct = 0.0
        $ioMBps = 0.0
        if ($previousProcesses.ContainsKey($process.Id)) {
            $previous = $previousProcesses[$process.Id]
            if ($process.CpuSeconds -ge $previous.CpuSeconds) {
                $cpuPct = (($process.CpuSeconds - $previous.CpuSeconds) / $captureInterval / [Math]::Max(1, $systemInfo.LogicalProcessors)) * 100.0
            }
            $currentIo = $process.ReadBytes + $process.WriteBytes
            $previousIo = $previous.ReadBytes + $previous.WriteBytes
            if ($currentIo -ge $previousIo) { $ioMBps = (($currentIo - $previousIo) / $captureInterval) / 1MB }
        }

        if (-not $processGroups.ContainsKey($process.Name)) {
            $processGroups[$process.Name] = [pscustomobject]@{ Cpu = 0.0; Io = 0.0; Memory = 0.0; Gpu = 0.0; Instances = 0 }
        }
        $group = $processGroups[$process.Name]
        $group.Cpu += $cpuPct
        $group.Io += $ioMBps
        $group.Memory += $process.WorkingSetMB
        $group.Instances += 1
        if ($gpu.ByPid.ContainsKey($process.Id)) { $group.Gpu += [double]$gpu.ByPid[$process.Id] }
    }

    foreach ($name in $processGroups.Keys) {
        $group = $processGroups[$name]
        if (-not $processTotals.ContainsKey($name)) {
            $processTotals[$name] = [pscustomobject]@{
                Name = $name
                CpuTotal = 0.0
                CpuPeak = 0.0
                IoTotal = 0.0
                IoPeak = 0.0
                MemoryPeak = 0.0
                GpuTotal = 0.0
                GpuPeak = 0.0
                MaxInstances = 0
                SeenSamples = 0
            }
        }
        $total = $processTotals[$name]
        $total.CpuTotal += [double]$group.Cpu
        $total.CpuPeak = [Math]::Max($total.CpuPeak, [double]$group.Cpu)
        $total.IoTotal += [double]$group.Io
        $total.IoPeak = [Math]::Max($total.IoPeak, [double]$group.Io)
        $total.MemoryPeak = [Math]::Max($total.MemoryPeak, [double]$group.Memory)
        $total.GpuTotal += [double]$group.Gpu
        $total.GpuPeak = [Math]::Max($total.GpuPeak, [double]$group.Gpu)
        $total.MaxInstances = [Math]::Max($total.MaxInstances, [int]$group.Instances)
        $total.SeenSamples += 1
    }

    $attributedProcessCpuPct = 0.0
    foreach ($group in $processGroups.Values) { $attributedProcessCpuPct += [double]$group.Cpu }
    $cpuAttributionGapPct = [Math]::Max(0, [double]$cpu - $attributedProcessCpuPct)

    $sample = [pscustomobject]@{
        Timestamp = $captureTime.ToString('o')
        ElapsedSeconds = [Math]::Round(($captureTime - $sessionStart).TotalSeconds, 1)
        CaptureMode = $captureMode
        LagMarker = $markerDetected
        MarkerTimestamp = $markerTimestamp
        CpuPct = [Math]::Round([Math]::Max(0, [Math]::Min(100, $cpu)), 2)
        CpuUtilityPct = [Math]::Round([Math]::Max(0, $cpuUtility), 2)
        CpuUserPct = [Math]::Round([Math]::Max(0, $cpuUser), 2)
        CpuPrivilegedPct = [Math]::Round([Math]::Max(0, $cpuPrivileged), 2)
        MaxLogicalCpuPct = [Math]::Round($cores.MaximumPct, 2)
        BusyLogicalCpuCount = $cores.BusyCount
        CpuQueue = [Math]::Round([Math]::Max(0, $cpuQueue), 2)
        AttributedProcessCpuPct = [Math]::Round([Math]::Max(0, $attributedProcessCpuPct), 2)
        CpuAttributionGapPct = [Math]::Round($cpuAttributionGapPct, 2)
        MaxFrequencyPct = [Math]::Round([Math]::Max(0, $maxFrequencyPct), 2)
        ProcessorFrequencyMHz = [Math]::Round([Math]::Max(0, $processorFrequencyMHz), 0)
        ActualFrequencyMHz = [Math]::Round([Math]::Max(0, $actualFrequencyMHz), 0)
        ProcessorPerformancePct = [Math]::Round([Math]::Max(0, $processorPerformancePct), 2)
        ProcessorPerformanceLimitPct = [Math]::Round([Math]::Max(0, $processorPerformanceLimitPct), 2)
        DpcPct = [Math]::Round([Math]::Max(0, $dpcPct), 2)
        InterruptPct = [Math]::Round([Math]::Max(0, $interruptPct), 2)
        DpcRate = [Math]::Round([Math]::Max(0, $dpcRate), 2)
        InterruptsPerSec = [Math]::Round([Math]::Max(0, $interruptsPerSec), 2)
        ContextSwitchesPerSec = [Math]::Round([Math]::Max(0, $contextSwitchesPerSec), 2)
        AvailableMemoryMB = [Math]::Round([Math]::Max(0, $availableMB), 1)
        CommittedMemoryPct = [Math]::Round([Math]::Max(0, $committedPct), 2)
        PagesPerSec = [Math]::Round([Math]::Max(0, $pagesPerSec), 2)
        PageReadsPerSec = [Math]::Round([Math]::Max(0, $pageReadsPerSec), 2)
        DiskActivePct = [Math]::Round($disk.ActivePct, 2)
        DiskQueue = [Math]::Round($disk.Queue, 2)
        DiskLatencyMs = [Math]::Round($disk.LatencyMs, 2)
        DiskMBps = [Math]::Round($disk.MBps, 2)
        BusiestDisk = $disk.Busiest
        GpuPct = [Math]::Round($gpu.Usage, 2)
        ProcessCount = $currentProcesses.Count
        SystemProcessCount = [Math]::Round([Math]::Max(0, $systemProcessCount), 0)
        SystemThreadCount = [Math]::Round([Math]::Max(0, $systemThreadCount), 0)
        ForegroundProcess = $foreground.Process
        ForegroundResponseMs = [Math]::Round($foreground.ResponseMs, 2)
        ForegroundHung = [bool]$foreground.Hung
        VisibleAppsTested = $uiSurvey.Tested
        WorstVisibleAppResponseMs = [Math]::Round($uiSurvey.WorstResponseMs, 2)
        SlowVisibleApps = $uiSurvey.SlowProcesses
        HungVisibleApps = $uiSurvey.HungProcesses
        DwmConfiguredRefreshHz = [Math]::Round($dwm.RefreshHz, 2)
        DwmObservedRefreshFps = [Math]::Round($dwmRefreshFps, 2)
        DwmComposedFps = [Math]::Round($dwmDisplayedFps, 2)
        DwmFramesMissed = [Math]::Round($dwmMissedDelta, 0)
        DwmFramesDropped = [Math]::Round($dwmDroppedDelta, 0)
        PowerSource = $batteryTelemetry.PowerSource
        BatteryChargePct = $batteryTelemetry.ChargePercent
        BatteryEstimatedRemainingSeconds = $batteryTelemetry.EstimatedRemainingSeconds
        BatteryChargeFlags = $batteryTelemetry.ChargeFlags
        BatteryDischargeRateMW = $batteryTelemetry.DischargeRateMW
        BatteryChargeRateMW = $batteryTelemetry.ChargeRateMW
        BatteryRemainingCapacityMWh = $batteryTelemetry.RemainingCapacityMWh
        BatteryVoltageMV = $batteryTelemetry.VoltageMV
        BrightnessPct = $batteryTelemetry.BrightnessPercent
        ThermalZoneC = $batteryTelemetry.ThermalZoneC
        WifiSignalPct = $wifiTelemetry.SignalPercent
        WifiReceiveLinkMbps = $wifiTelemetry.ReceiveLinkMbps
        WifiTransmitLinkMbps = $wifiTelemetry.TransmitLinkMbps
        WifiRadioType = $wifiTelemetry.RadioType
        TopCpuProcesses = Get-ProcessLeaderText $processGroups 'Cpu'
        TopMemoryProcesses = Get-ProcessLeaderText $processGroups 'Memory'
        TopIoProcesses = Get-ProcessLeaderText $processGroups 'Io'
        TopGpuProcesses = Get-ProcessLeaderText $processGroups 'Gpu'
    }
    $samples.Add($sample)
    try {
        if (Test-Path $liveSamplesPath) {
            $sample | Export-Csv -Path $liveSamplesPath -Append -NoTypeInformation -Encoding UTF8
        }
        else {
            $sample | Export-Csv -Path $liveSamplesPath -NoTypeInformation -Encoding UTF8
        }
    }
    catch { }

    $previousProcesses = $currentProcesses
    $previousCapture = $captureTime
    $previousDwm = $dwm
    $elapsed = ($captureTime - $sessionStart).TotalSeconds
    $percent = [Math]::Min(100, ($elapsed / $targetSeconds) * 100)
    if (-not $Quiet) {
        Write-Progress -Activity 'LagLens is recording' -Status ("{0:N0}s captured | CPU {1:N0}% | Disk {2:N0}% | {3:N0} MB RAM free" -f $elapsed, $cpu, $disk.ActivePct, $availableMB) -PercentComplete $percent
    }

    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::S) { $stoppedEarly = $true; break }
        }
    }
    catch { }
}
if (-not $Quiet) { Write-Progress -Activity 'LagLens is recording' -Completed }
$sessionEnd = Get-Date

if ($samples.Count -eq 0) {
    Write-Error 'No samples were captured. Please run LagLens again.'
    exit 1
}

Write-Section 'Analyzing the recording...'
$cpuValues = @($samples | ForEach-Object { $_.CpuPct })
$cpuUtilityValues = @($samples | ForEach-Object { $_.CpuUtilityPct })
$cpuCoreMaximumValues = @($samples | ForEach-Object { $_.MaxLogicalCpuPct })
$cpuPerformanceValues = @($samples | ForEach-Object { $_.ProcessorPerformancePct })
$actualFrequencyValues = @($samples | ForEach-Object { $_.ActualFrequencyMHz })
$queueValues = @($samples | ForEach-Object { $_.CpuQueue })
$frequencyValues = @($samples | ForEach-Object { $_.MaxFrequencyPct })
$availableValues = @($samples | ForEach-Object { $_.AvailableMemoryMB })
$committedValues = @($samples | ForEach-Object { $_.CommittedMemoryPct })
$pageReadValues = @($samples | ForEach-Object { $_.PageReadsPerSec })
$diskActiveValues = @($samples | ForEach-Object { $_.DiskActivePct })
$diskQueueValues = @($samples | ForEach-Object { $_.DiskQueue })
$diskLatencyValues = @($samples | ForEach-Object { $_.DiskLatencyMs })
$gpuValues = @($samples | ForEach-Object { $_.GpuPct })
$foregroundResponseValues = @($samples | Where-Object { $_.ForegroundProcess -and -not $_.ForegroundHung } | ForEach-Object { $_.ForegroundResponseMs })
$dpcValues = @($samples | ForEach-Object { $_.DpcPct })
$interruptValues = @($samples | ForEach-Object { $_.InterruptPct })
$contextSwitchValues = @($samples | ForEach-Object { $_.ContextSwitchesPerSec })
$dwmMissedValues = @($samples | ForEach-Object { $_.DwmFramesMissed })
$batteryChargeValues = @($samples | Where-Object { $_.BatteryChargePct -ge 0 } | ForEach-Object { $_.BatteryChargePct })

$sampleCount = [Math]::Max(1, $samples.Count)
$processSummary = @($processTotals.Values | ForEach-Object {
    [pscustomobject]@{
        Process = $_.Name
        AverageCpuPct = [Math]::Round($_.CpuTotal / $sampleCount, 2)
        PeakCpuPct = [Math]::Round($_.CpuPeak, 2)
        AverageIoMBps = [Math]::Round($_.IoTotal / $sampleCount, 2)
        PeakIoMBps = [Math]::Round($_.IoPeak, 2)
        PeakMemoryMB = [Math]::Round($_.MemoryPeak, 1)
        AverageGpuPct = [Math]::Round($_.GpuTotal / $sampleCount, 2)
        PeakGpuPct = [Math]::Round($_.GpuPeak, 2)
        MaxInstances = $_.MaxInstances
        SeenSamples = $_.SeenSamples
    }
})

$topCpu = @($processSummary | Sort-Object AverageCpuPct -Descending | Select-Object -First 3)
$topIo = @($processSummary | Sort-Object AverageIoMBps -Descending | Select-Object -First 3)
$topMemory = @($processSummary | Sort-Object PeakMemoryMB -Descending | Select-Object -First 3)
$topGpu = @($processSummary | Sort-Object AverageGpuPct -Descending | Select-Object -First 3)

$cpuAverage = Get-AverageValue $cpuValues
$cpuP95 = Get-Percentile $cpuValues 95
$cpuPeak = Get-PeakValue $cpuValues
$cpuHighFraction = Get-FractionAtOrAbove $cpuValues 90
$cpuCoreP95 = Get-Percentile $cpuCoreMaximumValues 95
$cpuCoreBusyFraction = Get-FractionAtOrAbove $cpuCoreMaximumValues 95
$cpuUtilityP95 = Get-Percentile $cpuUtilityValues 95
$queueP95 = Get-Percentile $queueValues 95
$availableMinMB = Get-MinValue $availableValues
$availableMinPct = if ($systemInfo.TotalMemoryGB -gt 0) { ($availableMinMB / ($systemInfo.TotalMemoryGB * 1024)) * 100 } else { 0 }
$committedP95 = Get-Percentile $committedValues 95
$pageReadsP95 = Get-Percentile $pageReadValues 95
$diskAverage = Get-AverageValue $diskActiveValues
$diskP95 = Get-Percentile $diskActiveValues 95
$diskPeak = Get-PeakValue $diskActiveValues
$diskHighFraction = Get-FractionAtOrAbove $diskActiveValues 90
$diskQueueP95 = Get-Percentile $diskQueueValues 95
$diskLatencyP95 = Get-Percentile $diskLatencyValues 95
$gpuP95 = Get-Percentile $gpuValues 95
$gpuPeak = Get-PeakValue $gpuValues
$foregroundResponseP95 = Get-Percentile $foregroundResponseValues 95
$foregroundResponsePeak = Get-PeakValue $foregroundResponseValues
$foregroundHungCount = @($samples | Where-Object { $_.ForegroundHung }).Count
$dpcP95 = Get-Percentile $dpcValues 95
$interruptP95 = Get-Percentile $interruptValues 95
$contextSwitchP95 = Get-Percentile $contextSwitchValues 95
$dwmMissedTotal = [double](($dwmMissedValues | Measure-Object -Sum).Sum)
$markerCount = @($samples | Where-Object { $_.LagMarker }).Count
$batterySamples = @($samples | Where-Object { $_.PowerSource -eq 'Battery' -and $_.BatteryChargePct -ge 0 })

$findings = New-Object System.Collections.Generic.List[object]
$events = Get-RecentRelevantEvents $sessionStart
$gpuWatchdogEvents = @($events | Where-Object { $_.Message -match 'LiveKernelEvent.*P1:\s*(117|141)' })
if ($gpuWatchdogEvents.Count -gt 0) {
    Add-Finding $findings 'warning' 'Graphics driver' 'Windows recorded graphics-engine watchdog failures' ("Reliability history contains {0} LiveKernelEvent 117/141 event(s) in the last 30 days. These are consistent with a graphics engine or driver becoming unresponsive and can produce frozen or slowly redrawn windows." -f $gpuWatchdogEvents.Count) 'Update the graphics driver using the laptop maker or Intel package, then compare marked slow moments. If watchdogs continue on a current driver, hardware or thermal troubleshooting becomes more important.'
}
$foregroundAvailableCount = @($samples | Where-Object { $_.ForegroundProcess }).Count
$uiOffenders = @($samples | Where-Object { $_.ForegroundProcess -and ($_.ForegroundHung -or $_.ForegroundResponseMs -ge 75) } | Group-Object ForegroundProcess | Sort-Object Count -Descending | Select-Object -First 4)
$uiOffenderText = if ($uiOffenders.Count -gt 0) { ($uiOffenders | ForEach-Object { "$($_.Name) ($($_.Count) delayed sample(s))" }) -join ', ' } else { 'No recurring foreground offender' }
if ($foregroundAvailableCount -eq 0) {
    Add-Finding $findings 'info' 'App responsiveness' 'The background session could not directly inspect the interactive desktop' 'System resource data was recorded, but Windows did not expose a foreground window to this process.' 'Press Ctrl+Alt+L during the next slowdown. The marker now starts a separate interactive, one-second UI burst for two minutes without recording window titles or input content.'
}
elseif ($foregroundHungCount -gt 0 -or $foregroundResponseP95 -ge 150 -or @($samples | Where-Object { $_.HungVisibleApps }).Count -gt 0) {
    Add-Finding $findings 'warning' 'App responsiveness' 'One or more app windows stopped responding promptly' ("Foreground message response reached {0:N0} ms at the 95th percentile with {1} timed-out sample(s). Repeated apps: {2}. DWM reported {3:N0} missed frame(s)." -f $foregroundResponseP95, $foregroundHungCount, $uiOffenderText, $dwmMissedTotal) 'Use Ctrl+Alt+L when the delay is visible. LagLens will switch into a two-minute high-resolution burst so the delayed app can be matched to CPU, GPU, disk, driver, and battery state.'
}
elseif ($foregroundResponseP95 -ge 50 -or $dwmMissedTotal -ge [Math]::Max(5, (($sessionEnd - $sessionStart).TotalMinutes * 10))) {
    Add-Finding $findings 'warning' 'App responsiveness' 'Brief UI latency or compositor frame misses were recorded' ("Foreground response was {0:N0} ms at the 95th percentile and peaked at {1:N0} ms. DWM reported {2:N0} missed frame(s)." -f $foregroundResponseP95, $foregroundResponsePeak, $dwmMissedTotal) 'Mark the next obvious slowdown with Ctrl+Alt+L; brief symptoms benefit most from the burst capture.'
}
else {
    Add-Finding $findings 'good' 'App responsiveness' 'App message queues responded promptly in this recording' ("Foreground response was {0:N1} ms at the 95th percentile with {1} timed-out samples. DWM reported {2:N0} missed frame(s)." -f $foregroundResponseP95, $foregroundHungCount, $dwmMissedTotal) 'This does not rule out a brief event between samples; use Ctrl+Alt+L when you feel one.'
}

if ($dpcP95 -ge 5 -or $interruptP95 -ge 5) {
    Add-Finding $findings 'warning' 'Drivers / input latency' 'Driver interrupt work may be delaying input and window updates' ("At the 95th percentile, DPC time was {0:N1}% and interrupt time was {1:N1}%; context switching reached {2:N0}/sec." -f $dpcP95, $interruptP95, $contextSwitchP95) 'A marked lag burst can narrow this to graphics, Wi-Fi, audio, USB/input, or storage activity. A targeted ETW trace can be added later if the pattern repeats.'
}
elseif ($contextSwitchP95 -ge 100000) {
    Add-Finding $findings 'info' 'Drivers / input latency' 'The system showed unusually high scheduling churn' ("Context switches reached {0:N0}/sec at the 95th percentile, while DPC and interrupt time remained lower." -f $contextSwitchP95) 'Compare this with marked slow moments and the top process list before treating it as a cause.'
}
else {
    Add-Finding $findings 'good' 'Drivers / input latency' 'Driver interrupt pressure looked normal' ("DPC time was {0:N1}% and interrupt time was {1:N1}% at the 95th percentile." -f $dpcP95, $interruptP95) 'No driver-latency action is suggested from this recording.'
}

$batteryHealth = [double]$systemInfo.Battery.HealthPercent
if ($systemInfo.Battery.Present) {
    if ($batteryHealth -lt 60) {
        Add-Finding $findings 'warning' 'Battery' 'The battery is substantially worn' ("Full-charge capacity is {0:N0} mWh versus {1:N0} mWh when new ({2:N1}% health), with {3} reported cycles." -f $systemInfo.Battery.FullChargeCapacityMWh, $systemInfo.Battery.DesignCapacityMWh, $batteryHealth, $systemInfo.Battery.CycleCount) 'Battery replacement is likely to improve runtime more than software tuning. Stop using it if it is swollen, unusually hot, or causing sudden shutdowns.'
    }
    elseif ($batteryHealth -lt 80) {
        Add-Finding $findings 'warning' 'Battery' 'The battery has meaningful age-related capacity loss' ("Full-charge capacity is {0:N0} mWh versus {1:N0} mWh when new ({2:N1}% health), with {3} reported cycles." -f $systemInfo.Battery.FullChargeCapacityMWh, $systemInfo.Battery.DesignCapacityMWh, $batteryHealth, $systemInfo.Battery.CycleCount) 'An unplugged marked session will show whether background activity is making the reduced capacity drain unusually fast.'
    }
    elseif ($batteryHealth -lt 90) {
        Add-Finding $findings 'info' 'Battery' 'The battery shows moderate wear for its age' ("Full-charge capacity is {0:N0} mWh versus {1:N0} mWh when new ({2:N1}% health), with {3} reported cycles." -f $systemInfo.Battery.FullChargeCapacityMWh, $systemInfo.Battery.DesignCapacityMWh, $batteryHealth, $systemInfo.Battery.CycleCount) 'This capacity loss is real but may not explain all of the poor runtime; collect at least 20 minutes while unplugged to measure the drain rate.'
    }
    else {
        Add-Finding $findings 'good' 'Battery' 'Battery capacity remains close to its original rating' ("Reported battery health is {0:N1}% after {1} cycles." -f $batteryHealth, $systemInfo.Battery.CycleCount) 'Use an unplugged recording to look for excessive software or display power use.'
    }
}

if ($batterySamples.Count -ge 2) {
    $firstBatterySample = $batterySamples | Select-Object -First 1
    $lastBatterySample = $batterySamples | Select-Object -Last 1
    $batteryHours = ([datetime]$lastBatterySample.Timestamp - [datetime]$firstBatterySample.Timestamp).TotalHours
    $chargeDrop = [double]$firstBatterySample.BatteryChargePct - [double]$lastBatterySample.BatteryChargePct
    $drainPerHour = if ($batteryHours -gt 0.1 -and $chargeDrop -ge 0) { $chargeDrop / $batteryHours } else { 0.0 }
    $dischargeRateValues = @($batterySamples | Where-Object { $_.BatteryDischargeRateMW -gt 0 } | ForEach-Object { $_.BatteryDischargeRateMW })
    $dischargeRateAverage = Get-AverageValue $dischargeRateValues
    $runtimeEstimate = if ($dischargeRateAverage -gt 0 -and $systemInfo.Battery.FullChargeCapacityMWh -gt 0) { $systemInfo.Battery.FullChargeCapacityMWh / $dischargeRateAverage } else { 0.0 }
    if (($batteryHours -ge 0.25 -and $drainPerHour -ge 25) -or ($runtimeEstimate -gt 0 -and $runtimeEstimate -lt 3)) {
        Add-Finding $findings 'warning' 'Battery drain' 'The unplugged drain rate was high' ("Across {0:N0} unplugged minutes, charge fell {1:N1} points ({2:N1}%/hour). Firmware-reported discharge averaged {3:N0} mW, implying about {4:N1} hours from a full charge at this load." -f ($batteryHours * 60), $chargeDrop, $drainPerHour, $dischargeRateAverage, $runtimeEstimate) 'Compare the top CPU/GPU processes and brightness during these samples; mark a typical unplugged slowdown to capture a high-resolution segment.'
    }
    else {
        Add-Finding $findings 'info' 'Battery drain' 'An unplugged segment was captured' ("Across {0:N0} unplugged minutes, the observed charge drop was {1:N1} points ({2:N1}%/hour). Firmware-reported discharge averaged {3:N0} mW." -f ($batteryHours * 60), $chargeDrop, $drainPerHour, $dischargeRateAverage) 'Longer unplugged segments produce a more reliable runtime estimate because the charge percentage changes in coarse steps.'
    }
}
else {
    Add-Finding $findings 'info' 'Battery drain' 'This recording did not include a meaningful unplugged segment' 'Battery health is available, but software drain cannot be measured while the laptop remains on AC power.' 'Use the laptop normally on battery for at least 20-30 minutes; LagLens will separate those samples automatically.'
}

$cpuLeaders = if ($topCpu.Count -gt 0) { ($topCpu | ForEach-Object { "$($_.Process) ($([Math]::Round($_.AverageCpuPct,1))% avg)" }) -join ', ' } else { 'No process attribution available' }
if ($cpuHighFraction -ge 0.20 -or ($cpuP95 -ge 95 -and $queueP95 -ge [Math]::Max(2, $systemInfo.LogicalProcessors / 2))) {
    Add-Finding $findings 'critical' 'CPU' 'The processor was a sustained bottleneck' ("CPU was at least 90% for {0:N0}% of the recording (95th percentile {1:N0}%). Leading processes: {2}." -f ($cpuHighFraction * 100), $cpuP95, $cpuLeaders) 'Re-run while closing or pausing the leading process. If System is the leader, update chipset, storage, network, and graphics drivers.'
}
elseif ($cpuCoreP95 -ge 95 -or $cpuCoreBusyFraction -ge 0.20) {
    Add-Finding $findings 'warning' 'CPU' 'One logical CPU was frequently saturated' ("The busiest logical CPU reached {0:N0}% at the 95th percentile while whole-machine CPU was {1:N0}%. Frequency-adjusted CPU utility reached {2:N0}%. Leading processes: {3}." -f $cpuCoreP95, $cpuP95, $cpuUtilityP95, $cpuLeaders) 'This can make a browser tab, Explorer, or another mostly single-threaded task stutter even when total CPU is below 100%. Use Ctrl+Alt+L during a visible delay to identify the foreground app.'
}
elseif ($cpuP95 -ge 85 -or $queueP95 -gt $systemInfo.LogicalProcessors) {
    Add-Finding $findings 'warning' 'CPU' 'Short CPU saturation or a processor backlog was recorded' ("CPU peaked at {0:N0}% and the 95th-percentile processor queue was {1:N1}. Leading processes: {2}." -f $cpuPeak, $queueP95, $cpuLeaders) 'Check whether the same process leads during a moment that visibly feels slow.'
}
else {
    Add-Finding $findings 'good' 'CPU' 'CPU capacity looked healthy during this recording' ("CPU averaged {0:N0}% with a {1:N0}% 95th percentile; no sustained processor queue formed." -f $cpuAverage, $cpuP95) 'No CPU-specific action is suggested from this run.'
}

if (($availableMinPct -lt 5 -or $availableMinMB -lt 768) -and ($committedP95 -ge 90 -or $pageReadsP95 -ge 25)) {
    Add-Finding $findings 'critical' 'Memory' 'Windows ran short of usable memory' ("Available RAM fell to {0:N0} MB ({1:N1}% of installed RAM), commit reached {2:N0}%, and page reads were {3:N0}/sec at the 95th percentile." -f $availableMinMB, $availableMinPct, $committedP95, $pageReadsP95) 'Sort Task Manager by Memory and reduce the leading apps, browser tabs, or background tools. Keep the page file enabled.'
}
elseif ($availableMinPct -lt 12 -or $committedP95 -ge 88 -or ($pageReadsP95 -ge 40 -and $availableMinPct -lt 20)) {
    Add-Finding $findings 'warning' 'Memory' 'Some memory pressure was recorded' ("Available RAM bottomed at {0:N1} GB ({1:N1}%), commit reached {2:N0}%, and physical page reads reached {3:N0}/sec at the 95th percentile. Largest working sets: {4}." -f ($availableMinMB / 1024), $availableMinPct, $committedP95, $pageReadsP95, (($topMemory | ForEach-Object { "$($_.Process) ($([Math]::Round($_.PeakMemoryMB)) MB)" }) -join ', ')) 'Repeat during the worst slowdown. If this repeats, trim the largest apps or investigate a process whose memory keeps growing.'
}
else {
    Add-Finding $findings 'good' 'Memory' 'The 20 GB of RAM was not the limiter in this run' ("At least {0:N1} GB remained available and commit stayed below {1:N0}% at the 95th percentile." -f ($availableMinMB / 1024), $committedP95) 'Extra RAM is unlikely to fix the slowdown captured here; focus on any CPU, disk, GPU, power, or driver finding.'
}

$ioLeaders = if ($topIo.Count -gt 0) { ($topIo | ForEach-Object { "$($_.Process) ($([Math]::Round($_.AverageIoMBps,1)) MB/s avg)" }) -join ', ' } else { 'No process attribution available' }
if (($diskLatencyP95 -ge 50 -and ($diskHighFraction -ge 0.10 -or $diskQueueP95 -ge 2)) -or ($diskHighFraction -ge 0.25 -and $diskQueueP95 -ge 2)) {
    Add-Finding $findings 'critical' 'Disk' 'Storage stalls are a likely cause of the lag' ("The busiest disk was at least 90% active for {0:N0}% of the recording, 95th-percentile latency was {1:N0} ms, and queue depth was {2:N1}. I/O leaders: {3}." -f ($diskHighFraction * 100), $diskLatencyP95, $diskQueueP95, $ioLeaders) 'Back up important files. Check drive health, free space, Windows Update/antivirus activity, and whether Windows is installed on a mechanical hard drive.'
}
elseif ($diskLatencyP95 -ge 25 -or $diskHighFraction -ge 0.10 -or $diskQueueP95 -ge 2) {
    Add-Finding $findings 'warning' 'Disk' 'The disk had noticeable busy or high-latency periods' ("Disk activity peaked at {0:N0}%, 95th-percentile latency was {1:N0} ms, and the queue reached {2:N1} at the 95th percentile. I/O leaders: {3}." -f $diskPeak, $diskLatencyP95, $diskQueueP95, $ioLeaders) 'Repeat during a clearly laggy period. A recurring latency result is more important than raw MB/s and often points to a slow or unhealthy drive.'
}
else {
    Add-Finding $findings 'good' 'Disk' 'Storage responded normally during this recording' ("The busiest disk averaged {0:N0}% active with {1:N0} ms latency at the 95th percentile." -f $diskAverage, $diskLatencyP95) 'No storage-specific action is suggested from this run.'
}

if ($script:GpuCounters.Count -gt 0) {
    $gpuLeaders = if ($topGpu.Count -gt 0) { ($topGpu | ForEach-Object { "$($_.Process) ($([Math]::Round($_.AverageGpuPct,1))% avg)" }) -join ', ' } else { 'No process attribution available' }
    if ($gpuP95 -ge 95) {
        Add-Finding $findings 'warning' 'GPU' 'Graphics utilization reached its limit' ("GPU utilization was {0:N0}% at the 95th percentile and peaked at {1:N0}%. Leaders: {2}." -f $gpuP95, $gpuPeak, $gpuLeaders) 'If this happened outside a game, update the graphics driver and disable unnecessary browser/app hardware acceleration one app at a time.'
    }
    else {
        Add-Finding $findings 'good' 'GPU' 'Graphics capacity did not stay saturated' ("GPU use was {0:N0}% at the 95th percentile." -f $gpuP95) 'A driver reset can still cause a short freeze; the hardware/driver event check below looks for that.'
    }
}
else {
    Add-Finding $findings 'info' 'GPU' 'GPU counters were unavailable' 'This Windows/driver combination did not expose GPU Engine performance counters to LagLens.' "Use Task Manager's Performance > GPU view during a future slowdown if graphics remains suspicious."
}

$highCpuFrequencySamples = @($samples | Where-Object { $_.CpuPct -ge 60 -and $_.ProcessorPerformancePct -gt 0 })
if ($highCpuFrequencySamples.Count -ge 3) {
    $lowFrequencyFraction = Get-FractionAtOrAbove @($highCpuFrequencySamples | ForEach-Object { 100 - $_.ProcessorPerformancePct }) 30
    $frequencyP05Equivalent = 100 - (Get-Percentile @($highCpuFrequencySamples | ForEach-Object { 100 - $_.ProcessorPerformancePct }) 95)
    if ($lowFrequencyFraction -ge 0.30) {
        $actualFrequencyP05 = Get-Percentile $actualFrequencyValues 5
        Add-Finding $findings 'warning' 'Power / heat' 'The CPU may be power- or heat-limited under load' ("While CPU use was high, effective processor performance stayed below 70% of nominal for {0:N0}% of those samples; the low point was about {1:N0}% and observed frequency fell to about {2:N0} MHz. Active power plan: {3}." -f ($lowFrequencyFraction * 100), $frequencyP05Equivalent, $actualFrequencyP05, $systemInfo.ActivePowerPlan) "Plug in the charger, use Balanced or Best performance, clear blocked vents, and check CPU temperature with the PC maker's utility."
    }
}
if ($systemInfo.ActivePowerPlan -match 'Power saver|Battery saver') {
    Add-Finding $findings 'warning' 'Power / heat' 'A power-saving plan is active' ("Windows reports the active plan as '$($systemInfo.ActivePowerPlan)'.") 'Switch Windows power mode to Balanced or Best performance and compare another recording.'
}

if ($systemInfo.SystemDriveFreePercent -gt 0 -and $systemInfo.SystemDriveFreePercent -lt 10) {
    $level = if ($systemInfo.SystemDriveFreePercent -lt 5) { 'critical' } else { 'warning' }
    Add-Finding $findings $level 'Free space' 'The Windows drive is nearly full' ("Only {0:N1} GB ({1:N1}%) is free on {2}." -f $systemInfo.SystemDriveFreeGB, $systemInfo.SystemDriveFreePercent, $systemInfo.SystemDrive) 'Free at least 15-20% of the Windows drive so updates, caches, and the page file have working room.'
}

if ($systemInfo.MemoryModules.Count -gt 1) {
    $capacityKinds = @($systemInfo.MemoryModules | ForEach-Object { $_.CapacityGB } | Sort-Object -Unique)
    $speedKinds = @($systemInfo.MemoryModules | ForEach-Object { $_.SpeedMHz } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    if ($capacityKinds.Count -gt 1 -or $speedKinds.Count -gt 1) {
        Add-Finding $findings 'info' 'RAM layout' 'The installed RAM modules are not identical' ("Modules: {0}. Mixed capacities or speeds can run partly outside dual-channel mode, but that alone rarely causes severe desktop lag." -f (($systemInfo.MemoryModules | ForEach-Object { "$($_.CapacityGB) GB at $($_.SpeedMHz) MHz" }) -join ', ')) 'Treat this as context, not a diagnosis. The memory-pressure finding above is stronger evidence.'
    }
}

$otherEvents = @($events | Where-Object { $_.Message -notmatch 'LiveKernelEvent.*P1:\s*(117|141)' })
if ($otherEvents.Count -gt 0) {
    $eventBrief = ($otherEvents | Select-Object -First 4 | ForEach-Object { "$($_.Provider) event $($_.Id)" }) -join ', '
    Add-Finding $findings 'warning' 'Hardware / drivers' 'Windows logged another relevant warning or error' ("Found $($otherEvents.Count) relevant event(s): $eventBrief.") 'Use the event table in this report. Repeated disk, WHEA, display, storage reset, app crash, or app hang events deserve targeted follow-up.'
}

$orderedFindings = @($findings | Sort-Object Rank -Descending)
$actionable = @($orderedFindings | Where-Object { $_.Level -in @('critical','warning') })
if ($actionable.Count -gt 0) {
    $headline = $actionable[0].Title
    $headlineDetail = "The strongest signal in this recording is $($actionable[0].Area.ToLower())."
}
else {
    $headline = 'No sustained bottleneck was captured'
    $headlineDetail = 'Run LagLens again while the computer is visibly lagging; intermittent problems require a recording that overlaps the symptom.'
}

$samples | Export-Csv -Path $samplesPath -NoTypeInformation -Encoding UTF8
$processSummary | Sort-Object AverageCpuPct -Descending | Export-Csv -Path $processPath -NoTypeInformation -Encoding UTF8
$systemInfo | ConvertTo-Json -Depth 6 | Set-Content -Path $systemPath -Encoding UTF8
try { if (Test-Path $liveSamplesPath) { Remove-Item -LiteralPath $liveSamplesPath -Force } } catch { }

$findingHtml = ($orderedFindings | ForEach-Object {
    $label = switch ($_.Level) { 'critical' { 'LIKELY BOTTLENECK' } 'warning' { 'CHECK THIS' } 'good' { 'LOOKS OK' } default { 'CONTEXT' } }
    "<article class='finding $($_.Level)'><div class='tag'>$label - $(ConvertTo-HtmlText $_.Area)</div><h3>$(ConvertTo-HtmlText $_.Title)</h3><p>$(ConvertTo-HtmlText $_.Evidence)</p><p class='next'><strong>Next:</strong> $(ConvertTo-HtmlText $_.NextStep)</p></article>"
}) -join "`n"

$processRows = ($processSummary | Sort-Object @{Expression={ [Math]::Max([Math]::Max($_.AverageCpuPct, $_.AverageGpuPct), $_.AverageIoMBps) }; Descending=$true} | Select-Object -First 15 | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlText $_.Process)</td><td>$($_.AverageCpuPct)%</td><td>$($_.PeakCpuPct)%</td><td>$($_.PeakMemoryMB)</td><td>$($_.AverageIoMBps)</td><td>$($_.PeakIoMBps)</td><td>$($_.AverageGpuPct)%</td></tr>"
}) -join "`n"
if ([string]::IsNullOrWhiteSpace($processRows)) { $processRows = "<tr><td colspan='7'>No process details were available.</td></tr>" }

$eventRows = ($events | Select-Object -First 20 | ForEach-Object {
    "<tr><td>$($_.Time.ToString('HH:mm:ss'))</td><td>$(ConvertTo-HtmlText $_.Provider)</td><td>$($_.Id)</td><td>$(ConvertTo-HtmlText $_.Message)</td></tr>"
}) -join "`n"
if ([string]::IsNullOrWhiteSpace($eventRows)) { $eventRows = "<tr><td colspan='4'>No relevant hardware, storage, display, resource exhaustion, app crash, or app hang events appeared during this recording.</td></tr>" }

$memoryModuleText = if ($systemInfo.MemoryModules.Count -gt 0) { ($systemInfo.MemoryModules | ForEach-Object { "$($_.CapacityGB) GB at $($_.SpeedMHz) MHz" }) -join '; ' } else { 'Module details unavailable without CIM access' }
$diskText = if ($systemInfo.PhysicalDisks.Count -gt 0) { ($systemInfo.PhysicalDisks | ForEach-Object { $extra = if ($_.TemperatureC -ge 0) { ", $($_.TemperatureC) C, wear $($_.WearPercent)%" } else { '' }; "$($_.FriendlyName) - $($_.MediaType), $($_.HealthStatus), $($_.SizeGB) GB$extra" }) -join '; ' } else { 'Drive model/health unavailable without Storage access' }
$gpuText = if ($systemInfo.VideoControllers.Count -gt 0) { ($systemInfo.VideoControllers | ForEach-Object { $dateText = if ($_.DriverDate) { ", $($_.DriverDate)" } else { '' }; "$($_.Name) (driver $($_.DriverVersion)$dateText)" }) -join '; ' } else { 'Graphics model unavailable without CIM or PnP access' }
$displayText = if ($systemInfo.Displays.Count -gt 0) { ($systemInfo.Displays | ForEach-Object { "$($_.Width)x$($_.Height)$(if($_.Primary){' primary'}else{''})" }) -join '; ' } else { 'Display details unavailable' }
$batteryText = if ($systemInfo.Battery.Present) { "$($systemInfo.Battery.HealthPercent)% health; $($systemInfo.Battery.FullChargeCapacityMWh) of $($systemInfo.Battery.DesignCapacityMWh) mWh; $($systemInfo.Battery.CycleCount) cycles" } else { 'Battery health report unavailable' }
$markerLogPath = Join-Path $OutputDirectory 'LagMarkers.csv'
$recordedSeconds = [Math]::Round(($sessionEnd - $sessionStart).TotalSeconds, 0)

$cpuChart = New-Sparkline $cpuValues '#7c5cff' 100
$memoryUsedValues = @($samples | ForEach-Object {
    if ($systemInfo.TotalMemoryGB -gt 0) { [Math]::Max(0, 100 - (($_.AvailableMemoryMB / ($systemInfo.TotalMemoryGB * 1024)) * 100)) } else { $_.CommittedMemoryPct }
})
$memoryChart = New-Sparkline $memoryUsedValues '#00a884' 100
$diskChart = New-Sparkline $diskActiveValues '#f59e0b' 100
$latencyChart = New-Sparkline $diskLatencyValues '#e34d59' 0
$gpuChart = New-Sparkline $gpuValues '#2b8cff' 100
$uiResponseChart = New-Sparkline @($samples | ForEach-Object { $_.ForegroundResponseMs }) '#d14ca5' 250
$driverLoadValues = @($samples | ForEach-Object { [double]$_.DpcPct + [double]$_.InterruptPct })
$driverChart = New-Sparkline $driverLoadValues '#875d2d' 20
$batteryChart = New-Sparkline $batteryChargeValues '#15803d' 100

$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LagLens report - $stamp</title>
<style>
:root{--ink:#172033;--muted:#657089;--line:#dfe4ee;--paper:#fff;--wash:#f5f7fb;--purple:#6f52ed;--critical:#c82f3e;--warning:#b46a00;--good:#087a60;--info:#42617e}*{box-sizing:border-box}body{margin:0;background:var(--wash);color:var(--ink);font:15px/1.55 "Segoe UI",Arial,sans-serif}.wrap{max-width:1120px;margin:auto;padding:28px}header{color:white;background:linear-gradient(125deg,#18233c,#4737a3);border-radius:20px;padding:30px 34px;box-shadow:0 16px 38px #1d255127}.eyebrow{font-size:12px;letter-spacing:.14em;text-transform:uppercase;opacity:.75}h1{font-size:36px;line-height:1.1;margin:9px 0}.lead{font-size:18px;max-width:800px;margin:0}.meta{margin-top:18px;color:#dce1ff}.panel{background:var(--paper);border:1px solid var(--line);border-radius:16px;padding:24px;margin-top:20px;box-shadow:0 5px 18px #25304f0b}h2{margin:0 0 15px;font-size:22px}h3{margin:6px 0 8px;font-size:18px}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}.metric{background:#f8f9fd;border:1px solid var(--line);border-radius:12px;padding:15px}.metric .value{font-size:26px;font-weight:700}.metric .label{color:var(--muted)}.findings{display:grid;gap:12px}.finding{border:1px solid var(--line);border-left:6px solid var(--info);border-radius:12px;padding:16px 18px}.finding.critical{border-left-color:var(--critical);background:#fff8f8}.finding.warning{border-left-color:var(--warning);background:#fffbf3}.finding.good{border-left-color:var(--good);background:#f6fffb}.tag{font-size:11px;letter-spacing:.08em;font-weight:700;color:var(--info)}.critical .tag{color:var(--critical)}.warning .tag{color:var(--warning)}.good .tag{color:var(--good)}.finding p{margin:6px 0}.next{color:#39445a}.charts{display:grid;grid-template-columns:1fr 1fr;gap:14px}.chart{border:1px solid var(--line);border-radius:12px;padding:15px;min-width:0}.chart h3{font-size:15px}.spark{width:100%;height:105px;background:linear-gradient(#fafbfe,#fff);border-radius:8px}.axis{stroke:#d7ddea;stroke-width:1}.chart-meta{color:var(--muted);font-size:13px}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{color:#4b5871;background:#f7f8fb;position:sticky;top:0}.table-wrap{overflow:auto;max-height:520px;border:1px solid var(--line);border-radius:10px}.facts{display:grid;grid-template-columns:180px 1fr;gap:7px 18px}.facts dt{font-weight:650}.facts dd{margin:0;color:#45516a}.files{font-family:Consolas,monospace;font-size:12px;color:#45516a;overflow-wrap:anywhere}.note{color:var(--muted);font-size:13px}.no-data{color:var(--muted);padding:25px}@media(max-width:760px){.grid,.charts{grid-template-columns:1fr}.facts{grid-template-columns:1fr}.facts dd{margin-bottom:8px}.wrap{padding:12px}header{padding:23px}h1{font-size:29px}}
</style>
</head>
<body><main class="wrap">
<header>
  <div class="eyebrow">LagLens diagnosis</div>
  <h1>$(ConvertTo-HtmlText $headline)</h1>
  <p class="lead">$(ConvertTo-HtmlText $headlineDetail)</p>
  <div class="meta">Recorded $recordedSeconds seconds | $($samples.Count) samples | $markerCount lag marker(s) | $($sessionStart.ToString('yyyy-MM-dd HH:mm:ss')) to $($sessionEnd.ToString('HH:mm:ss'))</div>
</header>

<section class="panel">
  <h2>At a glance</h2>
  <div class="grid">
    <div class="metric"><div class="value">$(Format-Number $foregroundResponseP95 0) ms</div><div class="label">Foreground app response, P95</div></div>
    <div class="metric"><div class="value">$(Format-Number $batteryHealth 0)%</div><div class="label">Battery capacity health</div></div>
    <div class="metric"><div class="value">$(Format-Number $cpuP95 0)%</div><div class="label">CPU, 95th percentile</div></div>
    <div class="metric"><div class="value">$(Format-Number $cpuCoreP95 0)%</div><div class="label">Busiest logical CPU, P95</div></div>
    <div class="metric"><div class="value">$(Format-Number ($availableMinMB/1024) 1) GB</div><div class="label">Lowest available RAM</div></div>
    <div class="metric"><div class="value">$(Format-Number $diskLatencyP95 0) ms</div><div class="label">Disk latency, 95th percentile</div></div>
    <div class="metric"><div class="value">$(Format-Number $gpuP95 0)%</div><div class="label">GPU, 95th percentile</div></div>
    <div class="metric"><div class="value">$(Format-Number ($dpcP95 + $interruptP95) 1)%</div><div class="label">Driver interrupt load, P95</div></div>
    <div class="metric"><div class="value">$markerCount</div><div class="label">Marked slow moments</div></div>
  </div>
</section>

<section class="panel"><h2>What LagLens found</h2><div class="findings">$findingHtml</div></section>

<section class="panel">
  <h2>Timeline</h2>
  <p class="note">A 95th percentile ignores the noisiest 5% of readings; it is usually more useful than a single peak.</p>
  <div class="charts">
    <div class="chart"><h3>CPU usage</h3>$cpuChart<div class="chart-meta">Average $(Format-Number $cpuAverage 0)% | P95 $(Format-Number $cpuP95 0)% | Peak $(Format-Number $cpuPeak 0)%</div></div>
    <div class="chart"><h3>RAM in use</h3>$memoryChart<div class="chart-meta">Minimum available $(Format-Number ($availableMinMB/1024) 1) GB | Commit P95 $(Format-Number $committedP95 0)%</div></div>
    <div class="chart"><h3>Busiest disk activity</h3>$diskChart<div class="chart-meta">Average $(Format-Number $diskAverage 0)% | P95 $(Format-Number $diskP95 0)% | Peak $(Format-Number $diskPeak 0)%</div></div>
    <div class="chart"><h3>Worst disk latency</h3>$latencyChart<div class="chart-meta">P95 $(Format-Number $diskLatencyP95 0) ms | Queue P95 $(Format-Number $diskQueueP95 1)</div></div>
    <div class="chart"><h3>GPU usage</h3>$gpuChart<div class="chart-meta">P95 $(Format-Number $gpuP95 0)% | Peak $(Format-Number $gpuPeak 0)%</div></div>
    <div class="chart"><h3>Foreground app response time</h3>$uiResponseChart<div class="chart-meta">P95 $(Format-Number $foregroundResponseP95 1) ms | Peak $(Format-Number $foregroundResponsePeak 1) ms | Timeouts $foregroundHungCount</div></div>
    <div class="chart"><h3>Driver DPC + interrupt time</h3>$driverChart<div class="chart-meta">DPC P95 $(Format-Number $dpcP95 1)% | Interrupt P95 $(Format-Number $interruptP95 1)%</div></div>
    <div class="chart"><h3>Battery charge</h3>$batteryChart<div class="chart-meta">Health $(Format-Number $batteryHealth 1)% | Unplugged samples $($batterySamples.Count)</div></div>
  </div>
</section>

<section class="panel">
  <h2>Mark a slow moment</h2>
  <p>Press <strong>Ctrl+Alt+L</strong> while an app is visibly slow. LagLens records the active process name and power state, switches the system recorder to two-second sampling, and starts a separate one-second interactive UI burst for two minutes. It does not record the window title, input content, or which keys and buttons you used.</p>
</section>

<section class="panel">
  <h2>Processes seen during the recording</h2>
  <p class="note">CPU and GPU percentages are shares of the whole machine. I/O is file and device transfer attributed by Windows.</p>
  <div class="table-wrap"><table><thead><tr><th>Process</th><th>CPU avg</th><th>CPU peak</th><th>RAM peak MB</th><th>I/O avg MB/s</th><th>I/O peak MB/s</th><th>GPU avg</th></tr></thead><tbody>$processRows</tbody></table></div>
</section>

<section class="panel">
  <h2>Windows events during the recording</h2>
  <div class="table-wrap"><table><thead><tr><th>Time</th><th>Source</th><th>ID</th><th>Message</th></tr></thead><tbody>$eventRows</tbody></table></div>
</section>

<section class="panel">
  <h2>Computer context</h2>
  <dl class="facts">
    <dt>Computer</dt><dd>$(ConvertTo-HtmlText ("$($systemInfo.Manufacturer) $($systemInfo.Model)".Trim()))</dd>
    <dt>Windows</dt><dd>$(ConvertTo-HtmlText $systemInfo.OS), build $(ConvertTo-HtmlText $systemInfo.OSBuild)</dd>
    <dt>Processor</dt><dd>$(ConvertTo-HtmlText $systemInfo.Processor) | $($systemInfo.LogicalProcessors) logical threads</dd>
    <dt>RAM</dt><dd>$($systemInfo.TotalMemoryGB) GB | $(ConvertTo-HtmlText $memoryModuleText)</dd>
    <dt>Graphics</dt><dd>$(ConvertTo-HtmlText $gpuText)</dd>
    <dt>Displays</dt><dd>$(ConvertTo-HtmlText $displayText)</dd>
    <dt>Battery</dt><dd>$(ConvertTo-HtmlText $batteryText)</dd>
    <dt>Storage</dt><dd>$(ConvertTo-HtmlText $diskText)</dd>
    <dt>Windows drive</dt><dd>$($systemInfo.SystemDriveFreeGB) GB free of $($systemInfo.SystemDriveSizeGB) GB ($($systemInfo.SystemDriveFreePercent)%)</dd>
    <dt>Power plan</dt><dd>$(ConvertTo-HtmlText $systemInfo.ActivePowerPlan)</dd>
    <dt>Startup items</dt><dd>$($systemInfo.StartupItemCount) standard Run-key/startup-folder entries</dd>
    <dt>Uptime</dt><dd>$($systemInfo.UptimeDays) days (0 means the value was unavailable)</dd>
  </dl>
</section>

<section class="panel">
  <h2>Evidence files</h2>
  <p>These let a technical helper inspect the exact readings without rerunning the test.</p>
  <div class="files">Samples: $(ConvertTo-HtmlText $samplesPath)<br>Processes: $(ConvertTo-HtmlText $processPath)<br>System: $(ConvertTo-HtmlText $systemPath)<br>Battery capacity history: $(ConvertTo-HtmlText $batteryHistoryPath)<br>Lag markers: $(ConvertTo-HtmlText $markerLogPath)</div>
  <p class="note">Privacy: LagLens works locally and makes no network requests. It records performance counters, battery/charger state, hardware summary, Windows event excerpts, foreground process names, and app response timing - not window titles, input content, document names, keystrokes, mouse coordinates, browser history, SSIDs, or file contents.</p>
</section>
</main></body></html>
"@

$html | Set-Content -Path $reportPath -Encoding UTF8

foreach ($counter in $counters.Values) { if ($null -ne $counter) { try { $counter.Dispose() } catch { } } }
foreach ($set in $diskCounters) {
    foreach ($counter in @($set.Active, $set.Queue, $set.Latency, $set.Bytes)) { if ($null -ne $counter) { try { $counter.Dispose() } catch { } } }
}
foreach ($counter in $script:GpuCounters.Values) { try { $counter.Dispose() } catch { } }

if (-not $Quiet) {
    Write-Host "`nReport created:" -ForegroundColor Green
    Write-Host $reportPath -ForegroundColor White
    Write-Host "`nStrongest result: $headline" -ForegroundColor Yellow
}
if (-not $NoOpen) {
    try { Start-Process $reportPath } catch { }
}
