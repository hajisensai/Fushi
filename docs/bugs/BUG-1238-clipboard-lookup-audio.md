## BUG-1238 · 剪贴板变更查词不应自动播放音频
- **报告**：2026-07-29（用户：）
- **真实性**：✅ 真 bug。主窗口词典页已在
  `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:234`
  对桌面请求传 `autoRead: false`，但常驻剪贴板面板的
  `hibiki/lib/src/lookup/clipboard_panel_controller.dart:282` 与瞬态覆盖窗的
  `hibiki/lib/src/lookup/global_lookup_controller.dart:681` 仍在剪贴板变更查词完成后
  无条件触发自动朗读，导致不同剪贴板去向行为不一致。
- **[x] ① 已修复** — `DesktopLookupRequest.allowsAutomaticAudio` 将剪贴板变化与
  热键/显式点词区分；常驻面板和瞬态覆盖窗只在请求允许时自动朗读，面板横幅点字、
  卡内点词等手动路径保持原行为。提交：`498074ecf`。
- **[x] ② 已加自动化测试** —
  `hibiki/test/sync/desktop_lookup_service_test.dart` 验证剪贴板与显式请求的朗读资格；
  `hibiki/test/lookup/desktop_lookup_dispatcher_test.dart` 和
  `hibiki/test/lookup/overlay_auto_read_parity_test.dart` 守住两个消费面的来源接线。
- **备注**：按用户要求不等待编译验收；本轮只做格式化、源码/差异静态检查。
