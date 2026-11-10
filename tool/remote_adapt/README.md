# remote_adapt：在朋友电脑上适配 galgame 的远程桌面 MCP 服务

在朋友电脑的**桌面会话**里手动运行一个小 MCP 服务，本机 Claude 注册后就多了
`mcp__<名字>__screenshot` / `click` / `touch_tap` … 这组工具，用法和本机 computer use 一样，只是操作对方屏幕。
不需要 ssh 写 cmd.txt → scp 拉截图那一圈：截图直接回到 Claude 上下文，驱动指令一条工具调用跑完。

只为临时借用对方电脑适配，**不做自启动**：用的时候双击 `start.cmd`，用完关窗口。

## 工具

| 工具 | 说明 |
|---|---|
| `screenshot` | DXGI 桌面复制（老游戏独占全屏也能截，BitBlt 是黑屏）；默认整个虚拟桌面缩到长边 1568、JPEG。`region=[l,t,w,h]` 放大局部（小区域不缩放 = 原始像素），`window=hwnd`(+`client=true`) 截窗口 / 客户区。返回文字里带缩放比与换算式、前台窗口；红十字是光标。 |
| `click` `move` `drag` `scroll` | SendInput 真实鼠标。坐标默认是**最近一次截图图像里的像素**（`coords="image"`），服务端换算成物理像素；`coords="physical"` 直接给物理像素。`click` 支持 `count=2` 双击、`modifiers=["shift"]`。 |
| `type_text` `key` | `type_text` 发 Unicode（日文 / 中文直接上屏，不经输入法）；`key` 发组合键（`"ctrl+s"`、`"alt+f4"`、`"vk:0x41"`），`hold_ms` 长按，DirectInput 老游戏用 `scancode=true`。 |
| `touch_tap` `touch_hold` `touch_swipe` | InjectTouchInput（PT_TOUCH），第④条触摸验收用；按住期间每 16 ms 发 UPDATE 帧保持触点。对方没有触屏也能注入。 |
| `list_windows` `focus_window` | 窗口 hwnd、标题、进程、**是否以管理员运行**、窗口 / 客户区物理矩形、DPI。 |
| `powershell` | 在对方桌面会话里执行命令，拉起的程序显示在对方屏幕上；`detach=true` 后台跑长进程（返回日志路径）。 |
| `galdriver` | 透传 `gal_realgame_driver_itest` 指令（`launch` / `calibrate` / `accept4` / `shot` …），等执行完返回 out.txt 新增内容，`shot` 的 PNG 一并作为图片返回。 |
| `view_image` | 读对方电脑上的图片文件。 |
| `info` | 是否管理员、DPI 感知、显示器物理矩形、光标、前台窗口、截图后端、galdriver 目录。 |

所有动作工具都可带 `screenshot_after=true`（按上次截图的区域 / 参数再截一张），省一轮调用。

### 坐标口径

服务声明 Per-Monitor-V2 DPI Aware，所有物理坐标都是真实屏幕像素，与驱动 `accept4` / `calibrate` / `click` 同一口径
（200% 缩放下传逻辑坐标会点偏，BUG-2721 备注）。截图会缩小，换算式就在截图返回的第一行：
`physical_x = left + (x+0.5) * sx`。给驱动传坐标时要么自己按这个式子换算，要么先 `region` 截一个不缩放的局部再读。

## 朋友电脑上（一次性准备）

1. 装 Python 3.10+（`winget install Python.Python.3.12`）和 [Tailscale](https://tailscale.com/download)。
2. 连进同一网络，二选一：你邀请对方加入你的 tailnet（对方 `tailscale up` 登录）；或对方用自己的账号登录，在其 Tailscale 后台把这台机器 **Share** 给你（不用进你的 tailnet，只暴露这一台）。
3. 把本目录（`tool/remote_adapt/`）整个拷过去。

## 每次使用

对方双击 **`start.cmd`**：

- 自动请求管理员权限（以管理员身份运行的游戏只接受同等权限进程的注入，UIPI）；
- 首次在 `%LOCALAPPDATA%\fushi_remote_adapt\venv` 建虚拟环境、装依赖；
- 加一条防火墙规则，只放行 Tailscale 网段 `100.64.0.0/10` 访问 8765；
- 服务**只监听本机 Tailscale 地址**，不碰局域网 / 公网；token 自动生成并保存在 `%LOCALAPPDATA%\fushi_remote_adapt\token`。

窗口里会打印一条注册命令，对方私下发给你，你在本机执行一次（之后不用再注册，token 不变）：

```bash
claude mcp add --transport http friend-a http://friend-pc.tailxxxx.ts.net:8765/mcp --header "Authorization: Bearer <token>"
```

连几台朋友电脑就注册几个名字。用完对方关掉窗口即可；服务是无状态 HTTP，重启后你这边不用重连。

ssh 可以留作备用通道（服务挂了远程重开），平时都走 MCP。

## Tailscale 网络

- `tailscale ping friend-pc` 看是不是直连。显示 `via DERP` 时走中继，延迟和带宽都差，截图会慢：
  多用 `region` 截局部、调小 `max_size` / `quality`，或者让对方路由器开 UPnP / 换网络打通直连。
- WireGuard 已加密，服务不另配 HTTPS；token 防的是同一 tailnet 里的其他设备。
- 想更严：在 Tailscale ACL 里只允许你的设备访问对方的 `tcp:8765`。

## galdriver（真机驱动）

驱动和服务约定同一个目录：服务默认 `%LOCALAPPDATA%\fushi_remote_adapt\galdriver`（`info` 里能看到，
`--galdriver-dir` 可改）。驱动跑在对方电脑上的 Fushi 测试宿主里，启动时把 `GALDRIVER_DIR` 设成这个**绝对路径**
（`run_windows_itest.ps1` 会改写子进程的 `LOCALAPPDATA`，所以不能靠默认值），例如用 `powershell` 工具：

```powershell
$env:GALDRIVER_DIR = "C:\Users\<对方>\AppData\Local\fushi_remote_adapt\galdriver"
cd <对方的 fushi checkout>\fushi
.\tool\run_windows_itest.ps1 -Visible integration_test\gal_realgame_driver_itest.dart
```

（`detach=true` 跑，返回日志路径。）之后 `galdriver("fakeanki\naccept4 1304 1590")` 一次调用返回全部 `ACCEPT4 …` 行。
完成判定用一条带随机串的未知指令做标记（驱动回 `unknown: __mcp_done_…`），不依赖 done.txt 序号，驱动重启后也不会错位。

## 本机自测

```bash
python tool/remote_adapt/geometry_test.py
python tool/remote_adapt/selftest.py
```

`selftest.py` 真起服务（HTTP + Bearer），用官方 MCP 客户端调每个工具，对一个记录事件的 Tk 靶子窗口核对：
鉴权拒绝、截图里能找到靶子、image / physical 坐标点击落点、双击、拖动、滚轮、Unicode 输入、组合键、
触摸点按（被系统提升成鼠标点击且坐标一致）、触摸滑动、长按（系统当右键）、局部截图 1:1、PowerShell UTF-8、
后台进程、galdriver 文件协议（用模拟驱动）、view_image。运行约 20 秒，期间会占用鼠标键盘。

## 已知限制

- 截图是桌面合成结果：窗口被挡住的部分截不到；要截被挡窗口的自身像素用驱动的 `shot game|hwnd:<n>`（WGC）。
- UAC 安全桌面（提权确认框）期间截图和输入都无效，需对方手动点。
- 防火墙规则固定放行 8765；改 `--port` 时自己加规则。
