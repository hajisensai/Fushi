## BUG-3278 · 视频库继续观看横滚行悬停放大被视口左右裁剪
- **报告**：2026-10-13（应用内反馈 #cb1nUGFr8m，Windows：视频库「继续观看」横向卡片鼠标悬停放大被视口 / 边框裁剪）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_video_page.dart` 的 `_buildHorizontalRowFrame`：BUG-2002 只给行高留了上下余量（`liftHeadroom`），横向 `ListView.separated` 没有任何 padding，首张 / 末张卡贴着视口左右沿，悬停放大（`kFushiHoverLiftScale`=1.05，以卡中心放大）溢出的左右 (scale-1)/2 被 ListView 视口裁成平边。首页 dashboard「继续」行同款问题已由 BUG-2281 修（`_continueCardsRow` 的 `liftSideRoom`），视频库这条路径没跟上。
- **[x] ① 已修复** — `_buildHorizontalRowFrame` 给 ListView 加 `padding: horizontal liftSideRoom`（最宽 = 横版卡宽 × (scale-1)/2），卡片尺寸与间距不变；继续观看 / 下一集 / 最近添加 / 首屏骨架共用同一份骨架，一起生效。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_video_hover_lift_test.dart`「横滚行首张卡左侧给放大留出横向余量」（首张卡左沿到行视口左沿 ≥ 卡宽×(scale-1)/2）。
- **备注**：未做 Windows 真机肉眼复测。
