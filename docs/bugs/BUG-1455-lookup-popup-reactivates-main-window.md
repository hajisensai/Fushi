## BUG-1455 · 拖动或缩放查词弹窗会把主窗口抬到前台
- **报告**：2026-08-02（用户：查词弹窗拖动或从右下角缩放时，Hibiki 主窗口被抬到前台）
- **真实性**：✅ 真 bug。查词面板由 `hibiki/windows/runner/global_lookup_window.cpp:1528` 的 `WM_NCLBUTTONDOWN` 进入系统 move/size 循环并成为活动窗口；主窗口随即收到 `WM_ACTIVATE/WA_INACTIVE`，但 `hibiki/windows/runner/win32_window.cpp:287` 原来不区分激活与失活，两种情况都会 `SetFocus(child_content_)`，把焦点和 Z 序抢回主窗口。
- **[x] ① 根因修复** — 主窗口只在 `WA_ACTIVE/WA_CLICKACTIVE` 且 Flutter 子 HWND 仍存活、仍属于当前主 HWND 时恢复焦点；查词弹窗接管激活以拖动/缩放时，主窗口不再反向抢焦点。`Win32Window::Destroy()` 在 controller teardown 前清空借用的 child HWND，避免 Windows 复用句柄后误聚焦另一窗口。
- **[x] ② 已加自动化测试** — `hibiki/windows/runner/tests/window_activation_policy_test.cpp` 可执行覆盖失活、正常点击/激活、`WM_ACTIVATE` 高低字边界、子窗销毁与 HWND 复用；`hibiki/test/sync/desktop_lookup_foreground_guard_static_test.dart` 同时守住生产接线、句柄存活/归属检查与销毁清理。
- **备注**：原生策略测试以 MSVC `/W4 /WX` 编译并通过；定向 Flutter 静态守卫 9/9 通过，`flutter analyze --no-pub` 通过（No issues found）。测试期间仅临时指定本机 system SQLite，以绕开预编译库下载的 Windows socket 121 超时，未写入产品配置。按用户要求未等待完整 Windows 编译/真机验收。
