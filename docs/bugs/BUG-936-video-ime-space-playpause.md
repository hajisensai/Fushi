## BUG-936 · 日文IME激活时视频页空格无法播放暂停（BUG-853 修复真机仍失效）
- **报告**：2026-07-20（用户：非沉浸模式下空格播放失效，日文空格还是没办法使用）
- **真实性**：✅ 真 bug，是 BUG-853 修复无效的真机反证；根因同 BUG-430（2026-11-05 真机定案）：被 IME 吃掉的空格以 `VK_PROCESSKEY` 到达，Flutter 嵌入层不发任何 KeyEvent（`engine/src/flutter/shell/platform/windows/keyboard_key_embedder_handler.cc:177-183`），所以无论判据是 `logicalKey == process` 还是放宽后的 `physicalKey == space && logicalKey != space`，Dart 侧都看不见这个键。BUG-1239 随后在顶层 `FlutterWindow::MessageHandler` 拦 `VK_PROCESSKEY` + scan 0x39 的 runner 通道同样无效：键盘消息只投给持焦的 `FLUTTERVIEW` 子窗口，顶层窗口过程收不到（真机诊断零触发）。证据表见 [BUG-430](BUG-430-win-ime-shortcut-fallback.md)。
- **[x] ① 已修复** — 由 BUG-1450 的 IME 解除关联守卫修复（`fushi/windows/runner/ime_association_guard.cpp` + `fushi/lib/src/platform/windows_ime_guard.dart`，`7a99dbf2ee6`）：真机 MS-IME 平假名态下视频页空格以真实 `0x20` 到达、命中 `videoTogglePlayPause`。本条放宽判据（`eaa568cd9`）与 BUG-1239 的 runner 空格通道在 `cf9e9661e4` 删除。
- **[x] ② 已加自动化测试** — 见 BUG-430：`fushi/windows/runner/tests/ime_association_guard_test.cpp` 真 HWND 契约用例（变异实测转红）+ `fushi/test/shortcuts/ime_process_key_reachability_guard_test.dart` 源码守卫；合成事件假绿测试已删。
- **备注**：教训——IME 吞键类问题在 Dart 判据层永远看不见，先抓 Win32 `WM_KEYDOWN` 的 wParam 与 `ImmGetContext` 再下结论。
