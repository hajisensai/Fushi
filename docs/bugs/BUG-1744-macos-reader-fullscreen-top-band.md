## BUG-1744 · macOS 阅读器全屏下顶部残留 28pt 拖拽横带
- **报告**：2026-08-19（用户报「顶部横带」）
- **真实性**：✅ 真 bug。

  `fushi/lib/src/pages/implementations/reader_fushi_page.dart:2850-2864`（修前）无条件挂了一条
  `Positioned(top:0, height: kMacTitleBarHeight /* 28 */)` 的 `DragToMoveArea` + 不透明
  `ColoredBox(color: bgColor)`；配套的正文让位在 `:1842-1846`：

  ```dart
  double get _macosWindowTitlebarInset => Platform.isMacOS ? kMacTitleBarHeight : 0;
  double get _readerTopOffset => _stableTopInset + _macosWindowTitlebarInset + _topProgressReserve;
  ```

  **唯一条件是 `Platform.isMacOS`**。对 `reader_fushi_page.dart` + `reader_fushi/*.dart` 全量 grep
  `fullscreen|isFullScreen|WindowManipulator` **零命中**，而 macOS 全屏由
  `fushi/lib/src/shortcuts/global_navigation.dart:368-376` 的 `WindowManipulator` 驱动。
  于是进原生全屏后：既没有标题栏也没有交通灯、窗口也拖不动，这条 28pt 不透明带和它同高的正文
  让位仍在 —— 就是用户看到的顶部横带。

  连带影响（同一真相源）：`popupTopReserve`（`:1857`）、`reader_chrome_floating.dart:111-123` 的
  `independentDocumentInsets`（歌词 / spread 整页图被顶掉 28px，露出 Scaffold 底色，是横带**最容易
  被肉眼看见**的场景）、顶部进度 pill（`chrome.part.dart` 的 `_stableTopInset + _macosWindowTitlebarInset`）。
  CSS 侧 `--chrome-top-inset` 由 `_readerTopOffset` 喂入（`webview.part.dart:685` 首载、
  `chrome.part.dart:1043-1047` 运行时 `setChromeInsets`），所以正文顶部实际留白 = 28 + 24 = 52px。

  `didChangeDependencies`（`:2682-2701`）只比较 `viewPadding.top/bottom`，**不监听全屏切换**；
  桌面进出全屏时 viewPadding 通常不变（两边都是 0），那条回喂路径永远不会触发。

- **[x] ① 已修复** — 提交见本分支。
  - 新建 `fushi/lib/src/platform/macos_fullscreen_state.dart`：macOS 原生全屏态的**唯一真相源**，
    挂 `NSWindowDelegate` 的 `windowDidEnterFullScreen` / `windowDidExitFullScreen`，暴露
    `ValueListenable<bool>`，并在注册后补一次 `isWindowFullscreened()` 查询作初值（系统可能恢复了
    上次的全屏会话）。非 macOS 恒 false 且不注册。
    **为什么不用别的信号**：`WindowManipulator.isWindowFullscreened()` 是异步查询、无变化通知，
    只能轮询；`window_manager` 的 `WindowListener` 在 macOS 上收不到全屏通知（macos_window_utils
    持有 NSWindow.delegate 并覆盖了它，见 `global_navigation.dart` 的 TODO-1375）；只在 app 自己的
    F11 快捷键里记状态会漏掉**绿灯按钮和「显示」菜单**——那是用户进全屏最常用的两条路。
    AppKit 的 delegate 回调是唯一覆盖全部入口的信号。
    依赖走 `package:macos_ui`（它 re-export 了 `NSWindowDelegate` 与 `WindowManipulator`），
    与 `global_navigation.dart` 同款，避免 `depend_on_referenced_packages`。
  - `reader_fushi_page.dart`：`_macosWindowTitlebarInset` 改为
    `Platform.isMacOS && !_macosFullscreen ? kMacTitleBarHeight : 0`（单一真相源，
    `_readerTopOffset` / `popupTopReserve` / `independentDocumentInsets` / 顶部进度 pill 全部自动跟随）；
    `DragToMoveArea` 那个 `Positioned` 整体门控 `if (Platform.isMacOS && !_macosFullscreen)`
    （只归零 inset 不够，带子本身仍会盖住正文）；initState 订阅 + dispose 摘钩；
    新增 `_onMacosFullscreenChanged()` —— **setState 之外必须调 `_applyChromeInsets()`**，
    因为 JS 的 `--chrome-top-inset` 由它单独推送、不跟 Flutter 重建走，漏了它正文 padding-top
    会停在旧的 28px 上（横带原样还在）。

- **[x] ② 已加自动化测试** —
  - `fushi/test/macos/macos_shell_fullscreen_sidebar_test.dart` 新增 BUG-1744 组：
    inset 必须按全屏态门控、`DragToMoveArea` 的 `Positioned` 必须整体门控（取窗为 `build()`，
    不是 `_buildBody()`）、状态必须取自 `MacosFullscreenState`、delegate 必须同时实现
    enter/exit 两个回调（只监听进入的话退出全屏后横带不会回来）、`_onMacosFullscreenChanged`
    必须同时 setState + `_applyChromeInsets`、dispose 必须摘监听。
  - BUG-1343 的既有守卫（`DragToMoveArea(` / `'fushi_reader_window_drag_area'` /
    `kMacTitleBarHeight` / `_macosWindowTitlebarInset` / `_readerTopOffset =>` /
    `titlebarInset:` / `_stableTopInset + _macosWindowTitlebarInset`）全部锚点保留、未改动，仍绿。
  - 验证：`flutter test test/macos/ --no-pub` → 13 passed。

- **备注**：**须 Mac 真机复验**（headless 无真 NSWindow，delegate 回调跑不到）：窗口态下拖拽带
  仍在且可拖动 → F11 / 绿灯 / 「显示」菜单三条路进全屏，横带消失且正文顶到边 → 退出全屏后
  拖拽带回来。歌词模式 / spread 整页图两种独立文档场景一并验（它们走
  `independentDocumentInsets`，是横带最显眼的场景）。
  与 [[BUG-1745]] 同为本轮 macOS 阅读器体感问题，但两者根因无关、可独立回滚。
