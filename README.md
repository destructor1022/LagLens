# LagLens

LagLens is a privacy-conscious Windows responsiveness and battery diagnostic recorder. It samples local performance counters, records process names and relevant Windows reliability events, and produces local CSV/HTML reports for later analysis.

## Repository layout

- `LagLens/` — recorder, background monitor, interactive lag marker, documentation, and analysis notes.
- `REMOVE_LAGLENS.ps1` and related files — complete local removal kit. These intentionally live outside `LagLens/` so they remain available when the installed folder is deleted.

## Privacy

The generated `LagLens/Reports/` directory and transient request files are excluded from Git. They can contain machine-specific performance and battery telemetry and should remain local.

See `LagLens/README.md` for usage, startup monitoring, collected fields, and the Ctrl+Alt+L lag marker.
