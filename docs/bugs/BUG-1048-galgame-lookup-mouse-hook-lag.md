## BUG-1048 · galgame 查词后鼠标移动全局卡顿（WH_MOUSE_LL 装在 Flutter 主线程）
- **报告**：2026-07-24（用户：玩 galgame 时「点击查词鼠标移动都会变卡，不查就没事」）
- **真实性**：✅ 真 bug —— 根因 `hibiki/windows/runner/global_lookup_window.cpp:456`（修复前；`Reveal` 与 `RevealStack` 两处相同代码）在 **Flutter platform 线程**上 `SetWindowsHookEx(WH_MOUSE_LL, ...)`。

  `WH_MOUSE_LL` 是**同步**低级钩子：系统把每一个鼠标输入事件（含高频移动）投递到安装钩子那条线程的消息队列，等它返回或超时（`LowLevelHooksTimeout`，默认 300ms）才继续分发给前台程序。装在 platform 线程上，等于让全系统鼠标输入排在 Dart/Flutter 的帧与 platform channel 之后——galgame 会话里主线程本就在跑 hook 台词轮询 + 工作台页面重建 + 查词 WebView2，于是查词浮窗一出现，鼠标移动就跟着主线程忙闲一卡一卡；浮窗关闭（`Hide()` 卸钩子）即恢复，正好对上「不查就没事」。

  回调本身对移动事件已是纯比较后 `CallNextHookEx`，所以问题不在回调工作量，而在**它所在的线程**。
- **[x] ① 已修复** — 新增 `hibiki/windows/runner/low_level_mouse_hook.{h,cpp}`：进程级钩子承载线程（只跑 `GetMessage` 循环），`Arm`/`Disarm` 经 `PostThreadMessage` 装卸钩子；回调只读目标 HWND 几何（`GetWindowRect` + `PtInRect`）并 `PostMessage`（异步）把「屏幕坐标 + 是否落在窗口内」投回窗口线程，绝不 `SendMessage`。`GlobalLookupWindow` 侧：`MouseHookProc` 改为窗口线程上的 `HandleGlobalClick`，`HHOOK mouse_hook_` 改为每实例 `bool mouse_hook_armed_`（常驻剪贴板面板仍从不 arm，其 `Hide()` 不会卸掉瞬态查词覆盖窗的点击外关闭）。点击外关闭 / 转发给 host 的判定语义一字未改。
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_mouse_hook_thread_guard_test.dart`（源码守卫：查词窗口不得自行 `SetWindowsHookEx`；钩子文件必须有 `std::thread` + `GetMessage`；回调只 `PostMessage` 不 `SendMessage`；新源文件已进 runner CMake 目标）。纯 Win32 输入队列行为无法在 Dart 侧行为测试里复现，源码守卫是当前最强可落地层。
- **备注**：native 改动，**待 Windows 真机复测**原始失败路径（galgame 会话中查词后移动鼠标）。
