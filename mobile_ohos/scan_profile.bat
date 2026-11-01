@echo off
chcp 65001 >nul
cd /d D:\androidproject\CodeAssit\mobile_ohos\ohos
for %%f in (*.p7b) do (
  echo FILE=%%f
  copy /Y "%%f" D:\androidproject\CodeAssit\mobile_ohos\profile_release.p7b
)
java -jar "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar" help > D:\androidproject\CodeAssit\mobile_ohos\_sign_help.txt 2>&1
python D:\androidproject\CodeAssit\mobile_ohos\_scan_p7b.py
echo DONE
