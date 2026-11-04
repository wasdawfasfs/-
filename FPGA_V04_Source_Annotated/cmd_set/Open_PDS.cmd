@echo off
rem V04 F136: use files relative to this package.
set PYTHONDONTWRITEBYTECODE=1

cd /d "%~dp0.."

if defined PANGO_PDS_BIN (start "" "%PANGO_PDS_BIN%\pds.exe" "%~dp0..\fpga_project\v04_source.pds") else (start "" "D:\pango\PDS_2022.2-SP6.1\bin\pds.exe" "%~dp0..\fpga_project\v04_source.pds")

if errorlevel 1 pause

