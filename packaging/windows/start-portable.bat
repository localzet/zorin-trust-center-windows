@echo off
setlocal

set "ARCH=amd64"
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=arm64"

set "ROOT=%~dp0\..\.."
set "PORTABLE_DIR=%ROOT%\portable"
set "PORTABLE_EXE=%PORTABLE_DIR%\ZorinTrustPortable-windows-%ARCH%.exe"
set "PROOF=%PORTABLE_DIR%\owner-proof.json"

if not exist "%PORTABLE_EXE%" (
    echo Portable executable is missing: %PORTABLE_EXE%
    exit /b 2
)

cd /d "%PORTABLE_DIR%"
echo Zorin Trust Portable 0.10
echo.
echo Keep this window open while the temporary workstation is in use.
echo Windows Firewall may ask whether to allow private-network access.
echo.
"%PORTABLE_EXE%" portable --proof-out "%PROOF%"

set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Portable session exited with code %RC%.
pause
exit /b %RC%
