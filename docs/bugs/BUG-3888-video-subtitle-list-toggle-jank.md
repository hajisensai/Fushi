## BUG-3888 · video-subtitle-list-toggle-jank
- **报告**：2026-10-30（用户：Windows 本地视频，push-aside 字幕列表打开和关闭都很卡）
- **真实性**：✅ 真 bug（沿代码路径确认，未做真机帧时测量）。字幕列表列宽走 200ms `AnimatedSize`（`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` `_subtitleJumpSidePanel`），画面区每帧换一次宽度；而 `fushi/lib/src/pages/implementations/video_fushi/layout.part.dart` `_buildVideoControls` 用裸 `LayoutBuilder` 把**整棵** controls 子树（控制条 / 字幕 overlay / rail …）建在回调里（7970c81228 控件按窗口分档引入），约束一变就整棵重建——开、关各重建几十次整套 chrome。关闭时面板内容立即卸载、只剩宽度收缩，所以开关两个方向同样卡。
- **[x] ① 已修复** — 新增 `VideoControlsDensityBuilder`（`fushi/lib/src/media/video/video_controls_density.dart`）：只在密度档变化、父级重建或小窗表面变化时重建子树，约束连续变化但档位不变时原样返回上次的 widget 实例；子树包在自己的 `Builder` 里，InheritedWidget 依赖变化仍单独触发重建。`_buildVideoControls` 改用它。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_controls_density_test.dart`（`VideoControlsDensityBuilder` 组：宽度逐帧收窄全程同档只 build 一次、跨阈值才重建；父级重建与小窗表面变化照常刷新）。
- **备注**：真 app 帧时未测，需用户在 Windows 上复测开关手感。
