# CodeAssist 电脑端：用手机配对码兑换 deviceToken，并写入本地配置
# 用法：
#   .\pair-claim.ps1 ABCD12
#   .\pair-claim.ps1 ABCD12 -ApiRoot https://mcp-x.com/prod-api
#   .\pair-claim.ps1   （交互输入）

param(
  [Parameter(Position = 0)]
  [string]$Code,

  [string]$ApiRoot = "https://mcp-x.com/prod-api",

  [string]$DeviceName = $env:COMPUTERNAME
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $ScriptDir ".codeassist-device.env"

if ([string]::IsNullOrWhiteSpace($Code)) {
  $Code = Read-Host "请输入手机上的 6 位配对码"
}
$Code = $Code.Trim().ToUpperInvariant()
if ($Code.Length -lt 4) {
  Write-Error "配对码无效"
  exit 1
}

$ApiRoot = $ApiRoot.Trim().TrimEnd("/")
if ($ApiRoot.EndsWith("/codeassist")) {
  $ApiRoot = $ApiRoot.Substring(0, $ApiRoot.Length - "/codeassist".Length)
}

$claimUrl = "$ApiRoot/codeassist/pair/claim"
$relayUrl = "$ApiRoot/codeassist"
$body = @{
  code       = $Code
  deviceName = if ([string]::IsNullOrWhiteSpace($DeviceName)) { "PC Agent" } else { $DeviceName }
} | ConvertTo-Json

Write-Host "[pair] POST $claimUrl"
try {
  $res = Invoke-RestMethod -Method Post -Uri $claimUrl -ContentType "application/json; charset=utf-8" -Body $body
} catch {
  Write-Error "兑换失败: $($_.Exception.Message)"
  if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
  exit 1
}

if ($res.error) {
  Write-Error "兑换失败: $($res.error)"
  exit 1
}

$token = [string]$res.deviceToken
if ([string]::IsNullOrWhiteSpace($token)) {
  Write-Error "响应里没有 deviceToken：$($res | ConvertTo-Json -Compress)"
  exit 1
}

@"
# 由 pair-claim 自动生成，勿提交到 Git
CODEASSIST_SERVER_URL=$relayUrl
CODEASSIST_TOKEN=$token
CODEASSIST_DEVICE_ID=$($res.deviceId)
CODEASSIST_USER_ID=$($res.userId)
CODEASSIST_DEVICE_NAME=$($res.deviceName)
"@ | Set-Content -Path $EnvFile -Encoding UTF8

Write-Host ""
Write-Host "[pair] 成功！已写入: $EnvFile"
Write-Host "  deviceToken = $token"
Write-Host "  relay       = $relayUrl"
Write-Host ""
Write-Host "下一步："
Write-Host "  1) Cursor MCP 环境变量设 CODEASSIST_SERVER_URL / CODEASSIST_TOKEN（可用上面值）"
Write-Host "  2) 或运行 start-codex-bridge.bat（会自动加载本 env 文件）"
Write-Host ""
