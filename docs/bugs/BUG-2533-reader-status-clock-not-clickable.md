## BUG-2533 · 阅读器状态行/播放条的计时图标点不动，改成真正的 MD3 停续键
- **报告**：2026-09-14（用户：截图指底部右端那颗秒表 + `0:01`，要求「干掉换成 MD3 的 icon、做成可实际点击开启或者关闭统计计时」）
- **真实性**：✅ 真 bug。两处画的都是**纯装饰**的秒表字形，没有任何 MD3 可点性：
  - `fushi/lib/src/reader/reader_status_footer.dart:540`（`ReaderStatusInline`，播放条右端）——
    整块 `Row` 里只有 `Icon` + `Text`，**不接任何指针**：`ReaderStatusInline` 此前根本没有
    回调参数，`chrome.part.dart` 的 `_buildBarStatusText()` 也没处可传。用户截图正是这一态
    （有声书播放条唤出，状态行按 BUG-2467 整条让位），所以屏幕上写着「计时中」的那颗图标
    点一百下都不会停表。
  - `fushi/lib/src/reader/reader_status_footer.dart:401`（`ReaderStatusFooter`）——功能上能停表
    （`onTapTracker` 挂在外层 `_hitTarget` 的 `GestureDetector` 上），但**看不出可点**：没有
    state layer、没有 ripple、没有 tooltip，图标本身只是个字形。
- **[x] ① 已修复** — 新增 `ReaderStudyClockButton`（`reader_status_footer.dart`）：真的 MD3
  `IconButton`（state layer + ripple + tooltip），计时中画 `Icons.pause_rounded`、已停画
  `Icons.play_arrow_rounded`，与统计侧栏那颗暂停键（`reader_statistics_sheet.dart` 的
  `_SessionClock`）同图标、同 i18n 文案、同一个 `_toggleStudyClockManualPause` 入口。
  两种底部形态都换上它；`ReaderStatusInline` 补 `onToggleTimer` 并在 `chrome.part.dart`
  的 `_buildBarStatusText()` 接上。按钮边长 = 状态行行高（28，铁律：视觉高 == 预留高，
  故显式 `tapTargetSize: shrinkWrap`，否则默认 48dp 触摸靶会把状态行撑成 48 挤正文），
  播放条里 32；两处都包 `ExcludeFocus`（TODO-700：这两面是纯指针面，不进焦点遍历池）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_status_footer_test.dart`：
  状态行「图标本身是按钮且点了触发停/续、按钮与整条行高都恒为 28」「⏸/▶ 随计时态互换」
  「不进焦点环（`canRequestFocus == false`）」；新增 `inline` 组（此前内联形态零覆盖）
  「播放条里那颗图标真的可点」「随计时器开关一起隐藏、与进度段互不连带」。
- **备注**：无新增 i18n（复用既有 `reader_stats_clock_pause` / `reader_stats_clock_resume`）。
  像素证据走 widget test 真实像素预览（改动只在 Flutter chrome 层，不涉 WebView 排版）。
