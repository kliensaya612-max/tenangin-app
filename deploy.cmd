@echo off
REM Deploy Tenangin ke VPS dari Windows dengan satu perintah.
REM Pemakaian:  deploy.cmd root@IP_VPS [domain] [email]
REM Contoh   :  deploy.cmd root@103.10.20.30 tenangin.contoh.com saya@contoh.com
REM Syarat   : OpenSSH client (bawaan Windows 10/11) + git. Kode harus sudah di-commit.
setlocal
if "%~1"=="" (
    echo Pemakaian: deploy.cmd user@ip_vps [domain] [email]
    exit /b 1
)
set TARGET=%~1
set DOMAIN=%~2
set EMAIL=%~3
set REMOTE_DIR=/var/www/tenangin

cd /d "%~dp0"
echo [1/3] Membuat arsip dari commit terakhir...
git archive --format=tar.gz -o "%TEMP%\tenangin.tar.gz" HEAD || exit /b 1

echo [2/3] Upload ke %TARGET%...
ssh %TARGET% "mkdir -p %REMOTE_DIR%" || exit /b 1
scp "%TEMP%\tenangin.tar.gz" %TARGET%:/tmp/tenangin.tar.gz || exit /b 1

echo [3/3] Install / update di server...
ssh %TARGET% "tar -xzf /tmp/tenangin.tar.gz -C %REMOTE_DIR% && rm /tmp/tenangin.tar.gz && DOMAIN='%DOMAIN%' EMAIL='%EMAIL%' bash %REMOTE_DIR%/deploy/install.sh" || exit /b 1

echo Selesai.
endlocal
