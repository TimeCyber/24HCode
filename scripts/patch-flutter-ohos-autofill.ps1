# Patch flutter_embedding_release.har AutoFill helper for SDK API 24 compile.
$ErrorActionPreference = 'Stop'
$src = 'D:\androidproject\CodeAssit\mobile_ohos\ohos\oh_modules\.ohpm\@ohos+flutter_ohos@rlzuzmv5zmp3jxmtog+q+vlqls+m46nxpln47xgsiok=\oh_modules\@ohos\flutter_ohos\src\main\ets\plugin\editing\OhosAutoFillHelper.ets'
$har = 'C:\flutter_ohos\bin\cache\artifacts\engine\ohos-arm64-release\flutter_embedding_release.har'
$tmp = 'D:\androidproject\CodeAssit\mobile_ohos\_har_patch'
if (-not (Test-Path $src)) { throw "patched source missing: $src" }
if (-not (Test-Path $har)) { throw "har missing: $har" }
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp | Out-Null
Copy-Item $har "$tmp\har.zip"
Expand-Archive -Path "$tmp\har.zip" -DestinationPath "$tmp\out" -Force
$targets = Get-ChildItem "$tmp\out" -Recurse -Filter 'OhosAutoFillHelper.ets'
if ($targets.Count -eq 0) { throw 'OhosAutoFillHelper.ets not found inside har' }
foreach ($t in $targets) {
  Copy-Item $src $t.FullName -Force
  Write-Host "patched $($t.FullName)"
}
Remove-Item "$tmp\har.zip" -Force
Compress-Archive -Path "$tmp\out\*" -DestinationPath "$tmp\har.zip" -Force
Copy-Item "$tmp\har.zip" $har -Force
Write-Host "HAR updated: $har"
