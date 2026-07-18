# LagLens

LagLens is a small, local Windows slowdown recorder. It watches the computer while the lag is actually happening and creates a plain-English HTML report.

## Run it

1. Double-click **Run LagLens.cmd**.
2. Press Enter for the standard 5-minute recording, or type a different number of minutes.
3. Use the computer normally and reproduce the slow thing. Press **S** if you capture it early.
4. The report opens automatically. Reports and supporting CSV files are saved in the **Reports** folder beside the script.

A longer 15–30 minute recording is useful for intermittent lag. A 2–5 minute recording is enough when the slowdown is easy to reproduce.

## What it checks

- Sustained CPU load, per-logical-CPU saturation, and processor backlog
- Dynamic CPU frequency/performance under load, which can suggest power or heat throttling
- Available RAM, commit pressure, and physical page-file reads
- Per-disk activity, queue depth, transfer latency, and top I/O processes
- GPU saturation when Windows exposes GPU Engine counters
- Foreground app message-response time without recording window titles
- DWM compositor refresh, missed frames, and dropped frames
- Driver DPC/interrupt pressure and context-switching load
- Top processes by CPU, memory, disk I/O, and GPU usage
- Battery design/full-charge capacity, cycle count, charger state, charge level, discharge rate, brightness, and thermal data when exposed
- Wi-Fi signal and link rate without recording the network name
- Low free space, power plan, RAM-module layout, and basic hardware details
- Storage, display-driver, WHEA, resource-exhaustion, crash, and app-hang events during the recording
- Live-kernel reliability history over 30 days, including intermittent GPU watchdog failures

## Privacy and safety

LagLens makes no network requests and changes no Windows settings. It records performance counters, process names, hardware summary, and short excerpts from relevant Windows events. It does **not** record keystrokes, document names, browser history, screenshots, or file contents.

LagLens does not replace a drive manufacturer's health test or a repair technician. Back up important files before troubleshooting if the report shows repeated disk errors, WHEA hardware errors, or severe storage latency.

See **DATA_DICTIONARY.md** for the meaning and privacy boundary of every added responsiveness, driver, battery, compositor, and Wi-Fi field.

## Optional command-line use

From PowerShell:

```powershell
& '.\LagLens.ps1' -DurationMinutes 15 -IntervalSeconds 2
```

Add `-NoOpen` if you do not want the finished report to open automatically.

## Automatic background monitoring

Double-click **Install Startup Monitoring.cmd** to make LagLens start quietly whenever you sign in. The background mode:

- samples every 15 seconds to keep overhead low on an older computer;
- saves a full report every two hours;
- continuously checkpoints a `-live.csv` file, so a shutdown does not erase the current session;
- records the top CPU, memory, I/O, and GPU processes with each sample; and
- automatically deletes diagnostic files older than 30 days.

The current state is written to `Reports\LagLens-background-status.txt`. Double-click **Disable Startup Monitoring.cmd** to remove the startup entry and stop the active monitor.

Press **Ctrl+Alt+L** or double-click the desktop **Mark Lag Now** shortcut while an app or Windows feels slow. The marker records only the timestamp, foreground process name, and power state. The background recorder switches from 15-second sampling to two-second sampling, and an interactive companion records app response and compositor timing once per second for two minutes. It stores only process names and input timing—not window titles, keys, buttons, mouse positions, or input contents.

When troubleshooting is finished, use the removal kit one folder above LagLens: `LAGLENS_REMOVAL_INSTRUCTIONS.md` and `REMOVE LAGLENS COMPLETELY.cmd`. The complete remover stops the monitor, removes the Startup shortcut, deletes all LagLens logs and files, and leaves a receipt without touching other outputs.

The normal **Run LagLens.cmd** mode remains the better close-up test because it samples every two seconds. Use that after the background logs identify a likely time or component.

## Asking Codex to analyze it later

Keep this LagLens folder in place. Later, ask: **"Analyze my LagLens logs and improve the recorder if the cause is still unclear."** Codex can read the HTML, CSV, JSON, and status files in the `Reports` folder, correlate slow periods with process leaders, and adjust the thresholds or add a more targeted counter for the next recording.
