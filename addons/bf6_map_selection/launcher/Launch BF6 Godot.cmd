@echo off
setlocal DisableDelayedExpansion
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_bf6_godot.ps1" -CreateShortcut %*
if errorlevel 1 pause
