# Linux（X11）app 外全局查词卡（2026-11-05）

补齐 [2026-06-25 全局查词覆盖窗设计](2026-06-25-global-lookup-webview-overlay-design.md) 的 Linux 端（Steam Deck 桌面模式是主要目标）。范围：在**任意应用**里选中文字 → 应用外悬浮球「应用外查词」/ 全局热键 / 鼠标侧键 / 手柄 → 主引擎查词 → 原生卡片窗渲染同一套 `assets/popup`。截屏识字（冻结层 + OCR）是下一阶段，见[桌面应用外悬浮球](2026-09-30-desktop-system-floating-ball.md)「截屏识字」。

## 1. 核心判断

- **不起第二个 Flutter engine**，Dart 侧沿用 `GlobalLookupController`，同 Windows / macOS。
- **卡片在独立进程 `fushi_lookup_card` 里**（`fushi/linux/lookup_card/`）。应用内 WebView 用的是 WPE WebKit（`flutter_inappwebview_linux`），WebKitGTK 与它注册同名 GObject 类型（`WebKitWebView` 等），两者不能进同一进程；用 WPE 自己画进 GTK 窗又得手搓帧导出与全部输入转发。独立进程用 GNOME 运行时自带的 WebKitGTK 4.1（Flatpak 零额外体积），输入、滚动、音频、透明都是现成的。
- runner（`linux/runner/global_lookup_channel.cc`）只做转发：`app.fushi.reader/global_lookup` 的每个调用原样发给 helper，答复原样回 Dart；反向调用（`jsMessage` / `overlayHidden` / `nativeError` / `globalMouseTrigger` / `getMedia`）原样转回通道。helper 在第一次调用时启动，死了下一次调用重启并重放 `prepare` / `setBlockCapture` / `setGlobalMouseTrigger`；不起 helper 也能答的（`isShowing` / `hide` …）就地答。
- 管道协议：stdin / stdout 每行一个 JSON（`linux/lookup_card/main.cc` 文件头），runner 侧用 `FlJsonMessageCodec`，helper 侧 json-glib。两个方向都异步（`line_pipe.h`）：同步写会在双方同时写大消息时互相等死。`getMedia` 的字节 base64。stdin 关闭 helper 即退出，不会比 Fushi 活得久。

| Windows | Linux（X11） |
|---|---|
| `WS_EX_NOACTIVATE` + `HWND_TOPMOST` | `GTK_WINDOW_POPUP`（override-redirect）+ `accept_focus = FALSE`：窗管不给焦点、不摆放，KWin 把非托管窗叠在托管窗之上（同悬浮球） |
| `SetVirtualHostNameToFolderMapping` | `webkit_web_context_register_uri_scheme("fushi-popup")`，`realpath` 校验不出 assets 目录；三个 scheme 都注册为 secure + CORS |
| `image://` / `dictmedia://` → Dart `getMedia` | 同两个 scheme，经 helper → runner → 通道反向调用；Content-Type 规则同 macOS |
| `chrome.webview.postMessage` | 同 macOS 的 shim（WebKitGTK 也是 `window.webkit.messageHandlers`），全 frame、文档开始注入，顺序 shim → adapter → host |
| `WH_MOUSE_LL` 点卡外关闭 | XInput2 `XI_RawButtonPress`（根窗，只观察不抓取）+ 指针位置：卡外 → 关；卡内 → `host.handleGlobalClick(x,y)`；滚轮键 4–7 不算 |
| `EVENT_SYSTEM_FOREGROUND` | 根窗 `_NET_ACTIVE_WINDOW` 变了 → 关（卡本身永不激活） |
| RawInput 侧键 | 同一条 raw 事件，DOM 3/4 → X 键 8/9；raw 选择只在卡显示中或真绑了侧键时打开（BUG-1077） |
| `WDA_EXCLUDEFROMCAPTURE` | X11 没有，`setBlockCapture` 空操作，设置项按 `GlobalLookupController.canBlockCapture` 隐藏 |
| 拖角 resize | `beginWindowResize` → `gdk_seat_grab` 指针，松手 `endLiveResize` + `windowMoved`（物理 px） |
| 离屏测量 | 同 macOS：**在屏、web view opacity 0、空输入形状**（点击穿透）停靠，reveal 只翻回来；WebKit 对未映射窗口节流 rAF |

