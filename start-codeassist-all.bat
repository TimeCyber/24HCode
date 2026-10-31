@echo off
REM CodeAssist：开机/登录后自动启动中继 + Cursor bridge
REM 可由「任务计划程序」调用；也可双击手动启动。
setlocal
set "PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\nvm4w\nodejs;D:\Git\cmd"
set "PATHEXT=.COM;.EXE;.BAT;.CMD;.VBS;.JS;.WS;.MSC"

cd /d D:\androidproject\CodeAssit

set "ACCESS_TOKEN=codeassist-dev-token"
set "HOST=0.0.0.0"
set "PORT=8787"
set "CODEASSIST_SERVER_URL=http://127.0.0.1:8787"
set "CODEASSIST_TOKEN=codeassist-dev-token"
set "CODEASSIST_IDE=cursor"
set "CODEASSIST_WORKSPACE=D:/androidproject/CodeAssit"
set "CODEASSIST_PROJECT_NAME=CodeAssit"
REM 自启时拉起后立即退出启动器，子进程独立运行
set "CODEASSIST_DETACH=1"

if exist "packages\mcp-server\.codeassist-device.env" (
  echo [codeassist] loading device env
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("packages\mcp-server\.codeassist-device.env") do (
    if not "%%A"=="" if not "%%B"=="" set "%%A=%%B"
  )
)

echo [codeassist] start-all %DATE% %TIME%
"C:\nvm4w\nodejs\node.exe" "D:\androidproject\CodeAssit\scripts\start-relay.mjs" >> "D:\androidproject\CodeAssit\packages\mcp-server\start-all.log" 2>&1
exit /b %ERRORLEVEL%
