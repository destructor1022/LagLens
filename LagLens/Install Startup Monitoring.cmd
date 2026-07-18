@echo off
setlocal
title Install LagLens startup monitoring
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Configure Startup Monitoring.ps1" -StartNow
echo.
pause
endlocal

