## BUG-1981 · Hook 浮窗 HWND 失效后自动与手动打开都无窗口
- **报告**：2026-08-31（用户：「游戏的hook浮窗打不开了，点击hook浮窗按钮也打不开」）
- **真实性**：✅ 真 bug。`fushi/windows/runner/floating_lyric_window.cpp:398` 的 `Show()` 只判 `hwnd_ == nullptr`，没有像 `GlobalLookupWindow` 一样核对 `IsWindow + GWLP_USERDATA`；HWND 被 `WM_CLOSE`/外部 teardown 销毁后，成员仍非空，`ShowWindow`/`SetWindowPos` 对死句柄失败但函数无条件回 `true`。同时 `fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:716` 只信上次 `show=true` 的 `_visible` 镜像，后续自动同步只发 `updateText`，手动入口也可能再次接受假成功，故屏幕始终没有窗口。
- **[x] ① 已修复** — `ad52944d70`：Win32 侧新增 `OwnsLiveWindow()`（含 back-pointer 防 HWND 复用）、在 `WM_NCDESTROY` 生命周期边界清句柄/交互状态、`Show()` 先丢死句柄再重建并在 `SetWindowPos` 失败时回 `false`；Dart 每轮显示同步用 `isShowing()` 对账真实 HWND，失配即重走 `show`。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_hook_overlay_window_lifetime_guard_test.dart` 钉死 Win32 所有权/销毁/失败应答不变量；`fushi/test/lookup/gal_hook_text_overlay_controller_test.dart` 模拟 Dart 仍记可见而 native HWND 已消失，断言下一行会再次调用 `show`。
- **备注**：聚焦 Flutter 测试在执行任何 case 前被 `pdfium_dart` 下载 `pdfium-win-x64.tgz` 的 GitHub release-assets 超时阻塞；未做 Windows 构建、真实游戏/设备 E2E，不能把本条记为真机已验证。
