## BUG-1343 · macOS窗口化阅读器缺少可拖拽区域
- **报告**：2026-08-01（用户：窗口化阅读时不知道从哪里拖动，三指拖移无法移动窗口）
- **真实性**：✅ 真 bug。macOS 启动无条件启用透明标题栏和 full-size content view；默认 `auto=MD3` 又不会挂根 `MacosWindow/ToolBar`，阅读器的原生 WebView 遂从窗口顶边铺满且没有显式拖动目标。透明标题栏本身不会把 WebView 变成可拖背景，导致窗口化阅读几乎没有稳定抓手。根因与修复点见 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1608-1626,2599-2613`。
- **[x] ① 已修复** — `c3796c723`, `6b048241c`：macOS 阅读器增加 28pt `DragToMoveArea` 标题栏带，复用 `kMacTitleBarHeight`；正文分页、词典弹窗、顶部进度 pill 共享 `_macosWindowTitlebarInset`。不注入正文引擎的歌词和 spread 独立文档改由 Flutter 侧真实缩进，避免拖动层盖住首行/整页图。其它平台恒为 0；没有改变窗口 frame，也没有擅自切原生 Spaces 全屏。
- **[x] ② 已加自动化测试** — `macos_shell_fullscreen_sidebar_test.dart` 锁定显式拖动区、稳定 key、标准标题栏高度、正文/进度/独立文档避让接线；`spread_chrome_escape_guard_test.dart` 与既有 fullscreen 单一 NSWindow owner 守卫继续通过。
- **备注**：三指拖移还取决于 macOS“辅助功能 → 指针控制 → 触控板选项”是否启用；应用侧现在提供了正确拖动目标。按用户要求本次不等待真机编译/窗口移动验收，仍待设备复测鼠标拖动、三指拖移及 F11 进出全屏。
