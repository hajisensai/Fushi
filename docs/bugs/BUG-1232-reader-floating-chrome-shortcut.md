## BUG-1232 · 阅读器悬浮控制栏快捷键未驱动临时显隐状态
- **报告**：2026-07-29（用户：）
- **真实性**：✅ 真 bug。根因在 `hibiki/lib/src/pages/implementations/reader_hibiki/caret.part.dart:523-531` 与 `reader_hibiki/chrome.part.dart:908-1046`：`readerToggleChrome` 快捷键始终调用挤压模式旧入口 `_toggleChrome()`，只翻 `_showChrome`；默认悬浮模式真正决定是否画栏的是 `_chromeTransientVisible`，自动隐藏由 `_chromeAutoHideTimer` 驱动。鼠标点空白走 `_handleFloatingChromeReveal()`，所以能唤栏并计时；快捷键既不改真实可见态也不续期，表现为必须先鼠标激活，且旧计时到点仍在操作中途收栏。
- **[x] ① 已修复** — 新增 `_toggleChromeFromShortcut()`：底栏悬浮时复用鼠标空白点击的 `_handleFloatingChromeReveal()` 单一状态机（隐藏时取消计时、显示时从最新操作重新武装计时），并经 `FocusReclaimCause.chromeToggled` 重新确认正文焦点；底栏仍是挤压模式时保留 `_toggleChrome()` 原语义。快捷键与手柄动作统一改走该入口。
- **[x] ② 已加自动化测试** — 新增 `hibiki/test/reader/reader_floating_chrome_shortcut_guard_test.dart`，锁定 `readerToggleChrome → _toggleChromeFromShortcut` 接线、悬浮/挤压分流、统一焦点回收，以及显隐状态机对同一自动隐藏计时器的取消/重武装。
- **备注**：没有改鼠标空白点击、VN 空白推进或顶部进度条的既有语义；只修快捷键/手柄进入了错误的旧状态层。
