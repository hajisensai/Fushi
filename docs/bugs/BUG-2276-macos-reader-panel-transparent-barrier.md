## BUG-2276 · macOS 阅读设置/导航抽屉打开后点正文不关闭
- **报告**：2026-09-08（用户：Mac 上阅读设置和导航打开后，点击阅读器不会关）
- **真实性**：✅ 真 bug（静态定位，未在 Mac 真机复现——本轮无 macOS 设备）。根因是 BUG-1692 那套 macOS 平台视图命中模型的**另一面**：`FlutterCompositor` 只把「排在平台视图之后、**确实画了像素**的 backing-store 图层」的 `paint_region` 写进 `FlutterMutatorView._hitTestIgnoreRegion`，也只有落在忽略区里的鼠标事件会被 Flutter 截住。而阅读器的设置 / 导航抽屉走 `showReaderSideSheet`（`fushi/lib/src/reader/reader_desktop_chrome.dart:387-391`）：`barrierColor: Colors.transparent`（ッツ 形态不给正文压暗）——**透明遮罩一个像素都不画**，在 macOS 上等于不存在。点正文的鼠标事件因此直穿到 WKWebView，`barrierDismissible: true` 永远等不到那次点击，抽屉关不掉；同一下点击反而被正文当成翻页 / 查词 / 跳播执行了。Windows（WebView 是纹理）与 Android（hybrid composition）由 Flutter 统一派发指针，遮罩照常吃点击，故是 macOS 独有。
- **[x] ① 已根因修复** — 不给遮罩硬塞一层「几乎不可见」的颜色（那是拿观感换命中，还得赌 engine 的 cull rect 细节），而是接住 WebView **已经收到**的那次点击：
  - `fushi/lib/src/reader/reader_desktop_chrome.dart` 新增纯判据 `readerWebViewPointerClosesSideSheet({sideSheetOpen, readerRouteIsCurrent})`——两个条件缺一不可（只看旗会在关闭动画尾巴误吞一次正文点击；只看路由会把压在正文上的**实色**遮罩对话框也算进来）。
  - `reader_fushi/chrome.part.dart`：`_sideSheetOpen` 旗只在 `showReaderSideSheet` 两侧翻（`try/finally` 复位）；`_closeSideSheetForWebViewPointer()` 命中时走 `Navigator.maybePop()`（不绕过 PopScope，BUG-782 同族）并返回 true。
  - `reader_fushi/webview.part.dart`：七条正文 tap 桥（`onTap` / `onTapEmpty` / `onVnBlankTap` / `onLyricsTapEmpty` / `onSpreadTapEmpty` / `onImageTap` / `onCueTap`）入口统一先过门控，命中即 return，**吞掉**这次点击。
  - 其它平台判据恒假（遮罩吃掉点击，JS 侧根本不上报 tap），行为逐字不变。
- **[x] ② 已加自动化测试** — `fushi/test/tools/bug_2276_reader_side_sheet_dismiss_guard_test.dart`（6 例：纯判据三态行为 + 源码守卫「旗在抽屉两侧翻且 finally 复位」「七条 tap 桥都接了门控」「门控走 maybePop 而非裸 pop」）。
- **备注**：**未在 Mac 真机复测**（本轮无 macOS 设备）。滚轮 / 拖拽（`onWheelPaginate` / `onSwipe`）未纳入本轮：抽屉开着时在 macOS 上滚正文仍会翻页——同一根因的次要面，用户本次未报，留待真机确认后一并处理。
