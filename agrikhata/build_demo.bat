@echo off
setlocal EnableExtensions
title AgriKhata Demo Build

cd /d "%~dp0"

set "RELEASE_DIR=%~dp0build\windows\x64\runner\Release"
set "INSTALL_SCRIPT=%~dp0install.bat"
set "CERT_CER=%~dp0windows\signing\certificate.cer"

echo.
echo  ========================================
echo   AgriKhata Demo Release Builder
echo  ========================================
echo.

:: ---------------------------------------------------------------
:: 1) Native Windows release build
:: ---------------------------------------------------------------
echo  [1/4] Building Windows release...
call flutter build windows --release
if errorlevel 1 (
    echo  ERROR: flutter build windows --release failed.
    exit /b 1
)
echo  Build complete.
echo.

:: ---------------------------------------------------------------
:: 2) Package MSIX (uses msix_config in pubspec.yaml)
:: ---------------------------------------------------------------
echo  [2/4] Creating MSIX package...
call flutter pub run msix:create
if errorlevel 1 (
    echo  ERROR: msix:create failed.
    exit /b 1
)
echo  MSIX package created.
echo.

if not exist "%RELEASE_DIR%\agrikhata.msix" (
    echo  ERROR: Expected package not found:
    echo         %RELEASE_DIR%\agrikhata.msix
    exit /b 1
)

:: ---------------------------------------------------------------
:: 3) Copy signing certificate (.cer) beside the installer
:: ---------------------------------------------------------------
echo  [3/4] Copying certificate.cer into release folder...
if not exist "%CERT_CER%" (
    echo  ERROR: Signing certificate missing:
    echo         %CERT_CER%
    exit /b 1
)
copy /Y "%CERT_CER%" "%RELEASE_DIR%\certificate.cer" >nul
if errorlevel 1 (
    echo  ERROR: Failed to copy certificate.cer
    exit /b 1
)
echo.

:: ---------------------------------------------------------------
:: 4) Copy 1-click installer helper into the release folder
:: ---------------------------------------------------------------
echo  [4/4] Copying install.bat into release folder...
if not exist "%INSTALL_SCRIPT%" (
    echo  ERROR: Source script missing: %INSTALL_SCRIPT%
    exit /b 1
)
copy /Y "%INSTALL_SCRIPT%" "%RELEASE_DIR%\install.bat" >nul
if errorlevel 1 (
    echo  ERROR: Failed to copy install.bat
    exit /b 1
)

echo.
echo  ========================================
echo   Demo package ready
echo  ========================================
echo.
echo  Release folder:
echo    %RELEASE_DIR%
echo.
echo  Shopkeeper files:
echo    agrikhata.msix
echo    certificate.cer
echo    install.bat   ^<-- double-click this
echo.
exit /b 0
