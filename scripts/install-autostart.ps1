# Register CodeAssist relay+bridge to run at user logon.
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\install-autostart.ps1
# Uninstall:
#   powershell -ExecutionPolicy Bypass -File scripts\uninstall-autostart.ps1

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Bat = Join-Path $Root "start-codeassist-all.bat"
$TaskName = "CodeAssist Autostart"

if (-not (Test-Path -LiteralPath $Bat)) {
  throw "Missing launcher: $Bat"
}

$Tr = 'cmd.exe /c "' + $Bat + '"'
& schtasks.exe /Create /TN $TaskName /TR $Tr /SC ONLOGON /RL LIMITED /F | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "schtasks create failed, exit=$LASTEXITCODE"
}

Write-Host ""
Write-Host "Registered scheduled task: $TaskName"
Write-Host "  Trigger: ONLOGON"
Write-Host "  Action: $Tr"
Write-Host ""
Write-Host "Running once now..."
& schtasks.exe /Run /TN $TaskName | Out-Host
Start-Sleep -Seconds 4
try {
  $h = Invoke-RestMethod -Uri "http://127.0.0.1:8787/health" -TimeoutSec 5
  Write-Host ("health: " + ($h | ConvertTo-Json -Compress))
} catch {
  Write-Host ("health not ready yet, check packages\mcp-server\start-all.log : " + $_.Exception.Message)
}
Write-Host ""
Write-Host ("Query: schtasks /Query /TN " + $TaskName + " /V /FO LIST")
Write-Host "Uninstall: powershell -ExecutionPolicy Bypass -File scripts\uninstall-autostart.ps1"
