@echo off
rem Discord Quest Mirror - double-click launcher for the Windows release zip.
rem Runs the mirror.ps1 sitting next to this file. -ExecutionPolicy Bypass
rem applies to this one process only - it doesn't change any system setting.
title Discord Quest Mirror
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0mirror.ps1" %*
if errorlevel 1 pause
