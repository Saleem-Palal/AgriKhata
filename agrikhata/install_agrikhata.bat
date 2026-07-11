@echo off
setlocal EnableExtensions
title AgriKhata Installer

:: ---------------------------------------------------------------
:: Elevate to Administrator (UAC) if not already elevated
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
echo  Configuring AgriKhata security permissions...

if not exist "%~dp0agrikhata.cer" (
    echo  ERROR: Certificate file not found:
    echo         %~dp0agrikhata.cer
    echo  Please re-download the full release package.
    pause
    exit /b 1
)

if not exist "%~dp0agrikhata.msix" (
    echo  ERROR: Installer package not found:
    echo         %~dp0agrikhata.msix
    echo  Please re-download the full release package.
    pause
    exit /b 1
)

certutil -addstore -f "Root" "%~dp0agrikhata.cer" >nul
if errorlevel 1 (
    echo  ERROR: Could not install the security certificate.
    echo  Please try again or contact support.
    pause
    exit /b 1
)

echo  Done! Launching installer setup now.
echo.
start "" "%~dp0agrikhata.msix"
exit /b 0
