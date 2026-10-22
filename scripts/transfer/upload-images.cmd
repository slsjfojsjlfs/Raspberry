@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload-images.ps1" %*
set "UPLOAD_EXIT_CODE=%ERRORLEVEL%"

if not "%UPLOAD_EXIT_CODE%"=="0" (
    echo.
    echo Image upload failed with exit code %UPLOAD_EXIT_CODE%.
)

exit /b %UPLOAD_EXIT_CODE%
