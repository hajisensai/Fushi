# 桌面应用外悬浮球（Windows / macOS）

2026-09-30 用户要求：Windows 和 macOS 也实现应用外悬浮球；桌面上应用外球与应用内球**可以同时存在**（不像 Android 那样主窗在前台时原生球让位）；观感 / 交互与应用内球、Android 原生球（BUG-2793 之后）一致。

## 分工

- **Dart**（`lib/src/floating_ball/`）持有配置、位置持久化与**全部动作的执行**（桌面查词都在 Dart：`GlobalLookupController`、`DesktopLookupService`）。
- **原生**（Windows runner / macOS Runner）只负责：画球与按钮列、拖动 / 吸附 / 展开动画、把「点了哪颗、球在哪」报回 Dart。原生侧不执行任何查词逻辑。

## 通道契约：`app.fushi.reader/floating_ball`（与 Android / iOS 同名）

### Dart → 原生

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `startSystemBall` | 见下 | `bool`：球窗 / 面板是否起来了（建窗或 D2D 失败回 false，Dart 不记签名、下次同步再试） | 未运行则创建；已运行则**原地**更新按钮 / 配色 / 图片（不挪位置、收起菜单） |
| `stopSystemBall` | — | — | 销毁全部窗口 |
| `isSystemBallRunning` | — | `bool` | |
| `setAppForeground` | `{foreground: bool}` | — | 桌面**忽略**（应用内外共存） |
| `takeSystemBallClosedByUser` | — | `bool` | 桌面恒 `false`（关闭即时推给 Dart，进程就是 app） |

`startSystemBall` 参数：

- `actions: List<String>` — 用户勾选的动作 id（桌面只会出现 `lookup` / `popup_lookup` / `clipboard` / `screen_ocr` / `sync`），按自上而下顺序。
- `labels: Map<String, String>` — 按钮文案 / tooltip，键为动作 id 加 `open_app` / `close` / `ball`。
- `iconImages: Map<String, Uint8List>` — 每颗按钮（含 `open_app` / `close`）的图标 PNG：正方形 66×66px（= 22 逻辑像素 × 3），前景色已按主题 `onSurface` 着色、背景透明。原生按当前 DPI 缩放到 22 DIP / pt 画在按钮正中。
- `ballImage: Uint8List` — 球面 PNG（`assets/meta/icon.png` 原图字节）。
- `colors: Map<String, int>` — `surface` / `onSurface` / `primary` 的 ARGB。
- `dock: 'left' | 'right'`，`fraction: double`（0..1）— 初始位置（Dart 持久化值）。
- `animate: bool`（可选，默认 `true`）— Windows 的动效策略：Dart 按墨水屏 / 系统减弱动画统一判定，纳入配置签名，切换时即使颜色不变也重新下发。macOS 暂未消费此字段，仍需在该平台单独修复与验证；Android 保留自身原生动画策略。

### 原生 → Dart（`invokeMethod`，同一通道）

| 方法 | 参数 | 说明 |
|---|---|---|
| `systemBallAction` | `{id: String, anchor: [left, top, right, bottom]}` | 用户点了 `lookup` / `popup_lookup` / `clipboard` / `sync` / `open_app`。`anchor` = 球在屏幕上的矩形，**物理像素、左上原点**（与 `global_lookup` 通道同一约定），供查词卡锚在球旁边；Dart 经 `GlobalLookupPhysicalPlacement`（物理像素通道）交给覆盖窗，**不能**当逻辑像素的 `anchorScreenRect` 再乘主窗 DPR。原生先收起菜单再报。 |
| `systemBallClosedByUser` | — | 用户点了 `close`：原生已自行销毁窗口，Dart 把「应用外显示」开关关掉。 |
| `systemBallPositionChanged` | `{dock: 'left'|'right', fraction: double}` | 拖动松手吸附后报一次，Dart 落库。 |

## 几何与观感（与 `ReaderFloatingBallLayout` / Android `FloatingBallGeometry.java` 同一套）

单位：Windows 用 DIP（`px = dip × dpi / 96`，按球所在显示器的 DPI），macOS 用 pt。

