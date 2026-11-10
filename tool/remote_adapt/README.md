# tool/remote_adapt — 远程适配机群

本机 Claude 会话通过 MCP 网关操作社区志愿者的 Windows 电脑（截屏 / 输入 / 触摸 / PowerShell / 文件 / galgame 真机驱动），
可以多台并行。说明见 [docs/agent/remote-adapt.md](../../docs/agent/remote-adapt.md)；发给志愿者的说明是 [VOLUNTEER.md](VOLUNTEER.md)。

| 文件 | 作用 |
|---|---|
| `fleet_gateway.py` | 本机网关：agent 的 WebSocket 入口 + Claude 的 MCP 入口 + 独占租约 + 审计 |
| `fleet_agent.py` | 被控端 agent（打包成 `fushi-adapt-agent.exe`） |
| `win_desktop.py` | 截图（mss）、SendInput 鼠标键盘、InjectTouchInput 触摸、前台窗口 |
| `galdriver_host.py` | 拉起真机驱动并按 cmd.txt / out.txt / done.txt 协议收发指令 |
| `fleet_protocol.py` | 线协议 |
| `build_agent.ps1` / `install_agent.ps1` / `start_gateway.ps1` | 打包 / 志愿者安装 / 启动网关 |
| `tests/` | `python -m pytest tool/remote_adapt/tests -q` |
