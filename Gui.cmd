@echo off
setlocal
set "HKU_DEMO="
if /I "%~1"=="--demo" set "HKU_DEMO=-Demo"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Gui.ps1" %HKU_DEMO%
if errorlevel 1 pause
