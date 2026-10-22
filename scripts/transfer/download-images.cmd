@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-images.ps1" %*
set "DOWNLOAD_EXIT_CODE=%ERRORLEVEL%"

if not "%DOWNLOAD_EXIT_CODE%"=="0" (
    echo.
    echo Image download failed with exit code %DOWNLOAD_EXIT_CODE%.
)

exit /b %DOWNLOAD_EXIT_CODE%
