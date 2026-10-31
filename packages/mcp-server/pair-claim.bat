@echo off
setlocal
cd /d "%~dp0"
REM 用法: pair-claim.bat ABCD12
REM       pair-claim.bat ABCD12 https://mcp-x.com/prod-api
set "CODE=%~1"
set "API=%~2"
if "%API%"=="" set "API=https://mcp-x.com/prod-api"

if "%CODE%"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pair-claim.ps1" -ApiRoot "%API%"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pair-claim.ps1" -Code "%CODE%" -ApiRoot "%API%"
)

if errorlevel 1 (
  echo.
  pause
  exit /b 1
)
echo.
pause
