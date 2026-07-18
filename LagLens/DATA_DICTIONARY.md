# LagLens data dictionary

Empty fields, `-1`, or zero where zero is not physically meaningful usually mean that Windows or the laptop firmware did not expose the sensor to this session.

## App and desktop responsiveness

- `ForegroundProcess`: executable/process name for the active window. Window titles are never collected.
- `ForegroundResponseMs`: time for the active window to answer a harmless `WM_NULL` message.
- `ForegroundHung`: the active window did not answer within 250 ms.
- `WorstVisibleAppResponseMs`, `SlowVisibleApps`, `HungVisibleApps`: periodic survey of up to 20 visible app windows; only process names are stored.
- `DwmConfiguredRefreshHz`: desktop compositor's configured refresh rate.
- `DwmObservedRefreshFps`: displayed desktop refreshes during the sample interval.
- `DwmComposedFps`: frames composed by DWM; low values can be normal when the desktop is visually idle.
- `DwmFramesMissed`, `DwmFramesDropped`: compositor timing misses during the interval.
- `LagMarker`, `MarkerTimestamp`: a Ctrl+Alt+L marker was detected.
- `CaptureMode`: `Normal` uses the configured interval; `Burst` samples every two seconds for two minutes after a marker or a severe foreground-window delay.
- `LagLens-*-ui-burst.csv`: a separate one-second, two-minute trace started by Ctrl+Alt+L in the interactive desktop session.
- `LagLens-*-ui-continuous.csv`: the automatic interactive trace. It samples every second on AC and every two seconds on battery, so useful app/desktop evidence does not depend on remembering the marker hotkey.
- `CaptureMode`: `Marker` for a user-marked close-up or `Continuous` for the automatic UI sentinel.
- `RequestedIntervalMs`, `SampleIntervalMs`, `RecorderDelayMs`: requested cadence, actual time between samples, and excess delay. A large recorder delay can expose a whole-system scheduling freeze even when resource averages look normal.
- `ForegroundResponding`, `ForegroundPrivateMemoryMB`, `ForegroundThreadCount`, `ForegroundHandleCount`: additional foreground-process state without recording window titles or content.
- `ProcessorQueueLength`, `ContextSwitchesPerSec`, `DpcTimePct`, `InterruptTimePct`, `PageReadsPerSec`, `DiskLatencyMs`: one/two-second resource and driver-pressure context around a UI stall.
- `AutoStallDetected`, `AutoStallReasons`: automatic labels for foreground hangs, 100 ms message delays, 750 ms recorder delays, compositor misses/drops, low compositor FPS during input, high DPC time, or 100 ms storage transfers. These labels are leads, not proof of a root cause.
- `InputOccurredSincePriorSample`, `MillisecondsSinceLastInput`: timing-only activity indicators in the interactive burst. They do not reveal the key, button, mouse position, or input contents.

## Driver and scheduling pressure

- `DpcPct`, `InterruptPct`: CPU time spent servicing deferred procedure calls and hardware interrupts. Sustained high values can indicate a graphics, Wi-Fi, audio, USB/input, or storage driver problem.
- `DpcRate`, `InterruptsPerSec`: activity counts; these require correlation and are not bad by themselves.
- `ContextSwitchesPerSec`: scheduling churn between threads/processes.
- `CpuUserPct`, `CpuPrivilegedPct`: user-mode versus Windows/kernel-mode CPU work.
- `CpuUtilityPct`: frequency-adjusted processor utilization.
- `MaxLogicalCpuPct`, `BusyLogicalCpuCount`: busiest logical CPU and the number at or above 90%; these expose single-thread bottlenecks hidden by a moderate whole-machine average.
- `AttributedProcessCpuPct`, `CpuAttributionGapPct`: total CPU attributed to polled processes and the remaining timing gap. A recurring gap helps distinguish a true process leader from kernel work or sampling mismatch.
- `ActualFrequencyMHz`, `ProcessorPerformancePct`, `ProcessorPerformanceLimitPct`: Windows' dynamic clock/performance readings used for power or heat throttling checks.
- `ProcessorFrequencyMHz`, `MaxFrequencyPct`: older nominal-frequency counters retained for compatibility; on some Intel systems they stay fixed and should not be treated as the actual live clock.
- `SystemProcessCount`, `SystemThreadCount`: scheduler population from Windows performance counters.

## Battery and power

- `PowerSource`: `AC`, `Battery`, or `Unknown`.
- `BatteryChargePct`, `BatteryEstimatedRemainingSeconds`, `BatteryChargeFlags`: Windows power-status readings.
- `BatteryDischargeRateMW`, `BatteryChargeRateMW`, `BatteryRemainingCapacityMWh`, `BatteryVoltageMV`: firmware/WMI readings when exposed.
- `BrightnessPct`: internal-panel brightness when exposed.
- `ThermalZoneC`: firmware ACPI thermal-zone value when exposed; it may not be the CPU package temperature.
- `LagLens-latest-system.json` stores design capacity, current full-charge capacity, calculated health percentage, and cycle count from Windows' battery report.
- `BatteryHealthHistory.csv` preserves each two-hour capacity estimate rather than trusting one firmware snapshot. Capacity estimates can change after charging or firmware recalibration; a repeated value is stronger evidence than a single reading.

## Network and Wi-Fi

- `WifiSignalPct`, `WifiReceiveLinkMbps`, `WifiTransmitLinkMbps`, `WifiRadioType`: local Wi-Fi link properties. SSID/network name is deliberately not stored.
- LagLens makes no pings or other network requests. If later evidence suggests network latency, a targeted opt-in test can be added.

## Existing resource fields

CPU, memory availability/commit/page reads, per-disk activity/queue/latency, GPU-engine use, process count, and top process groups are recorded alongside the responsiveness and battery fields so the same moment can be correlated.

Relevant Application Error, Application Hang, Windows Error Reporting, storage, WHEA, and display-driver events are included in completed reports. Live-kernel reliability events are checked across the prior 30 days because Windows may process a GPU watchdog report after the visible freeze that created it.

## Privacy boundary

LagLens does not collect input contents, key identities, mouse coordinates, screenshots, window titles, document/file names, URLs, browser history, SSIDs, or file contents.
