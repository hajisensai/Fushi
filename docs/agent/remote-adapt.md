# 远程适配机群（社区志愿者电脑上做 galgame 内嵌查词适配）

内嵌查词的四条验收（galgame-hooking.md §0、§7）必须在**原始启动路径**上跑，但游戏都在社区成员手里。
这套工具让本机的 Claude 会话直接操作志愿者的 Windows 电脑：截屏、鼠标、键盘、真实触摸注入、PowerShell、
文件传输，以及在对方电脑上跑 galgame 真机驱动（`accept4` 等）。可以同时操作多台。代码在 `tool/remote_adapt/`。

## 架构

```
志愿者电脑 ×N：fushi-adapt-agent.exe（在登录用户的桌面会话里，主动外连）
   └─ driver\fushi.exe = gal_realgame_driver_itest 打成的 Debug 构建（数据隔离在 work\test-root）
        │  WebSocket + Bearer token，经 Tailscale
        ▼
本机：fleet_gateway.py ── MCP（http://127.0.0.1:8766/mcp）── 各 Claude 会话
```

- agent 必须跑在**交互桌面会话**里：服务会话（ssh / Windows 服务）里 SendInput、截图、拉起的窗口都到不了用户看到的桌面。
  install_agent.ps1 用「启动」文件夹快捷方式，`-Elevated` 时用登录触发、`/IT /RL HIGHEST` 的计划任务。
- 游戏以管理员身份运行时，agent 也必须提权（UIPI），否则 SendInput 报「只发出 0/N 个事件」。
- 坐标都是虚拟桌面物理像素（agent 声明 Per-Monitor-V2 DPI 感知），与 `accept4` 的坐标同一坐标系。

## 维护者一次性准备

1. 本机装 Tailscale，邀请志愿者进同一个 tailnet。
2. `pip install -r tool/remote_adapt/requirements.txt`（mcp 固定 1.x）。
3. `python tool/remote_adapt/fleet_gateway.py --init-token` 生成 `~/.fushi-fleet/token`。
4. `claude mcp add --scope user --transport http fleet http://127.0.0.1:8766/mcp`，所有会话共用。
5. 打包：`powershell -ExecutionPolicy Bypass -File tool/remote_adapt/build_agent.ps1 -BuildDriver`，
   产物在 `tool/remote_adapt/dist/`（不入库）。把 zip、网关地址、token 发给志愿者，对方按 `VOLUNTEER.md` 安装。
6. 每次用之前运行 `tool/remote_adapt/start_gateway.ps1`（agent 断线会自己退避重连）。

驱动代码改了要重新打包；只改 agent 时可以用 `update_agent` 工具远程替换，不用对方再操作。

## 多台并行的分工

- **一台机器一个 Claude 会话**，一个会话只负责一个引擎、只用一个 worktree（与 galgame-hooking.md
  「一引擎一任务」一致）。总控会话负责分配「哪台机器 × 哪个引擎」，汇总各会话的台账，并更新 `engine-support.yaml`。
- 每台机器有**独占租约**：先 `claim_machine(machine, holder=<任务名>)` 拿 lease，后续调用都带上它，
  做完调用 `release_machine`。holder 相同再 claim 会拿回原 lease（上下文压缩后找回）。空闲超过 30 分钟租约自动过期；
  要抢别人的租约，先确认对方已不用，再传 `steal=true`。
- 构建在各自的 worktree 里做（照常走 `heavy.dart` 租约），产物用 `put_file` 推过去，
  例如 helper zip 推到 `work\` 后用 `powershell` 的 Expand-Archive 解到 `driver\voice_hook\<arch>\`。

## 会话里的用法

1. `list_machines` → `claim_machine`。
2. 先 `machine_info`，确认分辨率、DPI、有无触屏、是否管理员。身份台账（galgame-hooking.md §2）里
   需要的 exe 路径、SHA-256、进程树都用 `powershell` 在对方电脑上取。
3. 验收优先走驱动指令，它们返回文字、省额度：
   `galdriver_start(seed_from_config=true)` 把对方的 Fushi 数据（含词典）复制进隔离测试根并启动驱动 →
   `galdriver "launch <游戏exe>"` → `state` / `lines` / `thread <id>` → 停在一句对白上 →
   `galdriver "fakeanki"` → `galdriver "accept4 <字形x> <y>"`。
4. 启动器、弹窗、游戏菜单这类驱动处理不了的地方，用 `screenshot` + `click` / `key` / `type_text`。
   截图坐标默认就是图里的像素，网关会换算成物理坐标；动作加 `screenshot_after=true` 可以顺带截图，省一轮调用。
5. 截图几乎全黑（`nearly_black`）通常是独占全屏：改用 `galdriver "shot game"`（WGC），再用 `get_file` 把图拉回来。
6. 触摸验收（§7 的表）用 `touch` 工具：`tap` 点按、`hold` 长按、`swipe` 滑动，每一步之后用 `machine_info`
   或动作结果里的 `foreground` 记下前台窗口。

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

覆盖租约、Win32 结构体布局（x64）、真实截图、驱动文件协议（用假驱动，含超时后迟到完成与崩溃的情形），
以及「网关 + 两个替身 agent + 真 MCP 客户端」端到端：截图、坐标换算、租约隔离、PowerShell、跨块文件往返、驱动启停。
