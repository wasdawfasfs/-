@echo off
rem V04 F136: use files relative to this package.
set PYTHONDONTWRITEBYTECODE=1

cd /d "%~dp0.."

explorer "%~dp0..\fpga_project\generate_bitstream"

if errorlevel 1 pause

