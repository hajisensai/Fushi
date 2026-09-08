## BUG-2281 · 首页继续卡片悬停缺少边框
- **报告**：2026-09-08（用户：首页「继续」卡片鼠标移入应该出框）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_dashboard_page.dart:1499` 的 `_buildContinueCard` 忽略 `FushiHoverLift.builder` 的悬停状态，只缩放，不绘制边框。
- **[x] ① 已修复** — 消费已有悬停状态，以 foreground DecoratedBox 绘制 2px 主题色圆角框，移出透明；不会增加布局尺寸，封面不会遮挡描边。「继续」与「最近添加」复用同一修复。提交见本文件所属提交。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart` 在真实首页书卡上验证鼠标移入显框、移出复位、尺寸不变；与 `fushi_hover_lift_test.dart` 合跑 34 passed，7 个既有 Bangumi 测试 skipped。`flutter analyze --no-pub` 通过。
- **备注**：未构建/运行真实 Windows 应用，原始截图路径设备肉眼复测待补。未运行全量测试。
