@echo off
setlocal
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "PATH=%DEVECO%\tools\ohpm\bin;%DEVECO%\tools\hvigor\bin;%DEVECO%\tools\node\bin;%PATH%"
set "DEVECO_SDK_HOME=%DEVECO%\sdk"
set "HOS_SDK_HOME=%DEVECO%\sdk"

REM ensure AutoFill API24 patch
for /d %%d in ("D:\androidproject\CodeAssit\mobile_ohos\ohos\oh_modules\.ohpm\@ohos+flutter_ohos@*") do (
  copy /Y "D:\androidproject\CodeAssit\mobile_ohos\ohos_patches\OhosAutoFillHelper.ets" "%%d\oh_modules\@ohos\flutter_ohos\src\main\ets\plugin\editing\OhosAutoFillHelper.ets" >nul
)

cd /d D:\androidproject\CodeAssit\mobile_ohos\ohos
call hvigorw assembleHap -p product=default -p buildMode=release --no-daemon
if errorlevel 1 exit /b 1

if not exist "D:\androidproject\CodeAssit\releases\harmony" mkdir "D:\androidproject\CodeAssit\releases\harmony"
if exist "entry\build\default\outputs\default\entry-default-signed.hap" (
  copy /Y "entry\build\default\outputs\default\entry-default-signed.hap" "D:\androidproject\CodeAssit\releases\harmony\codeassist-ohos-arm64-signed.hap"
  echo SIGNED: releases\harmony\codeassist-ohos-arm64-signed.hap
) else if exist "entry\build\default\outputs\default\entry-default-unsigned.hap" (
  copy /Y "entry\build\default\outputs\default\entry-default-unsigned.hap" "D:\androidproject\CodeAssit\releases\harmony\codeassist-ohos-arm64-unsigned.hap"
  echo UNSIGNED: releases\harmony\codeassist-ohos-arm64-unsigned.hap
)
dir "entry\build\default\outputs\default\*.hap"
exit /b 0
