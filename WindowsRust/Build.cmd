@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-windows.ps1"
set RESULT=%ERRORLEVEL%
echo.
if not "%RESULT%"=="0" echo BUILD FAILED. Read build.log and docs\BUILD.md.
if "%RESULT%"=="0" echo BUILD FINISHED. Open dist\Lens-Windows\Lens.exe.
pause
exit /b %RESULT%
