# 卸载 CodeAssist 登录自启任务
$TaskName = "CodeAssist Autostart"
& schtasks.exe /Delete /TN $TaskName /F
if ($LASTEXITCODE -eq 0) {
  Write-Host "已删除计划任务: $TaskName"
} else {
  Write-Host "删除失败或不存在: $TaskName (exit=$LASTEXITCODE)"
}
