@echo off
setlocal
title LagLens - Windows slowdown recorder
color 0B

echo.
echo  LagLens records what the computer is doing while it feels slow.
echo  It does not need administrator access and does not upload anything.
echo.

if not "%~1"=="" goto direct
set "minutes=5"
set /p "minutes=How many minutes should it record? [5]: "
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0LagLens.ps1" -DurationMinutes "%minutes%"
goto done

:direct
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0LagLens.ps1" %*

:done
if errorlevel 1 (
  echo.
  echo LagLens stopped with an error. Leave this window open and share the message.
  pause
)
endlocal

