@echo off
setlocal
title Disable LagLens startup monitoring
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Configure Startup Monitoring.ps1" -Remove
echo.
pause
endlocal

