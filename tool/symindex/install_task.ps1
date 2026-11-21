# 注册 / 更新计划任务 FushiSymindexRefresh：每天凌晨 4 点跑一次主 checkout 里的 tool/symindex/refresh.ps1
# （develop 没动时几秒就退出）。只需在本机跑一次；删掉用 Unregister-ScheduledTask FushiSymindexRefresh。
#
#   powershell -ExecutionPolicy Bypass -File tool/symindex/install_task.ps1
$ErrorActionPreference = 'Stop'
$commonDir = (git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir).Trim()
$main = Split-Path -Parent $commonDir
$script = Join-Path $main 'tool\symindex\refresh.ps1'
if (-not (Test-Path $script)) { throw "主 checkout 里还没有 $script（PR 合并、主 checkout 更新后再注册）" }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Daily -At '04:00'
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable -Priority 7
Register-ScheduledTask -TaskName 'FushiSymindexRefresh' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Output "已注册 FushiSymindexRefresh：每天 04:00 跑（错过时开机后补跑） $script，日志在 %LOCALAPPDATA%\fushi-symindex\refresh.log"
