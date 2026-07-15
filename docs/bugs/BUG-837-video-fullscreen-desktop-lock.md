## BUG-837 · 桌面视频全屏独占锁死桌面无法切到其他软件
- **报告**：2026-07-15（用户：双屏 Windows）
- **真实性**：✅ 真 bug — 根因 `third_party/media_kit_video/windows/utils.cc:44-49`（`Utils::EnterNativeFullscreen`）。
- **现象**：桌面进视频全屏后，桌面点不开其他软件、只有任务栏能动、窗口最小化也不行，必须 Win+D（显示桌面）或退出视频才能操作其他软件；双屏。
- **根因**：桌面视频全屏走 media_kit 上游 `EnterNativeFullscreen`：把主窗口 `style & ~WS_OVERLAPPEDWINDOW` 变无边框、`SetWindowPos(HWND_TOP, rcMonitor…)` 精确铺满整块显示器。Flutter/ANGLE 的无边框窗口精确等于显示器矩形 + 顶层 → 被 Windows/DWM 提升为**独占式全屏（Fullscreen Optimization / 独占 MPO flip）**，z-order 被霸占：其他窗口浮不上来（只有系统置顶的任务栏可点）、Alt+Tab/任务栏切不走、双屏另一屏受牵连，只能 Win+D 强制最小化一切或退出视频还原样式才解锁。排除了「窗口置顶」路径——读用户生产库 `desktop_clipboard_window_mode = normal`，主窗从不带 `WS_EX_TOPMOST`。
- **[x] ① 已修复** — `third_party/media_kit_video/windows/utils.cc` `EnterNativeFullscreen`：① 落点改 `HWND_NOTOPMOST`（非置顶层 + 清除遗留 always-on-top，让被激活的其他窗口能覆盖本窗口）；② 窗口高度 `monitor_height + 1`（比显示器高 1px，底边落屏外，使客户区不再精确等于显示器矩形 → DWM 不再判独占全屏、恢复普通合成、窗口可被覆盖/切走；多出 1px 在屏外不可见，视觉仍铺满）。不动 `WS_OVERLAPPEDWINDOW` 全屏状态机（`ExitNativeFullscreen`/`WM_NCCALCSIZE` 依赖它）。提交：<pending>。
- **[x] ② 已加自动化测试** — `hibiki/test/build/video_fullscreen_no_exclusive_guard_test.dart`（源码扫描守卫：`EnterNativeFullscreen` 段必含 `HWND_NOTOPMOST` 且不含 `HWND_TOP,`、必含 `monitor_height + 1`；原生窗口无法在 host 跑，守卫防 re-vendor/重构静默回归）。
- **备注**：z-order/DWM 独占行为**必须在双屏真机复测**——修复逻辑正确但 FSO/独占合成只有真机能最终验证；当前后台会话单屏 + 沙箱跑不了 GUI 前台切换，复现不了。真机验证点：进视频全屏后 Alt+Tab / 点任务栏能正常切到其他软件、双屏另一屏可用、退出全屏窗口正常还原。若仍锁死需迭代 FSO 规避手段。
