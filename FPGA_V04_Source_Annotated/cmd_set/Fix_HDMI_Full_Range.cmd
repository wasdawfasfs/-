@echo off
rem V04 F136: use files relative to this package.
set PYTHONDONTWRITEBYTECODE=1
cd /d "%~dp0.."
"%~dp0..\runtime\python.exe" -I "%~dp0..\scripts\hdmi_full_range.py" --set-full
if errorlevel 1 pause
