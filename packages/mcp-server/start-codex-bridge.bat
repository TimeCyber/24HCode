@echo off
setlocal
set "PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\nvm4w\nodejs;D:\Git\cmd"
cd /d D:\androidproject\CodeAssit\packages\mcp-server

REM 默认本地中继；若已用 pair-claim 兑换，则优先加载云端 deviceToken
set "CODEASSIST_SERVER_URL=http://127.0.0.1:8787"
set "CODEASSIST_TOKEN=codeassist-dev-token"
set "CODEASSIST_IDE=codex"
set "CODEASSIST_WORKSPACE=D:/androidproject/CodeAssit"
set "CODEASSIST_MCP_BUILD=bridge-0.3.5"

if exist "%~dp0.codeassist-device.env" (
  echo [codeassist] loading .codeassist-device.env
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%~dp0.codeassist-device.env") do (
    if not "%%A"=="" if not "%%B"=="" set "%%A=%%B"
  )
)

echo [codeassist] starting Codex bridge...
echo [codeassist] SERVER=%CODEASSIST_SERVER_URL%
"C:\nvm4w\nodejs\node.exe" dist\bridge.js >> D:\androidproject\CodeAssit\packages\mcp-server\codex-bridge.log 2>&1
