@echo off
setlocal
set "DEVECO=C:\Program Files\Huawei\DevEco Studio"
set "PATH=%DEVECO%\tools\ohpm\bin;%DEVECO%\tools\hvigor\bin;%DEVECO%\tools\node\bin;C:\flutter_ohos\bin;%PATH%"
set "FLUTTER_ROOT=C:\flutter_ohos"
set "JAVA_HOME=%DEVECO%\jbr"
set "DEVECO_SDK_HOME=%DEVECO%\sdk"
set "HOS_SDK_HOME=%DEVECO%\sdk"
set "FLUTTER_GIT_URL=https://gitcode.com/openharmony-tpc/flutter_flutter.git"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

cd /d D:\androidproject\CodeAssit\mobile_ohos
flutter config --enable-ohos >nul
flutter config --ohos-sdk="%DEVECO%\sdk" >nul
flutter pub get
if errorlevel 1 exit /b 1

echo [ohos] flutter build app --release...
flutter build app --release --target-platform=ohos-arm64
REM may fail on AutoFill; patch then assembleApp

echo [ohos] applying AutoFill API24 patch...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$roots = Get-ChildItem 'D:\androidproject\CodeAssit\mobile_ohos\ohos\oh_modules\.ohpm' -Directory -Filter '@ohos+flutter_ohos@*'; foreach ($r in $roots) { $dest = Join-Path $r.FullName 'oh_modules\@ohos\flutter_ohos\src\main\ets\plugin\editing\OhosAutoFillHelper.ets'; if (Test-Path $dest) { Copy-Item 'D:\androidproject\CodeAssit\mobile_ohos\ohos_patches\OhosAutoFillHelper.ets' $dest -Force; Write-Host patched $dest } }"

echo [ohos] hvigor assembleApp...
cd /d D:\androidproject\CodeAssit\mobile_ohos\ohos
call hvigorw assembleApp -p product=default -p buildMode=release --no-daemon
if errorlevel 1 exit /b 1

if not exist "D:\androidproject\CodeAssit\releases\harmony" mkdir "D:\androidproject\CodeAssit\releases\harmony"

REM typical outputs under ohos/build/outputs or entry build
for %%F in ("build\outputs\default\*.app") do (
  copy /Y "%%F" "D:\androidproject\CodeAssit\releases\harmony\codeassist-ohos-arm64.app"
  echo COPIED %%F
)
for %%F in ("build\outputs\default\*\*.app") do (
  copy /Y "%%F" "D:\androidproject\CodeAssit\releases\harmony\codeassist-ohos-arm64.app"
  echo COPIED %%F
)

echo [ohos] searching .app artifacts...
dir /s /b "*.app" 2>nul
exit /b 0
