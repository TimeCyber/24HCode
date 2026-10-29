@echo off
setlocal
set "PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\nvm4w\nodejs;D:\Git\cmd"
set "CODEASSIST_SERVER_URL=http://127.0.0.1:8787"
set "CODEASSIST_TOKEN=codeassist-dev-token"
set "CODEASSIST_IDE=codex"
set "CODEASSIST_WORKSPACE=D:/androidproject/CodeAssit"
set "CODEASSIST_MCP_BUILD=bridge-0.3.5"
cd /d D:\androidproject\CodeAssit\packages\mcp-server
echo [codeassist] starting Codex bridge...
"C:\nvm4w\nodejs\node.exe" dist\bridge.js >> D:\androidproject\CodeAssit\packages\mcp-server\codex-bridge.log 2>&1
