# tool/remote_adapt — 远程适配

一个 Claude 会话通过 MCP 网关同时操作所有在线的社区志愿者 Windows 电脑（截屏 / 输入 / 触摸 / PowerShell / 文件 /
galgame 真机驱动）。说明见 [docs/agent/remote-adapt.md](../../docs/agent/remote-adapt.md)。

```
powershell -ExecutionPolicy Bypass -File tool/remote_adapt/build_packages.ps1 -Gateway <公网域名或IP> -BuildDriver
```

产出 `dist/` 下两个压缩包：主控端（自己用）和志愿者（发给朋友），都是解压双击即用。

| 文件 | 作用 |
|---|---|
| `fleet_gateway.py` | 主控端网关：agent 的 WebSocket 入口 + Claude 的 MCP 入口 + 审计；首次运行自动放行防火墙、注册 MCP |
| `fleet_agent.py` | 被控端 agent（打包成 `双击开始适配.exe`，机器名默认取电脑名） |
| `win_desktop.py` | 截图（mss）、SendInput 鼠标键盘、InjectTouchInput 触摸、前台窗口 |
| `galdriver_host.py` | 拉起真机驱动并按 cmd.txt / out.txt / done.txt 协议收发指令 |
| `fleet_protocol.py` | 线协议 |
| `build_packages.ps1` | 打两个压缩包 |
| `VOLUNTEER.txt` | 志愿者包里的「说明.txt」 |
| `tests/` | `python -m pytest tool/remote_adapt/tests -q` |
