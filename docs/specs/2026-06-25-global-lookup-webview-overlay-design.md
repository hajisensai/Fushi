# 全局查词设计 · 裸 WebView2 覆盖窗（TODO-617）

> 状态：设计已与用户确认（2026-06-25），待写实现计划。
> 范围：Windows MVP。mac/Linux 后续。

## 1. 目标与非目标

### 目标（yomitan 式全局查词）
- 在**任意外部 app**（浏览器、PDF、文档）里选中文字，按全局热键，在光标处弹出 Hibiki 词典卡片。
- 卡片是真正的词典弹窗（和 app 内查词一模一样的渲染：释义、频率、音高、外字图、发音）。
- 不打扰外部 app 的正常使用。
- 按一下出现，`Esc` / 点卡片外区域 / 再按热键 收起。

### 非目标（MVP 明确不做）
- ❌ 「按住热键才显示、松开消失」的语义（需低级键盘钩子，砍掉）。
- ❌ 在全局查词卡片里制卡 / 收藏（只读 MVP；要挖词时一键跳主 app 打开完整卡片）。
- ❌ 第二个 Flutter engine / 多窗口框架。
- ❌ 隐藏主窗到托盘 + 唤回（主窗保持普通任务栏 app）。
- ❌ mac / Linux（后续迭代）。

## 2. 核心判断（为什么这样设计）

把数据结构看清楚后，全局查词只有**两个真问题**：① 从外部 app 拿到选中文字；② 在光标处画一张不抢焦点的卡片。其余都是衍生。

- **拿文字**：Windows 跨 app 唯一可靠方式 = 注入 `Ctrl+C` → 读剪贴板 → 还原旧剪贴板。
- **画卡片**：用**裸 Win32 分层窗 + WebView2 控件**渲染现有 `popup.html`，**不起 Flutter 窗口**。这正是 Hibiki Android 已有的 native `:popup` 进程思路（无 Flutter engine、原生 WebView 渲染同一份 `popup.html`）的 Windows 移植。

**裸 WebView2 而非第二 Flutter engine 的理由**（消除三个固有代价）：
1. 第二 engine 会把词典索引再 mmap 一份 → 内存翻倍。
2. 第二个 `HibikiDatabase` 连接 + 写竞争。
3. 最大风险：`flutter_inappwebview_windows` 的 WebView2 surface 绑在**主 FlutterView 的 HWND** 上（`in_app_webview.cpp:1729` 等），第二个 `FlutterViewController` 能否正确注册插件、绑对 HWND 是整条路最大未验证点。裸 WebView2 绕开全部三条。

**查词放主 Dart engine（而非 native C++ 直查）的理由**：查词编排、词典启用/排序/折叠设置、发音解析、`popupJson` 生成逻辑全在 Dart 且久经考验。在 C++ 重写一份（Android `:popup` 的做法）会与 Dart 逻辑发散。保持单一查词大脑。

## 3. 组件与边界

| 组件 | 语言 | 职责 | 新/复用 |
|---|---|---|---|
| 主 Flutter 窗口 | Dart | 词典大脑：HoshiDicts FFI + AppModel + DB + 注册全局热键。**不动** | 复用 |
| `GlobalLookupController` | Dart | 编排：热键 → 抓选区 → 查词 → 推送 → 收起 | 新 |
| 选区抓取 FFI | Dart ~80 行 | `SendInput` 注入 Ctrl+C + 剪贴板存取/还原 | 新（照抄 `desktop_foreground_guard.dart:54-72` 的 user32 FFI 范式）|
| WebView2 覆盖窗 | C++ | Win32 分层/置顶/不激活窗 + WebView2 控件，载 `popup.html` | 新（照抄 `windows/runner/floating_lyric_window.cpp` 的「native 窗 + channel」范式）|
| 覆盖窗 channel | Dart↔C++ | 3 根渲染线 + 生命周期（show/hide/dismissed） | 新 |
| `popup.html/js/css` | JS | 卡片渲染 | **整套复用** |
| bridge adapter | JS | 把 `window.flutter_inappwebview.callHandler` 映射到 `window.chrome.webview.postMessage` | 新（薄注入层，不改 popup.js 主体）|

每个组件能独立理解、独立测试：
- 选区抓取 FFI：输入「无」，输出「当前选区文本 or null」，副作用「剪贴板被还原」。
- WebView2 覆盖窗：输入「位置 + popupJson + 媒体回调」，输出「屏上一张卡 + 用户交互事件」。
- `GlobalLookupController`：把上面两者 + `AppModel.searchDictionary` 串起来。

## 4. 数据流（一次查词）

