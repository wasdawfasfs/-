@echo off
rem V04 F136: use files relative to this package.
set PYTHONDONTWRITEBYTECODE=1

cd /d "%~dp0.."

"%~dp0..\runtime\python.exe" -I "%~dp0..\scripts\hdmi_full_range.py" --set-full
if errorlevel 1 echo HDMI full-range check failed. Check NVIDIA output settings.
"%~dp0..\runtime\python.exe" -I "%~dp0..\launch_camera.py" --entry gamma --mode Camera --autostart

if errorlevel 1 pause

