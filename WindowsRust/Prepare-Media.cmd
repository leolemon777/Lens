@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\prepare-media.ps1"
set RESULT=%ERRORLEVEL%
echo.
if "%RESULT%"=="0" echo Media tools are ready. Run Build.cmd next.
pause
exit /b %RESULT%
