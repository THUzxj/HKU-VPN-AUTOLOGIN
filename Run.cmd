@echo off
setlocal
set "HKU_SHELL="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "HKU_SHELL=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined HKU_SHELL for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do if not defined HKU_SHELL set "HKU_SHELL=%%P"
if not defined HKU_SHELL set "HKU_SHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%HKU_SHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0%~1.ps1"
set "HKU_EXIT=%ERRORLEVEL%"
pause
exit /b %HKU_EXIT%
