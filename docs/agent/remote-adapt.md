# 远程适配（社区志愿者电脑上做 galgame 内嵌查词适配）

内嵌查词的四条验收（galgame-hooking.md §0、§7）必须在**原始启动路径**上跑，但游戏都在社区成员手里。
这套工具让**一个** Claude 会话直接操作所有在线志愿者的 Windows 电脑：截屏、鼠标、键盘、真实触摸注入、PowerShell、
文件传输，以及在对方电脑上跑 galgame 真机驱动（`accept4` 等）。代码在 `tool/remote_adapt/`。

## 架构

```
志愿者电脑 ×N：双击开始适配.exe（UAC 提权、在登录用户的桌面会话里、主动外连）
   └─ driver\fushi.exe = gal_realgame_driver_itest 打成的 Debug 构建（数据隔离在 work\test-root）
        │  wss（自签证书固定在 agent.json）+ Bearer token → 主控端公网地址:8765 ─路由器转发→ 本机 48765
        ▼
本机：fushi-fleet-gateway.exe ── MCP（http://127.0.0.1:8766/mcp）── Claude 会话
```

- agent 必须跑在**交互桌面会话**里：服务会话（ssh / Windows 服务）里 SendInput、截图、拉起的窗口都到不了用户看到的桌面。
  所以志愿者每次是自己双击 exe，不装服务。
- 两个 exe 都带 `--uac-admin`：agent 提权后才能操作以管理员身份运行的游戏（UIPI）；网关提权才能写防火墙规则。
- 坐标都是虚拟桌面物理像素（agent 声明 Per-Monitor-V2 DPI 感知），与 `accept4` 的坐标同一坐标系。
- 走公网，所以 agent 只连 `wss://`：网关首次运行生成自签证书 `~/.fushi-fleet/gateway.crt`，打包时把证书 PEM
  写进志愿者包的 `agent.json`（`gateway_cert`），agent 只信任这一张。DNS 被劫持或中间人冒充网关时 TLS 握手失败，
  token 不会发出去，冒充者也拿不到对方电脑的控制权。明文 `ws://` 直接拒绝。
- 所有 agent 共用一个 token（社区都是熟人，维护者拍板「权限高点无所谓」）：拿到志愿者包的人能以任意机器名连入。
  主控端包里的 `token.txt` 和 `gateway.key` 只留在自己手里。

## 打包（维护者）

```
pip install -r tool/remote_adapt/requirements.txt
powershell -ExecutionPolicy Bypass -File tool/remote_adapt/build_packages.ps1 -Gateway <公网域名或IP> -BuildDriver
```

- `-Gateway` 是志愿者能连到的主控端地址（可写 `host:port`，默认端口 8765；中文域名自动转 punycode）。
  路由器把公网 TCP 8765 转发到主控电脑的 48765（`-ListenPort`，写进主控端包的 `gateway.json`）。
  本机 8765 被 Fushi 自己的服务占用，网关不能监听它。
- token 和网关证书存在 `~/.fushi-fleet/`（没有就生成），两个包配套。换掉任一个都会让已发出的志愿者包失效。
- 产物在 `tool/remote_adapt/dist/`（不入库）：
  - `fushi-adapt-主控端-<日期>.zip`：`fushi-fleet-gateway.exe` + `token.txt` + `gateway.crt/.key`。双击运行，首次自动放行防火墙入站 48765、
    执行 `claude mcp add --scope user --transport http fleet http://127.0.0.1:8766/mcp`。
  - `fushi-adapt-志愿者-<日期>.zip`：`双击开始适配.exe` + 写好地址和 token 的 `agent.json` + `driver\` + `说明.txt`。
    机器名默认取对方电脑名。
- 驱动代码改了要加 `-BuildDriver` 重新打包；只改 agent 时可以用 `update_agent` 工具远程替换，不用对方再操作。

## 会话里的用法

1. `list_machines` 看谁在线；之后每个工具用 `machine` 点名。不同机器的调用可以在同一条消息里并行发。
2. 先 `machine_info`，确认分辨率、DPI、有无触屏、是否管理员。身份台账（galgame-hooking.md §2）里
   需要的 exe 路径、SHA-256、进程树都用 `powershell` 在对方电脑上取。
3. 验收优先走驱动指令，它们返回文字、省额度：
   `galdriver_start(seed_from_config=true)` 把对方的 Fushi 数据（含词典）复制进隔离测试根并启动驱动 →
   `galdriver "launch <游戏exe>"` → `state` / `lines` / `thread <id>` → 停在一句对白上 →
   `galdriver "fakeanki"` → `galdriver "accept4 <字形x> <y>"`。
4. 启动器、弹窗、游戏菜单这类驱动处理不了的地方，用 `screenshot` + `click` / `key` / `type_text`。
   截图坐标默认是该机器最近一次截图里的像素，网关换算成物理坐标；动作加 `screenshot_after=true` 可以顺带截图，省一轮调用。
5. 截图几乎全黑（`nearly_black`）通常是独占全屏：改用 `galdriver "shot game"`（WGC），再用 `get_file` 把图拉回来。
6. 触摸验收（§7 的表）用 `touch` 工具：`tap` 点按、`hold` 长按、`swipe` 滑动，每一步之后用 `machine_info`
   或动作结果里的 `foreground` 记下前台窗口。
7. 构建照常在 worktree 里做（走 `heavy.dart`），产物用 `put_file` 推过去，
   例如 helper zip 推到 `work\` 后用 `powershell` 的 Expand-Archive 解到 `driver\voice_hook\<arch>\`。

## 边界

- 志愿者的截图、台词、游戏文件只在调试时临时使用，**不进仓库、不进 fixture、不写进 PR / issue**（§3、§7）。
  拉回本机的文件放 scratchpad，用完删除。
- 驱动启动时注入 `FUSHI_TEST_ROOT=work\test-root` 和 `FUSHI_TEST_HIDDEN=1`，不碰对方真实的 Fushi 数据。
  seed 只在测试根为空时复制一次，要重新复制用 `reset_test_root=true`。
- 网关的审计日志在 `~/.fushi-fleet/audit/<machine>.jsonl`（记操作名和参数，不记文件内容）。
- 在对方电脑上跑出的 `accept4 verdict=full` 算原始路径证据，照常按 §7 写进台账；
  修复仍只做引擎级（§0），不因为某位志愿者的某款游戏加按 exe 区分的特判。

## 测试

```bash
python -m pytest tool/remote_adapt/tests -q
```

覆盖 Win32 结构体布局（x64）、真实截图、驱动文件协议（用假驱动，含超时后迟到完成与崩溃的情形），
以及「网关 + 两个替身 agent + 真 MCP 客户端」端到端：点名不存在的机器、两台并行、截图与坐标换算、PowerShell、
跨块文件往返、驱动启停、错 token 与非法机器名被拒、证书不符的冒充网关与明文 ws 被拒。
