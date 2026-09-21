# macOS app 外全局查词覆盖窗（2026-09-14）

补齐 [2026-06-25 全局查词覆盖窗设计](2026-06-25-global-lookup-webview-overlay-design.md) 里留给「后续」的 macOS 端。范围：macOS Fushi 在**任意应用**里选中文字 → 全局热键 / 鼠标侧键 / 手柄 → 主引擎查词 → 原生覆盖窗渲染同一套 `assets/popup` 卡片。Linux 仍无。

## 1. 核心判断（与 Windows 完全同构）

- **不起第二个 Flutter engine**。查词、render script、级联布局、bridge 语义全部沿用 `GlobalLookupController`；macOS 只补 `app.fushi.reader/global_lookup` 通道的 native 实现，Dart 侧唯一改动是放开 `isSupported` 与 popup 资源目录探测。
- native 实现是 `fushi/macos/Runner/GlobalLookupOverlay.swift`：`NSPanel(.borderless, .nonactivatingPanel)` + `WKWebView`，一一对应 `windows/runner/global_lookup_window.cpp`。

| Windows | macOS |
|---|---|
| `WS_EX_NOACTIVATE` / 永不夺焦点 | `.nonactivatingPanel` + `canBecomeKey/Main = false`；WKWebView 子类 `acceptsFirstMouse = true` |
| `HWND_TOPMOST` + 置顶守卫 | `level = .popUpMenu` + `canJoinAllSpaces / fullScreenAuxiliary` |
| `SetVirtualHostNameToFolderMapping("hibiki.popup")` | `WKURLSchemeHandler` `fushi-popup://assets/<file>`（自定义 scheme 而非 file://：host 与 popup iframe 必须同源才能包 iframe 的 `chrome.webview` 桥） |
| `image://` / `dictmedia://` `WebResourceRequested` → Dart `getMedia` | 同两个 scheme 的 `WKURLSchemeHandler` → 同一条反向调用；Content-Type 规则同 `MediaContentTypeHeader`，加 `Access-Control-Allow-Origin: *` 让词典字体过 CORS |
| `chrome.webview.postMessage` | 每个 frame 文档开始注入 shim：`window.chrome.webview.postMessage = m => webkit.messageHandlers.fushiOverlay.postMessage(JSON.stringify(m))`；随后按同样顺序注入 `popup_bridge_adapter.js`、`global_lookup_host.js` |
| `WH_MOUSE_LL` 点卡外关闭 + `EVENT_SYSTEM_FOREGROUND` | `NSEvent` 全局鼠标监视（其它 app 的点击必然在卡外）+ 本进程本地监视（卡内 → `host.handleGlobalClick(x,y)` 由 host 判卡/空隙；主窗 → 关）+ `NSWorkspace.didActivateApplication`；只在显示期间 arm（BUG-1077） |
| RawInput 侧键触发 | `NSEvent.addGlobalMonitorForEvents(.otherMouseDown)`，`buttonNumber` 与 DOM button 同编码（3 后退 / 4 前进）；只在真绑了侧键时注册 |
| `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` | `NSWindow.sharingType = .none` |
| `WM_NCLBUTTONDOWN/HTBOTTOMRIGHT` 拖角 resize | `beginWindowResize` → 本地 drag 监视改 frame，松手 `endLiveResize` + `windowMoved`（物理 px，与 WM_EXITSIZEMOVE 同载荷） |
| 离屏渲染 → `Reveal` 搬到光标 | **在屏、`webView.alphaValue = 0`、`ignoresMouseEvents`** 的透明停靠 → reveal 只翻 alpha / 鼠标；原因：WebKit 对不在任何屏幕上的窗口冻结 rAF（见记忆 `mac-hidden-runner-webkit-raf-frozen`），而 host 的自测量靠 rAF |
| `galCard` 离屏卡片窗（游戏内查词） | 不支持（galgame 按规则 Windows-only），`target == "galCard"` 直接回 `gal_card_unavailable` |

## 2. 坐标契约