- 球 48、按钮 40、间距 6、贴边 margin 8；收起外缩 `tuck = 0.34 × 48`（球只露约 2/3）；收起态不透明度 0.42。
- **视口** = 球所在显示器的**工作区**（Windows `MONITORINFO.rcWork`，macOS `NSScreen.visibleFrame`）。若停靠边外侧紧挨着另一块显示器，`tuck` 取 0（不把球塞进邻屏）。
- 位置 = 停靠边 + 球顶在活动范围 `[minTop, maxTop]` 里的比例；`minTop = viewport.top + margin`，`maxTop = max(minTop, viewport.bottom − ball − margin)`。
- 收起球左 = 左停靠 `viewport.left − tuck` / 右停靠 `viewport.right − ball + tuck`；展开球左 = `viewport.left + margin` / `viewport.right − ball − margin`。
- 按钮自上而下：`close`、`open_app`、然后 `actions`；列在球正上方、与球同轴，末颗离球最近（中心距球心 `ball/2 + gap + button/2`）。每列最多 `perColumn = max(1, floor((viewport.height − 2·margin − ball) / (button + gap)))` 颗，超出向屏幕中央方向续列（列距 = `button + gap`，各列底对齐）。放不下时展开态把球沿边往下滑：`expandedTop = clamp(ballTop, viewport.top + margin + reach − ball/2, maxTop)`，`reach = ball/2 + rowCount·(button + gap)`。
- 球：圆形裁切 `ballImage`（cover），描边环宽 `1 + 1.5·t`，颜色 `lerp(onSurface@35%, primary, t)`，阴影随 t 加深；不透明度 `0.42 + 0.58·t`，拖动中 1。
- 按钮：圆形，底色 = `surface` 上叠 6% `onSurface`，轻阴影（≈ elevation 2），图标居中 22；悬停 / 按下给 onSurface 8% / 12% 的叠色；tooltip = labels。

## 动画（与应用内同时长同曲线）

- Windows `animate=false` 时展开、收起、拖后吸附直接落到最终几何，不启动动画计时器；运行中切换通过原地配置更新取消旧动画，位置回调仍正常发送。
- 展开 280ms、收起 190ms，进度 t 线性；中途反向按剩余路程缩短。球位置 / 不透明度 / 描边随 t 插值。
- 按钮 i（共 n 颗）：`begin = (n−1−i)·0.35/(n−1)`（n=1 时 0），`end = min(1, begin + 0.65)`，`k = easeOutBack((t − begin)/(end − begin))`，easeOutBack = 三次贝塞尔 (0.175, 0.885, 0.32, 1.275)。按钮从球心飞到落点：`center = ballCenter + offset·k`，缩放 `0.4 + 0.6·min(k, 1.2)`，不透明度 `clamp(k, 0, 1)`。
- 拖动：越过系统拖动阈值（Windows 取 `SM_CXDRAG/SM_CYDRAG` 按球窗 DPI 以 `MulDiv(…, dpi, 96)` 换成物理像素——`GetSystemMetricsForDpi` 对这两项不缩放（实测恒回 4），macOS 4pt）即拖动——先**立即收起**，球跟手（纵向夹在 `[minTop, maxTop]`），不透明度 1。松手：按球心在视口左右哪一半定停靠边、比例按落点，220ms easeOutCubic (0.215, 0.61, 0.355, 1) 吸附到收起位，并报 `systemBallPositionChanged`。拖到另一块显示器就以那块的工作区为视口。
- **不闪**（BUG-2793 的教训）：点球展开时不得出现「窗口先变大、下一帧才挪位」的跳动；按钮所在的表面必须在显示前就按最终几何布好，只做动画。
- 显示器配置 / 工作区 / DPI 变化：收起并按停靠边 + 比例在新视口重摆（位置永远落在屏内）。

## 窗口形态

