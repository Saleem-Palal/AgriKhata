@echo off
setlocal EnableExtensions
title AgriKhata Installer

:: ---------------------------------------------------------------
:: Admin elevation is required for Local Machine certificate trust.
:: MSIX rejects Current-User-only roots with 0x800B0109.
:: ---------------------------------------------------------------
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
    exit /b
)

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

:: Install into Local Machine stores (required for MSIX trust).
certutil -addstore -f "Root" "%~dp0certificate.cer" >nul
if errorlevel 1 (
    echo  ERROR: Could not add certificate to Trusted Root.
    pause
    exit /b 1
)

certutil -addstore -f "TrustedPeople" "%~dp0certificate.cer" >nul
if errorlevel 1 (
    echo  ERROR: Could not add certificate to Trusted People.
    pause
    exit /b 1
)

echo  Credentials configured.
echo  Launching installer...
echo.
start "" "%~dp0agrikhata.msix"
exit /b 0
