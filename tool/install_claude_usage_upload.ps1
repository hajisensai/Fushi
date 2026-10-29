# 注册 Windows 计划任务：每小时把本机 Claude Code 额度消耗汇总上传到 rank.fushi.moe/usage。
# 前置：~/.fushi/usage-upload.json 写好 {"token": "<服务端 USAGE_UPLOAD_TOKEN>"}（或设环境变量 FUSHI_USAGE_TOKEN）。
#   powershell -ExecutionPolicy Bypass -File tool/install_claude_usage_upload.ps1 [-Remove]
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$name = 'FushiClaudeUsageUpload'
if ($Remove) { Unregister-ScheduledTask -TaskName $name -Confirm:$false; return }
$node = (Get-Command node).Source
# 脚本复制到 ~/.fushi，计划任务不依赖会被清理的 worktree 路径。
$dir = Join-Path $env:USERPROFILE '.fushi'
New-Item -ItemType Directory -Force $dir | Out-Null
$script = Join-Path $dir 'claude_usage_upload.mjs'
Copy-Item (Join-Path $PSScriptRoot 'claude_usage_upload.mjs') $script -Force
$log = Join-Path $dir 'claude_usage_upload.log'
$arg = "/c `"`"$node`" `"$script`" --days 3 >> `"$log`" 2>&1`""
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 1)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Output "已注册计划任务 $name（每小时），日志 $log"
