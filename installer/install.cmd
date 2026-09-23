@echo off
chcp 65001 >nul
title KatiChat Setup
set "SRC=%~dp0."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Src "%SRC%" -PkgDir "%SRC%"
if errorlevel 1 (
  echo.
  echo   Installation failed. See messages above.
  timeout /t 20
  exit /b 1
)
echo.
echo   Installation finished. Starting the app...
timeout /t 6
exit /b 0
