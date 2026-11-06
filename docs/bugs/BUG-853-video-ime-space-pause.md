## BUG-853 · 日语输入法激活时视频页按空格无法暂停
- **报告**：2026-07-16（用户：）
- **真实性**：✅ 真 bug，与 BUG-430 同一根因（2026-11-05 真机定案）：视频页 `FLUTTERVIEW` 在无文本焦点时仍关联 IME context，MS-IME 平假名态把空格（即使没有组字）投成 `WM_KEYDOWN wParam=VK_PROCESSKEY`，Flutter 嵌入层直接丢弃（`engine/src/flutter/shell/platform/windows/keyboard_key_embedder_handler.cc:177-183`），视频页根本收不到空格。原记录的根因「IME 把 Space 的 logicalKey 改写成 `process`」不成立（`process` 原生端不可达，BUG-1432）。真机证据与修复点见 [BUG-430](BUG-430-win-ime-shortcut-fallback.md)：无守卫时空格 0xE5、Dart 零事件；有守卫（`fushi/windows/runner/ime_association_guard.cpp`，BUG-1450）时视频页 4 次空格均以真实 `0x20` 到达并命中 `videoTogglePlayPause`，含按过字母之后。
- **[x] ① 已修复** — 由 BUG-1450 的 IME 解除关联守卫修复（`7a99dbf2ee6`），2026-11-05 真机证实。本条当年加的 `process` 回退（`97fcba434`）与 BUG-936 放宽后的 `isVideoImeSpacePlayPause` 已在 `cf9e9661e4` 删除（不可达死代码）。
- **[x] ② 已加自动化测试** — 见 BUG-430：`fushi/windows/runner/tests/ime_association_guard_test.cpp` 真 HWND 契约用例（已变异实测转红）+ `fushi/test/shortcuts/ime_process_key_reachability_guard_test.dart` 源码守卫。原合成 `process` 事件的假绿测试 `video_ime_space_playpause_test.dart` 已删。
- **备注**：Space 在 MS-IME 平假名态空闲时就会被吃（插全角空格），比字母更敏感，所以日文用户最先在视频页报这个键。
