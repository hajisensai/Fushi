# 维护者本机：启动机群网关。agent 入口绑在本机 Tailscale IPv4 上，MCP 入口只在 127.0.0.1。
#
#   powershell -ExecutionPolicy Bypass -File tool/remote_adapt/start_gateway.ps1
#
# 首次：先 `python tool/remote_adapt/fleet_gateway.py --init-token` 生成 token，
# 再注册 MCP（一次即可，所有 Claude 会话共用）：
#   claude mcp add --scope user --transport http fleet http://127.0.0.1:8766/mcp
param(
  [string]$AgentHost = "",
  [int]$AgentPort = 8765,
  [int]$McpPort = 8766
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($AgentHost)) {
  $ts = Get-Command tailscale -ErrorAction SilentlyContinue
  if ($null -eq $ts -and (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) {
    $ts = Get-Item "$env:ProgramFiles\Tailscale\tailscale.exe"
  }
  if ($null -eq $ts) { throw "没找到 tailscale；装好并登录，或用 -AgentHost 指定监听地址" }
  $tsPath = if ($ts -is [System.Management.Automation.CommandInfo]) { $ts.Source } else { $ts.FullName }
  $AgentHost = (& $tsPath ip -4 | Select-Object -First 1).Trim()
  if ([string]::IsNullOrWhiteSpace($AgentHost)) { throw "tailscale ip -4 没有返回地址（未登录？）" }
}
Write-Host "[fleet] 志愿者 agent.json 里填 gateway = ws://${AgentHost}:${AgentPort}/agent"
& python (Join-Path $PSScriptRoot "fleet_gateway.py") `
  --agent-host $AgentHost --agent-port $AgentPort --mcp-port $McpPort
