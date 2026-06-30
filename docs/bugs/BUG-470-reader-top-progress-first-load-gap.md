## BUG-470 · 首屏顶部进度 inset 缺口（正文首行被进度条压住）
- **报告**：2026-06-30（用户：·独立 code-review Reviewer A 定位）
- **真实性**：✅ 真 bug。TODO-975（reader chrome 悬浮化）引入的回归。
- **[x] ① 已修复** — `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart:749`（`_refreshProgress` 内顶部进度上升沿补推 inset）
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_top_progress_first_load_inset_guard_static_test.dart`（源码守卫）
- **备注**：提交 `23fd57051c44bd0297e79a97b6a05d4c499a60d7`（分支 fix-975-top-inset-gap，integration 合并后哈希可能变）

### 根因（file:line）
- `_readerTopOffset = _stableTopInset + _topProgressReserve`（`reader_hibiki_page.dart:1174`）。
- `_topProgressReserve` 经 `_showTopProgress` 门控（`reader_hibiki_page.dart:1118-1123`），后者要求 `_progressCurrentChars != null && _progressTotalChars != null && _progressTotalChars! > 0`。
- 这两个字段在 `_refreshProgress`（`navigation.part.dart`，原 :730-735）才首次置值，**晚于** `_onRestoreComplete` 里 `_reapplyChromeInsetsAfterFirstLoad()`（`navigation.part.dart:101`）与首载 setup 脚本注入的 `--chrome-top-inset`（`webview.part.dart:350`，取 `_readerTopOffset`）。
- 默认顶部进度 ON 时首次开书：注入的 WebView 顶部 inset 漏掉 18px（`_showTopProgress` 此刻仍 false → `_topProgressReserve=0`），随后进度测出、Flutter 侧 strip 占 18px 绘出，但**没有任何路径在 `_progressTotalChars`/`_progressCurrentChars` 由 null/0→正 的跃迁上重推 inset**（`_applyChromeInsets` 仅由 toggle / `_reapplyChromeInsetsAfterFirstLoad` / pref-change 触发，进度刷新路径从不调）。
- 结果：正文首行被顶部进度条压住，直到下次样式变更/切主题/toggle 底栏/旋屏触发 inset 重推才自愈。TODO-975 之前 `_readerTopOffset` 无条件含 18px，故无此问题。

### 修复
在 `_refreshProgress` 写 `_progressCurrentChars`/`_progressTotalChars` 处，捕获 rebuild 前后的 `_showTopProgress`（顶部预留的唯一门控真相源），仅在它由 false→true 的**上升沿**补一次 `_applyChromeInsetsAndReanchor()`：先下发含 18px 顶部预留的新 chrome inset，再走 begin→commit 重锚把阅读位置滚回（连续模式裸改 inset 会 reflow 归零弹回章首；分页模式 JS 侧整体 no-op）。
- 只在上升沿补推，避免每次进度刷新（轮询 10s / 滚动）都重推 inset 造成抖动。
- 不破坏 restore 位置：`_applyChromeInsetsAndReanchor` 复用既有样式重锚编排（采锚→换 inset→滚回），不丢阅读位置。
- 与 BUG-467（底栏首载预留闭合，`_reapplyChromeInsetsAfterFirstLoad`）、973 手柄沉浸、`_lyricsMode` 早返回正交共存（歌词模式由 `_applyChromeInsets` 自身的 `_lyricsMode` 早返回挡掉）。

### 测试
源码守卫 `reader_top_progress_first_load_inset_guard_static_test.dart`：钉死 `_refreshProgress` 在「顶部进度 false→true 上升沿」补推 inset 的不变式——
1. `_refreshProgress` 含 `final bool topProgressWasShown = _showTopProgress;`（rebuild 前快照门控）。
2. 含 `if (!topProgressWasShown && _showTopProgress)` 上升沿判据后调 `_applyChromeInsetsAndReanchor()`。
3. `_topProgressReserve` 仍经 `_showTopProgress` 门控（预留真相源不被绕过）。

reader 页含真实 `InAppWebView` 平台视图，widget 测试无法挂载整页、无法观测首载 inset 注入的真实帧，故以结构守卫钉死门控不变式（沿用 `reader_bottom_chrome_gate_static_test.dart` 范式）。