Dart 说的是**物理 px、左上原点**（Win32）；AppKit 是**点、左下原点**。所有过界都经 `topLeftPoint / appKitRect`，dpr 取**锚点屏幕**的 `backingScaleFactor` 并作为 `monitorDpr` 回给 Dart（BUG-859 同语义）。`showAt` 回 `workW/H`（`visibleFrame` × scale）、`cursorWorkX/Y`（锚点相对工作区左上）。`revealStack` 的工作区夹紧增量折进 `commitLayerShift`（点 == CSS px，因为 WKWebView 按锚点屏幕 scale 栅格化）。

## 3. 取词链路（`SelectionCaptureMac.swift`，同 `foreground_selection` 通道）

顺序：`captureContext`（既有 AX 上下文捕获，用户开了「读取整句」时）→ `captureSelection`：AX `kAXSelectedText` → 释放所有修饰键后合成 ⌘C（`CGEvent`，`.cghidEventTap`）+ `changeCount` 轮询 600 ms + **整份**剪贴板还原（所有 type，不只文本）→ 未授权辅助功能时退化为「当前剪贴板文本」并回 `trusted:false`。三步都在 Dart 的剪贴板串行闸门内。

AX 与合成按键都要 **辅助功能（TCC）** 授权：设置页「查词」分类新增 macOS-only 动作项 `lookup.accessibility_permission`（`AXIsProcessTrustedWithOptions` 带 prompt + 打开隐私面板）。用户第一次明确触发全局查词且尚未授权时也会打开该面板，并停止本次捕获，避免把系统设置窗口误当成前台来源；应用启动时不主动弹窗，授权后再次触发即可按 Windows 语义读取选中文字。

## 4. 默认热键

macOS 默认键表整体 Ctrl→⌘，但 ⌘⌥D 是系统「打开/关闭 Dock 隐藏」符号热键，系统先吃、`RegisterEventHotKey` 永远收不到。`globalExternalLookup` 在 macOS 表里**保持 Ctrl⌥D**（`shortcut_defaults.dart`），可在快捷键设置页改。

## 5. 验证

- Windows/Linux CI 编不了 Swift：源码守卫 `fushi/test/native/macos_global_lookup_overlay_guard_static_test.dart` 钉通道名、Dart `_invoke` 出现的**每个** forward 方法都有 Swift `case`、五个反向调用、host JS 入口、deferred 列表与 Windows 路由一致、never-activate 契约、Xcode 接线。
- Mac 真机：`fushi/integration_test/macos_global_lookup_itest.dart`（`FUSHI_TEST_HIDDEN=1 FUSHI_TEST_INPUT=1`）——预热就绪 → `lookupText('猫')` → native `isShowing` → 经 env 门控的 `debugEvaluateJs` 读 root iframe DOM 文本含「猫 / ねこ」→ `debugSnapshot` 落 PNG → `hide` 后 `isShowing=false`。**2026-09-15 已在 Mac（macOS 27.0，flutter 3.41.6）跑通**：Swift 编译通过；宿主在 `fushi-popup://assets/` 下加载；deferred bridge（favoriteCheck / duplicateCheck）经 Dart 往返；宿主 `overlaySize`（geometryEpoch 1）→ `revealStack` 级联几何路径真跑（rAF 3 秒 183 帧）；截图可见完整卡片（词头「猫」+ 读音 + 词典名 + 释义 + 工具栏）。
- 真机验证的两个环境坑（都不是代码问题）：① Mac 显示器空闲熄屏时 WindowServer 把所有窗口判 occluded，WebKit 把 WKWebView 置 `document.hidden`、冻结 rAF，表现为「DOM 有字但不画、不回报 overlaySize、只走 450ms READY-SAFETY 兜底」——`tool/run_mac_itest.ps1` 现在先 `caffeinate -u` 唤醒；② Mac 上共用的 `~/dev/fushi-test-root` 可能被更新分支迁到更高 schema，旧分支开库直接 `FushiDatabaseDowngradeException`，换一个新目录当 `FUSHI_TEST_ROOT` 即可。
- 宿主 `global_lookup_host.js` 原本把 iframe 地址硬编码成 Windows 虚拟主机 `https://hibiki.popup/popup.html`，macOS 下 iframe 全空白；现改为按宿主自身 `location` 相对解析（Windows 解析结果不变，Node harness 无 location 时保留字面量）。
- 热键 / 侧键 / 点卡外关闭 / AX 取词需要辅助功能授权与真人操作，本轮为 `implemented_unverified`，待用户在 Mac 上授权后按上面链路人工验一次。
