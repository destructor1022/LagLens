# LagLens removal instructions

This file intentionally lives **outside** the `LagLens` folder so it remains available when cleanup is needed.

## Easy removal

Double-click **REMOVE LAGLENS COMPLETELY.cmd**, then type `REMOVE` when prompted.

The removal tool will:

1. Signal the active background recorder and continuous UI sentinel to stop and wait for confirmation.
2. Unregister the `LagLens Background Monitor` scheduled task, remove any fallback Startup shortcut, and remove `Mark Lag Now.lnk` from the desktop.
3. Permanently delete the `outputs\LagLens` folder, including every HTML, CSV, JSON, status, and live diagnostic log.
4. Leave `outputs\LagLens-removal-receipt.txt` confirming exactly what was removed.

It is deliberately restricted to a direct child folder named `LagLens` beside the removal script. It will refuse to run if the expected `outputs\LagLens` layout is not present. It does not target any other output or Codex files.

## Asking Codex to remove it

Say: **"We are done troubleshooting; remove LagLens completely using the removal kit."**

Codex should:

1. Read this file and `LAGLENS_REMOVAL_MANIFEST.json`.
2. Request write access to the Startup folder if the sandbox requires it.
3. Optionally dry-run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\REMOVE_LAGLENS.ps1" -WhatIf
   ```

4. Run the actual removal without an interactive prompt:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\REMOVE_LAGLENS.ps1" -Force
   ```

5. Verify that the scheduled task, fallback Startup shortcut, and `outputs\LagLens` no longer exist, and report the receipt location.

## Manual fallback

If the automated remover cannot stop the monitor, sign out of Windows, sign back in, immediately run **Disable Startup Monitoring.cmd** from the LagLens folder, wait about 15 seconds, and then delete only the `outputs\LagLens` folder. Delete the Startup shortcut manually if it remains:

`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\LagLens Background Monitor.lnk`
