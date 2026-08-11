## BUG-1501 · 选集横轨只能点 X 关闭，点击视频区域无效
- **报告**：2026-08-11（用户：Wight）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_fushi/layout.part.dart` 的 `_videoWithSubtitlePanel` 只叠加 `_episodeOverlayPanel`，没有面板外 dismiss barrier；`fushi/lib/src/pages/implementations/video_fushi_page.dart` 的 `_handleVideoPointerUp` 也未门控 `_episodeListVisible`，无法让点击视频只关闭选集而不进入播放器手势。
- **[x] ① 已修复** — `5cd768687b` 增加仅在选集横轨展开时命中的透明关闭层，并在视频 pointer-up 手势入口提前关闭选集，避免同一次点击继续触发播放器操作。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_episode_list_push_aside_guard_test.dart` 锁定 barrier 层级、隐藏态零拦截及 pointer-up 早返回。
- **备注**：后续按用户要求跳过所有测试；提交前曾在 Windows 同一 Fushi 运行目标守卫与 debug 构建。