- **Windows**：`WS_POPUP` + `WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`，owner = nullptr（主窗最小化时球不能跟着隐藏），`UpdateLayeredWindow` 逐像素 alpha（全透明像素点击穿透），D2D / WIC 自绘（范式同 `floating_lyric_window.cpp`）；`WM_MOUSEACTIVATE` 与 `WM_POINTERACTIVATE` 都交给 `window_activation_policy.h` 的 `OverlayNoActivateReply()`（`MA_NOACTIVATE` / `PA_NOACTIVATE`；`WS_EX_NOACTIVATE` 只挡鼠标，触摸 / 触控笔按下另走 `WM_POINTERACTIVATE`，同 BUG-2788），点球不抢前台（否则「应用外查词」取不到别的程序的选区）。窗口类名 `FushiFloatingBallWindow`，**标题不能是 "Fushi"**（`main.cpp` 按标题 FindWindow 找主窗）。PerMonitorV2：处理 `WM_DPICHANGED`、`WM_DISPLAYCHANGE`、`WM_SETTINGCHANGE(SPI_SETWORKAREA)`。纯几何放头文件并按 `windows/runner/CMakeLists.txt` 现有范式加 `_test` + `_gate`。
- **macOS**：`NSPanel`，styleMask `[.borderless, .nonactivatingPanel]`，`level = .statusBar`，collectionBehavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`，`hidesOnDeactivate = false`，`becomesKeyOnlyIfNeeded`，自绘 `NSView`（`acceptsFirstMouse = true`，不激活 app）；监听 `NSApplication.didChangeScreenParametersNotification` 重摆。坐标：AppKit 左下原点 ↔ 通道里的物理像素左上原点按 `backingScaleFactor` 换算（同 `GlobalLookupOverlay.swift` 约定）。

## 设置

- 「应用外显示」开关在 Android / Windows / macOS 可见（iOS 不提供）；桌面文案不提「显示在其他应用上层」权限。
- 应用外按钮组在桌面可选：`lookup`（唤起主窗并打开查词页）、`popup_lookup`（查前台程序当前选中的文字 = 全局查词热键同一路径）、`clipboard`（查剪贴板文字，卡片锚在球旁）、`screen_ocr`（截屏识字，见下节）、`sync`（唤起主窗并跑一轮手动同步，结果在主窗里给）。拍照查词桌面不提供。`lookup`、`popup_lookup` 与 `screen_ocr` 只在「查词」模块开着时可选、也只在那时下发给原生（模块关着查词页没有入口、全局查词不启动）；模块开关一变，宿主重新同步球的按钮。
- 位置偏好：`floating_ball.system_dock` / `floating_ball.system_y`（与应用内球的 `floating_ball.dock` / `floating_ball.y` 分开——两颗球可以同时在）。

## 截屏识字（2026-10-04 补齐）

用户 2026-10-04 指出：桌面应用外球没有截屏识字（Android / iOS 有）。桌面形态 = **冻结画面选字层**：点球上的「截屏识字」→ 截球所在的那块显示器 → 原生立刻用这张截图盖满该显示器（画面「定格」，提示识别中）→ Dart 跑系统 OCR → 原生在截图上画行框 → 用户点字，Dart 命中测试后用**全局查词覆盖窗**（与「应用外查词」同一张卡）锚在被点的字旁边弹卡。点行框外 / Esc / 右键 / 关闭钮退出，球随之恢复。

### OCR

- macOS：沿用 `app.fushi.reader/system_ocr`（`apple/FushiSystemOcr.swift`，Vision）。
- Windows：本次补上 `app.fushi.reader/system_ocr` 的 Windows 实现（`Windows.Media.Ocr`，WRL/ABI，不用 C++/WinRT 投影——runner 以 `_HAS_EXCEPTIONS=0` 编译）。`isAvailable` = 本机有任何可用识别语言；`recognize` 按 `language` 建引擎，该语言识别器没装时报 `PlatformException(code: 'LANGUAGE_UNAVAILABLE')`，Dart 映射成 `SystemOcrUnavailableException('language_unavailable')` 并提示去「设置 → 时间和语言 → 语言」装日语（含 OCR 组件）。行框 = 该行所有词框的并集；CJK 词之间不插空格（Windows OCR 会把日文按词拆开）。识别在工作线程跑，结果投回平台线程回话。副作用（有意）：漫画「设备自带 OCR」引擎在 Windows 上也随之可用。

### 通道补充（Dart → 原生）

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `startScreenOcrCapture` | `{anchor: [l,t,r,b] \| null, labels: {recognizing, hint, close}, colors: {primary, surface, onSurface}}` | `{png: Uint8List, screen: [l,t,r,b]}`；失败 `{error: String}`（`permission_denied` / `capture_failed`） | 选 anchor 中心所在显示器（null 取光标所在）；先藏起球与按钮列（不销毁），等合成后截**整块显示器**（物理像素，PNG 宽高 = screen 宽高），然后立刻显示冻结层并显示 `labels.recognizing`。失败时球已恢复、不显示冻结层。 |
| `updateScreenOcrOverlay` | `{lines: [[l,t,r,b], …], message: String?}` | — | `lines` 是截图像素坐标；画行框（primary 描边 + 12% 填充）。`message` 非空时替换顶部提示文字（识别失败 / 没识别到字 / 语言没装），为 null 时显示 `labels.hint`。 |
| `stopScreenOcr` | — | — | 关冻结层、恢复球。Dart 主动关不回调。 |

### 通道补充（原生 → Dart）

| 方法 | 参数 | 说明 |
|---|---|---|
| `screenOcrTap` | `{x, y}` | 冻结层上左键点下（不含关闭钮）：截图像素坐标（= 相对 screen 左上的物理像素）。 |
| `screenOcrDismissed` | — | Esc / 右键 / 关闭钮：原生已关层、已恢复球。 |

坐标约定同上文：物理像素、左上原点（macOS 按 `backingScaleFactor` 与 AppKit 左下原点换算，同 `GlobalLookupOverlay.swift`）。

### 冻结层窗口

- 必须在**查词卡之下**：卡在冻结层之上弹出、点卡外时卡自己收起，冻结层同时收到那一记点击（可能就是查下一个字）。
- Windows：`WS_POPUP`，`WS_EX_TOPMOST | WS_EX_TOOLWINDOW`，覆盖显示器整块（含任务栏）；显示时取一次前台（为了收 Esc——点球是本进程收到的最后一次输入，`SetForegroundWindow` 允许），之后 `WM_MOUSEACTIVATE` 回 `MA_NOACTIVATE`，点击不改 Z 序（查词卡 `HWND_TOPMOST` 后到者在上）。类名 `FushiScreenOcrWindow`，标题不得是 "Fushi"。
- macOS：`NSPanel` 无边框，level `.statusBar`（卡是 `.popUpMenu`，在其上），`canBecomeKey` 以收 Esc，`collectionBehavior` 同球（含 `.fullScreenAuxiliary`）。截屏：macOS 14+ 用 ScreenCaptureKit `SCScreenshotManager`（只排除球的面板，不排除主窗），13.x 回落 `CGDisplayCreateImage`；没有「屏幕录制」权限时 `CGRequestScreenCaptureAccess()` 并返回 `permission_denied`，Dart 唤起主窗提示。

### Dart 侧

- `screen_ocr` 在桌面应用外球上可选，条件同 `popup_lookup`（查词模块开着：结果要用全局查词卡）。拍照查词桌面仍不提供。
- 点字：`screenOcrHitTest`（scale 1）→ 查 `line.text` 从被点字起的后缀、`sentence = line.text`，`GlobalLookupPhysicalPlacement(anchorScreenRect: 字框 + screen 左上)`。点在行外 → `stopScreenOcr` 并收起查词卡。
- 开始前先收起已开的查词卡（否则它会被截进图里）。

## 验证记录（2026-09-30）

- **Windows 真机**（Debug runner，隔离数据根 `FUSHI_TEST_ROOT`，屏上测试实例；显示器当时关着、截屏全黑，以下用 Win32 枚举窗口 + 合成鼠标 + 隔离库取证）：
  - 打开「应用外显示」后出现 `FushiFloatingBallWindow`（60×60 = 球 48 + 两侧阴影边 6，DPI 100%），扩展样式 TOPMOST | TOOLWINDOW | LAYERED | NOACTIVATE，与主窗并存。收起态外缩 16px（= 0.34×48），球顶 391（= 8 + 1094×0.35 出厂比例），与几何公式逐项相符。
  - 合成点击球：前台窗口不变（不抢焦点）；球窗尺寸不变、滑回屏内贴边 8；另起 `FushiFloatingBallMenuWindow`，与球同轴。
  - 拖到左半屏松手：吸附左缘并外缩；Dart 收到 `systemBallPositionChanged` 落库 `floating_ball.system_dock = left`、`system_y = 0.6014`（与落点换算一致）。
  - 点「关闭」：两个原生窗口销毁，Dart 把 `floating_ball.system` 置 false。
  - 「打开 Fushi」在测试 runner 下不前置主窗是设计使然（`DesktopForegroundGuard.isHiddenWindowsRunner` 早返回），非本功能缺陷。
- **macOS**：真 Mac 上对 `FlutterMacOS.framework` 类型检查 0 错误；时序小程序（假 messenger）走通启动 → 展开 → 点动作 → 原地更新 → 关闭，面板位置 / 按钮落点 / anchor 与手算一致。**未做**：完整 Xcode 工程编译与真机点按 / 拖动 / 悬停。
- 定向测试 108 条、全量 analyze 通过。
