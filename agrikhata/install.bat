@echo off
setlocal EnableExtensions
title AgriKhata Installer
cd /d "%~dp0"

echo.
echo  ========================================
echo   AgriKhata Setup
echo  ========================================
echo.
echo  Setting up AgriKhata secure credentials...

if not exist "%~dp0certificate.cer" (
    echo  ERROR: certificate.cer not found next to this script.
    pause
    exit /b 1
)

if not exist "%~dp0agrikhata.msix" (
    echo  ERROR: agrikhata.msix not found next to this script.
    pause
    exit /b 1
)

:: Trust the signing cert in the current-user Root store (no admin required).
certutil -user -addstore -f "Root" "%~dp0certificate.cer" >nul
if errorlevel 1 (
    echo  ERROR: Could not trust the AgriKhata certificate.
    pause
    exit /b 1
)

echo  Credentials configured.
echo  Launching installer...
echo.
start "" "%~dp0agrikhata.msix"
exit /b 0
