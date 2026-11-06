## BUG-3882 · video-continue-card-hover-clipped
- **报告**：2026-10-30（用户：视频首页「继续观看」小卡悬停放大被遮住、封面上下被裁）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_continue_spotlight.dart` 宽屏网格没给 `kFushiHoverLiftScale` 放大留余量，放大的卡被视口裁掉；侧卡封面高按行高硬塞，不是 16:9，`BoxFit.cover` 把上下裁掉。
- **[x] ① 已修复** — 行高按 2 行 + 放大余量反推，网格 / 列表 padding 留出 `_liftRoom`；侧卡封面高 = 卡宽 × 9/16，列数改 `ceil` 使卡宽不超出可用宽。
- **[x] ② 已加自动化测试** — 既有 `fushi/test/widgets/video_continue_spotlight_test.dart`、`fushi/test/pages/home_video_hover_lift_test.dart`。
- **备注**：Windows 调试实例上人工确认过。
