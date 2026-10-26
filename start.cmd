@echo off
title TENANGIN - Start All
REM Nyalakan MySQL (XAMPP) bila belum jalan
tasklist | find /i "mysqld.exe" >nul
if errorlevel 1 (
    echo Starting MySQL...
    start "MySQL" /min C:\xampp\mysql\bin\mysqld.exe --defaults-file=C:\xampp\mysql\bin\my.ini --standalone
    timeout /t 6 /nobreak >nul
)
REM FastAPI + Laravel + Queue + Vite
cd /d "%~dp0apps\api-ai"
call start.cmd