```
全局热键
  → captureForegroundWindow()        记住前台窗 HWND（为了收起后还焦点）
  → injectCopyReadSelection()        存旧剪贴板 → SendInput Ctrl+C → 等前台写入(复用 BUG-114 有界重试)
                                      → 读=选区文本 → 还原旧剪贴板 → 抑制 clipboard_watcher 自触发
  → AppModel.searchDictionary(text)  复用现成，FFI 直吐 popupJson（自包含）
  → channel.showAt(cursorRect, json) native 把覆盖窗摆光标处、显示、把 JSON 注入 WebView2
  → window.renderPopup()             复用 popup.js 画卡

外字图：WebView2 WebResourceRequested(image://?dictionary=...&path=...)
        → native → channel → Dart HoshiDicts.instance.getMediaFile(dict, path) → bytes 回灌
发音  ：popup.js callHandler('resolveWordAudio'/'playWordAudio')
        → adapter → chrome.webview.postMessage → native → channel → Dart（复用现有解析/播放）
收起  ：Esc(WebView2 keydown) / 点卡外(命中透明区) / 再按热键
        → channel.hide() → SetForegroundWindow 把焦点还给原前台窗
```

## 5. 「不打扰 app」的三道保证

1. **idle 覆盖窗不显示** —— 平时没有任何窗、不抢任何东西，外部 app 完全正常。
2. **只有全局热键触发抓选区** —— 不轮询剪贴板、不监听选择事件，只有按键那一刻才注入 Ctrl+C。
3. **`WS_EX_NOACTIVATE` 永不抢焦点** —— 卡片浮在外部 app 上但键盘焦点仍在外部 app；收起后 `SetForegroundWindow` 把焦点还回去。

## 6. 复用 vs 新增

**复用**：`popup.html/js/css` 整套渲染、`AppModel.searchDictionary`（`app_model.dart:2350`）、`HoshiDicts`（含 `lookupPopupJson`/`getMediaFile`）、`floating_lyric_window.cpp` 的 native 窗 + channel 范式、`desktop_foreground_guard.dart` 的 user32 FFI 范式、剪贴板有界重试（`desktop_lookup_service.dart:216-227`）。

**新增**：`GlobalLookupController`、选区抓取 FFI、WebView2 覆盖窗 native + channel、bridge adapter。

## 7. 三个待验证的真风险（实现前打样）

1. **裸 WebView2 载 `popup.html` 本地资源 + `image://` 拦截**：用 WebView2 `SetVirtualHostNameToFolderMapping`（映射 popup 资源目录）+ `WebResourceRequested`（拦 `image://` 外字图）。gaiji 字节回灌需真机验。
2. **bridge adapter**：popup.js 现用 `window.flutter_inappwebview.callHandler`，裸 WebView2 是 `window.chrome.webview`。注入一层 adapter 映射 `callHandler(name, args)` → `postMessage({handler:name, args})`，**不改 popup.js 主体**。WebView2 → JS 回值用 `postMessage` 回传 + Promise 配对。
3. **复用 `flutter_inappwebview_windows` 已有的 WebView2 SDK 集成**：仓库里 `packages/flutter_inappwebview_windows` 已经集成了 WebView2 SDK（`webview_environment_manager.cpp` 等）。优先复用其 WebView2 环境创建代码，避免从零搭。

## 8. 测试策略

- **选区抓取 FFI**：纯函数化「剪贴板存取/还原」+ 单测（注入逻辑可 mock SendInput）。
- **bridge adapter**：node/JS 单测，验 `callHandler` → `postMessage` 映射 + 回值配对。
- **渲染**：`popupJson` → WebView2 真机截图取证（焦点驱动集成测试，见 `docs/agent/integration-testing.md`）。
- **守卫（源码扫描）**：① 覆盖窗带 `WS_EX_NOACTIVATE`；② 热键只注册 keyDown（不引入低级键盘钩子）；③ 不引入 `tray_manager` / 第二 Flutter engine。

## 9. 分期

- **M0 打样**：裸 WebView2 窗载 `popup.html` + 静态 `popupJson` 渲染出卡 + `image://` 拦截外字图（验风险 1/3）。
- **M1 抓选区**：选区抓取 FFI + 全局热键 → 查词 → 推送 → 渲染（端到端，Windows MVP 核心）。
- **M2 收起 + 还焦点**：Esc / 点卡外 / 再按热键 → hide + `SetForegroundWindow`。
- **M3 发音**：bridge adapter 接 `resolveWordAudio`/`playWordAudio`（风险 2）。
- **M4 打磨**：嵌套查词（卡里查词）、热键可配、多显示器定位。
- 后续：mac / Linux。

## 10. 已知遗留 / 决策记录

- 热键：现 `Ctrl+Shift+D` 已被「桌面剪贴板查词」（`desktop_lookup_service.dart:132-137`）占用。全局查词**另设可配热键**，避免语义打架（具体键位实现时定）。
- 嵌套查词在裸 WebView2 里走 popup.js 已有的栈逻辑，覆盖窗给足屏幕空间即可，不需要 Flutter 侧 `DictionaryPopupController`。
- 制卡/收藏降级：卡片上保留入口，点击 → `postMessage` → 主 app 打开完整查词页（不在覆盖窗里完成写操作）。
