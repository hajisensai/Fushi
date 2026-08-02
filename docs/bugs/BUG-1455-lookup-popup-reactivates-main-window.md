## BUG-1455 · 拖动或缩放查词弹窗会把主窗口抬到前台
- **报告**：2026-08-02（用户：查词弹窗拖动或从右下角缩放时，Hibiki 主窗口被抬到前台）
- **真实性**：✅ 真 bug。查词面板由 `hibiki/windows/runner/global_lookup_window.cpp:1528` 的 `WM_NCLBUTTONDOWN` 进入系统 move/size 循环并成为活动窗口；主窗口随即收到 `WM_ACTIVATE/WA_INACTIVE`，但 `hibiki/windows/runner/win32_window.cpp:287` 原来不区分激活与失活，两种情况都会 `SetFocus(child_content_)`，把焦点和 Z 序抢回主窗口。
- **[x] ① 根因修复** — `21b0d7baf`：主窗口只在 `LOWORD(wparam) != WA_INACTIVE` 时恢复 Flutter 子窗口焦点；查词弹窗接管激活以拖动/缩放时，主窗口不再反向抢焦点。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/desktop_lookup_foreground_guard_static_test.dart` 新增 `WM_ACTIVATE` 分支源码守卫，要求 `SetFocus(child_content_)` 唯一调用受 `WA_INACTIVE` 门控。
- **备注**：`flutter analyze --no-pub` 通过（No issues found）；定向 `flutter test test/sync/desktop_lookup_foreground_guard_static_test.dart --no-pub` 在任何用例执行前被 `pdfium_dart` 下载 `pdfium-win-x64.tgz` 的 Windows socket 121 超时阻断，不能记为测试通过。按用户要求未等待完整 Windows 编译/真机验收。