坐标：Dart 物理 px、左上原点；GDK 逻辑根坐标；换算用锚点显示器 `gdk_monitor_get_scale_factor`，作为 `monitorDpr` 回 Dart，工作区 `gdk_monitor_get_workarea`。

## 2. bridge lock 的差异

WebKitGTK 4.1 的 script message 不带来源 frame，Windows / macOS 的第二道门（锁定后只认宿主文档主 frame）在这里做不到。令牌这一道照旧：CSPRNG（`getrandom`）32 字节、常量时间比较、只回宿主闭包、顶层文档 commit 即解锁。词典的 sandboxed srcdoc iframe 是不透明源，读不到宿主闭包里的令牌；宿主在文档开始就上锁，早于任何词典内容。

## 3. 取词

`foreground_selection.captureSelection` 在 runner 里读**主选区（primary selection）**，即当前持有选区的应用里高亮的文字：不注入 Ctrl+C、不碰剪贴板（仍走 Dart 的剪贴板串行闸门，与 macOS 同一个入口）。

1. **合成器的主选区**（`linux/runner/wayland_selection.cc`，`ext-data-control-v1`，在 worker 线程上开一条短命的 Wayland 连接，整体限时 500 ms）。必须先走这条：Fushi 画在 XWayland 上，而 KWin 只在 X11 窗口有焦点时才把 Wayland 应用的选区抄进 X11，悬浮球又从不拿焦点，所以 Konsole / Firefox 里选的字在 X11 PRIMARY 里永远是空的（Deck 上实测：data control 读到整句，X11 PRIMARY 为 None）。data control 是剪贴板管理器不拿焦点读选区的标准做法，KWin 6.7 提供。Flatpak 因此加了 `--socket=wayland`（只用来读选区，`GDK_BACKEND` 仍是 x11）。
2. **X11 PRIMARY**：没有 Wayland 显示 / 不支持 data control / 读到空时退回（纯 X11 会话、X11 应用里选的字）。

`captureContext`（整句）X11 / Wayland 都没有对应物，回 notImplemented，Dart 照常退回 `captureSelection`。

## 4. 平台门与限制

- Dart：`linuxLookupCardAvailable`（`lib/src/lookup/linux_lookup_card.dart`）= X11 会话（`linuxSessionIsX11`）且可执行文件旁有 `fushi_lookup_card`。helper 只在构建机有 `webkit2gtk-4.1 json-glib-1.0 x11 xi` 时编出（同 WPE 的可选策略），没有就整套 app 外查词不出现。
- **XWayland（SteamOS 3.9 桌面默认是 Plasma Wayland，Flatpak 强制 X11）**：X 客户端只看得到落在 X 窗口上的指针与按键。点 Wayland 原生窗口不产生 raw 事件，靠 `_NET_ACTIVE_WINDOW` 变化关卡（待 Deck 实测）；`atCursor` 的光标位置是最后一次落在 X 窗口上的位置；keybinder 热键只在 X 窗口有焦点时生效。所以 Deck 上主入口是悬浮球（球与卡都是 X 窗口）。
- **WebKitGTK DMA-BUF 渲染器**（临时兼容层，外部限制）：在这个窗口里（XWayland、Flatpak、Deck GPU）它画出宿主文档，却把弹窗 iframe 的合成层留空，卡片只剩一个空的深色壳（Deck 实测，读窗口像素确认）。helper 的 `main.cc` 在 `gtk_init` 前设 `WEBKIT_DISABLE_DMABUF_RENDERER=1`（不覆盖用户已设的值），只影响 helper 进程；卡片小，非 DMA-BUF 路径没有可见代价。清理条件：某个 WebKitGTK 版本在这个配置下用 DMA-BUF 能画出卡片的 iframe。
