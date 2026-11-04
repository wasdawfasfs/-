@echo off
rem V04 F136: use files relative to this package.
set PYTHONDONTWRITEBYTECODE=1

cd /d "%~dp0.."

"%~dp0..\runtime\python.exe" -I "%~dp0..\scripts\download_v04.py"

if errorlevel 1 pause

