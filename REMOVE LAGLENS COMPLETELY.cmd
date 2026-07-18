@echo off
setlocal
title Remove LagLens completely
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0REMOVE_LAGLENS.ps1"
echo.
pause
endlocal

