@echo off
chcp 65001 >nul
echo AI Quota Tray - install
choice /c YN /m "Also start automatically when Windows starts"
if errorlevel 2 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Startup
)
echo.
pause
