## BUG-4911 · 换集保持全屏逐帧重试 30 帧，controls 首建晚于 30 帧就丢全屏
- **报告**：2026-11-20（来源：路线图 #3722 c51 的 video-36e，代码审读复核成立）
- **真实性**：✅ 真问题。根因（基准 `origin/develop@7745effa2e`，`fushi/lib/src/pages/implementations/video_fushi/fullscreen.part.dart`）：
  - `:98-139` `_scheduleInitialFullscreenIfNeeded` 在就绪后用 `addPostFrameCallback` 逐帧自我重排，直到 `_videoControlsContext` 非空；`:112` 的 `_initialFullscreenRetries > 30` 是上限。等待期间每帧空转一次回调；controls 首建慢于 30 帧（大文件首帧、原盘菜单换正片）时放弃并退掉接管来的原生全屏——换集后全屏丢了。
  - 真正的前提变化只有一个事件：controls 子树 Builder 给 `_videoControlsContext` 赋值（`layout.part.dart:430`、`:558`），或页面进了失败 / 缺失态。轮询是在补「状态变了没人通知」的缺口。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/video/video_initial_fullscreen_gate.dart`（一次性闸门：就绪 `arm` 开闸；`notify` 同帧合并成一个帧后尝试；`waiting` 不排下一帧；`settle` 关闸）。页面：`_scheduleInitialFullscreenIfNeeded` 只开闸；context 两处赋值点改走 `_captureVideoControlsContext`（写完 `notify`）；`_buildScaffold` 渲染失败 / 缺失态时 `notify`（放弃并退原生全屏）；原 `_didInitialFullscreen = true` 三处（换集移交、远端换集、网页档收作窗口全屏）改 `settle()`。去掉 30 帧上限：失败 / 缺失态由渲染事件放弃，加载中退页仍由 dispose 的 `_releaseHandedOverNativeFullscreen` 收口。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_initial_fullscreen_gate_test.dart`：手动帧泵驱动闸门，controls 第 41 帧才到仍进全屏、等待期间不排任何帧回调；同帧合并；开闸前通知无效；失败态放弃一次；settle 后作废。`fushi/test/pages/video_fullscreen_switch_flatten_guard_test.dart` 的锚点改成闸门调用。
- **备注**：未做设备复测（本轮所有者定不做）：桌面全屏下换集（本地快路径、慢路径、原盘自动全屏）仍保持全屏、ESC 一次退出；加载失败的换集页退回窗口态。
