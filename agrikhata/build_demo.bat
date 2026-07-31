@echo off
setlocal EnableExtensions
title AgriKhata Demo Build

cd /d "%~dp0"

set "RELEASE_DIR=%~dp0build\windows\x64\runner\Release"
set "INSTALL_SCRIPT=%~dp0install.bat"
set "CERT_CER=%~dp0windows\signing\certificate.cer"
set "ROOT_VERSION_JSON=%~dp0..\version.json"
set "ASSET_VERSION_JSON=%~dp0assets\version.json"

echo.
echo  ========================================
echo   AgriKhata Demo Release Builder
echo  ========================================
echo.

:: Keep bundled asset in sync with repo-root version.json (GitHub source).
if exist "%ROOT_VERSION_JSON%" (
    echo  Syncing assets\version.json from repo root...
    if not exist "%~dp0assets" mkdir "%~dp0assets"
    copy /Y "%ROOT_VERSION_JSON%" "%ASSET_VERSION_JSON%" >nul
)
echo.

:: ---------------------------------------------------------------
:: Google OAuth Client ID (optional env → dart-define; never commit secrets)
::   set GOOGLE_CLIENT_ID=xxxx.apps.googleusercontent.com
:: Production MSIX:
::   flutter pub run msix:create --dart-define=GOOGLE_CLIENT_ID="<CLIENT_ID>"
:: ---------------------------------------------------------------
set "DART_DEFINES="
if defined GOOGLE_CLIENT_ID (
    set "DART_DEFINES=--dart-define=GOOGLE_CLIENT_ID=%GOOGLE_CLIENT_ID%"
    echo  Using GOOGLE_CLIENT_ID from environment for this build.
) else (
    echo  WARNING: GOOGLE_CLIENT_ID is not set.
    echo           Drive backup will rely on Settings at runtime, or rebuild with:
    echo           flutter pub run msix:create --dart-define=GOOGLE_CLIENT_ID^="<CLIENT_ID>"
)
if defined GOOGLE_CLIENT_SECRET (
    set "DART_DEFINES=%DART_DEFINES% --dart-define=GOOGLE_CLIENT_SECRET=%GOOGLE_CLIENT_SECRET%"
)
echo.

:: ---------------------------------------------------------------
:: 1) Native Windows release build
:: ---------------------------------------------------------------
echo  [1/4] Building Windows release...
call flutter build windows --release %DART_DEFINES%
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
call flutter pub run msix:create %DART_DEFINES%
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
