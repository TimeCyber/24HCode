@echo off
setlocal
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "PATH=C:\Windows\System32;C:\Windows;%DEVECO%\tools\ohpm\bin;%DEVECO%\tools\hvigor\bin;%DEVECO%\tools\node\bin;C:\nvm4w\nodejs;C:\flutter_ohos\bin;%PATH%"
set "FLUTTER_ROOT=C:\flutter_ohos"
set "JAVA_HOME=%DEVECO%\jbr"
set "DEVECO_SDK_HOME=%DEVECO%\sdk"
set "HOS_SDK_HOME=%DEVECO%\sdk"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
set "FLUTTER_GIT_URL=https://gitcode.com/openharmony-tpc/flutter_flutter.git"

cd /d D:\androidproject\CodeAssit\mobile_ohos

echo [ohos] flutter=%FLUTTER_ROOT%
where ohpm
where hvigorw

flutter config --enable-ohos >nul
flutter config --ohos-sdk="%DEVECO%\sdk" >nul
flutter pub get
if errorlevel 1 exit /b 1

echo [ohos] preparing native project via flutter build hap...
flutter build hap --release --target-platform=ohos-arm64
REM flutter may fail on AutoFill types; we patch then assemble with hvigor

echo [ohos] applying AutoFill API24 patch...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$roots = Get-ChildItem 'D:\androidproject\CodeAssit\mobile_ohos\ohos\oh_modules\.ohpm' -Directory -Filter '@ohos+flutter_ohos@*'; foreach ($r in $roots) { $dest = Join-Path $r.FullName 'oh_modules\@ohos\flutter_ohos\src\main\ets\plugin\editing\OhosAutoFillHelper.ets'; if (Test-Path $dest) { Copy-Item 'D:\androidproject\CodeAssit\mobile_ohos\ohos_patches\OhosAutoFillHelper.ets' $dest -Force; Write-Host patched $dest } }"

echo [ohos] hvigor assembleHap...
cd /d D:\androidproject\CodeAssit\mobile_ohos\ohos
call hvigorw assembleHap -p product=default -p buildMode=release --no-daemon
if errorlevel 1 exit /b 1

if not exist "D:\androidproject\CodeAssit\releases\harmony" mkdir "D:\androidproject\CodeAssit\releases\harmony"
copy /Y "D:\androidproject\CodeAssit\mobile_ohos\ohos\entry\build\default\outputs\default\entry-default-unsigned.hap" "D:\androidproject\CodeAssit\releases\harmony\codeassist-ohos-arm64-unsigned.hap"
echo [ohos] done: releases\harmony\codeassist-ohos-arm64-unsigned.hap
exit /b 0
