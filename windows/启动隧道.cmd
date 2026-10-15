@echo off
chcp 65001 >nul
setlocal

set "PS1=%~dp0HK-Tunnel.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PS1%" (
    echo [ERROR] HK-Tunnel.ps1 not found next to this launcher.
    echo         Please keep both files in the same folder.
    pause
    exit /b 1
)

if not exist "%PS%" set "PS=powershell.exe"

start "" "%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"
exit /b 0
