## BUG-2886 · 显示拓扑变化后，离屏停放的查词覆盖窗落进屏幕右上角吞点击
- **报告**：2026-10-03（agent 在 ceshi 样本 Fate/stay night[Realta Nua] 真机验收时，accept4 前置检查报「已有查词卡在屏」而发现）
- **真实性**：✅ 真 bug。根因 `fushi/windows/runner/global_lookup_window.cpp` `GlobalLookupWindow::OffscreenX()` 只在建窗 / 停放那一刻按「虚拟桌面右缘 + 200」算离屏位，此后显示拓扑变化（分辨率 / 缩放 / 热插拔让桌面变宽）没有任何地方重新停放。
  - 现场：测试 app（pid 146320）的预热覆盖窗 `FushiGlobalLookupWindow` 停在物理 `[3144,0,4041,515]`，`IsWindowVisible=1`，屏幕是 3840×2160 @150%——右上角 696×515 物理像素落在屏内；`WindowFromPoint(3500,200)` 命中它的 `Chrome_RenderWidgetHostHWND`，即这块区域的点击被一个用户看不见的窗口吞掉。
  - 佐证：这个窗与 app 主窗（同在 01:42:27–32 创建）`GetDpiForWindow=96`，之后创建的窗是 144，说明建窗时拓扑不同；3144 恰等于「当时虚拟宽 2944 + 200」。同条件下新建的探针窗（`OffscreenX()` = 4040）原地不动，排除了系统自行挪窗。
  - `Hide()` 走 `SW_HIDE`，不受影响；受影响的是「显示着但未 Reveal」的三种停放：`PrewarmWebView`、`ShowAt` 的离屏测量、`ResizeOffscreen` 的 gal 采集面。
- **[x] ① 已修复** — 本提交 `fix(lookup): re-park off-screen lookup windows when the display topology changes`：新增 `ReparkOffscreenIfParked()`（仅 `!revealed_ && IsWindowVisible` 时按当前 `OffscreenX()` 只换位置，`SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE`，不带 `SWP_SHOWWINDOW`），在 `WM_DISPLAYCHANGE` 与 `WM_DPICHANGED`（系统建议矩形按旧位置换算）末尾调用。与浮动歌词窗 TODO-832 的 `WM_DISPLAYCHANGE` 处理同一思路。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/global_lookup_offscreen_repark_guard_test.dart`（源码守卫，断言前先剥注释：两条消息都重新停放；只挪未上屏的可见窗、只换位置、不带显示标志）。变异实测：给 SetWindowPos 加 `SWP_SHOWWINDOW`、注释掉 `WM_DISPLAYCHANGE` 里的调用，两条都变红。
- **备注**：拓扑变化的触发源（显示器休眠唤醒 / 缩放切换）本机无法确定性复现，真机证据是上述状态快照与探针对照。
