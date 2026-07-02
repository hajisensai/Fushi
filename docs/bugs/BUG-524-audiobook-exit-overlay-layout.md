## BUG-524 · Audiobook退出快捷设置后红屏
- **报告**：2026-07-02（用户：）
- **真实性**：✅ 真 bug。macOS 真实导入 SRT+MP3 有声书后进入 reader，打开右下快捷设置并点击「退出」，复现 Flutter 红屏：`A _RenderLayoutBuilder was mutated in _RenderLayoutBuilder.performLayout`，错误日志时间 `2026-07-02 01:33:03`。根因是 `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart:1633` 的退出按钮在 `Navigator.of(context).pop()` 关闭快捷设置 overlay 后，仍在同一布局/overlay 激活帧同步调用 `widget.onExitReader()`；调用方 `hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart:1029` 继续 pop reader，reader dispose 路径 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1639` detach 有声书并在 `hibiki/lib/src/media/audiobook/audiobook_session.dart:235` 同步清空 session + `notifyListeners()`，导致 overlay/layout 树在 performLayout 期间被重入修改。
- **[x] ① 已修复** — `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart:1633` 先捕获 `widget.onExitReader`，关闭快捷设置 overlay 后用 `WidgetsBinding.instance.addPostFrameCallback` 在下一帧触发 reader 退出，让 overlay 本帧 layout/activate 完成后再释放有声书 session；同时用 `_exitScheduled` 防止重复键盘/焦点激活调度多次退出。提交：本提交。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart` 新增 BUG-524 源码守卫，断言退出动作必须先 `Navigator.pop`，再经 `WidgetsBinding.instance.addPostFrameCallback` 调用捕获的 `exitReader()`，且不得同步 `widget.onExitReader()`；`hibiki/test/media/audiobook/audiobook_play_bar_theme_chip_test.dart` 新增 widget 行为测试，断言点击退出后当前 tick 不触发 reader 退出、下一帧才退出，重复触发最多调度一次。
- **验证**：
  - `flutter test test/media/audiobook/reader_quick_settings_sheet_static_test.dart`
  - `flutter test test/media/audiobook/audiobook_play_bar_theme_chip_test.dart test/media/audiobook/reader_quick_settings_sheet_static_test.dart test/utils/misc/import_crash_breadcrumb_test.dart`
  - `flutter build macos --debug`
- **备注**：原始 macOS GUI 失败路径（SRT+音频书 → 快捷设置 → 退出）尚未完成复测。阻塞点不是业务断言失败，而是当前本机 macOS 调试窗口可被 `screencapture -l` 截到、但 Computer Use / CGEvent / 焦点集成测试都无法接管；`integration_test/desktop_settings_smoke_test.dart -d macos` 也停在 focus traversal 只到 1 个目标。修复仍需下一轮能操作真窗口后复验。
