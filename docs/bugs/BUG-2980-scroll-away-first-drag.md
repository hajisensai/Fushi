## BUG-2980 · 悬浮页头从顶部连续拖动越过阈值仍不收起
- **报告**：2026-10-06（样式改版审查）
- **真实性**：真实代码路径缺陷。`fushi/lib/src/utils/components/fushi_floating_page_chrome.dart:275` 原实现只在滚动方向变化时检查 56px 阈值；从顶部持续同向拖动时，后续更新不再检查阈值。
- **[x] ① 已实现修复** — 在真实拖动更新中检查用户方向和滚动位置；程序滚动与布局修正不触发隐藏。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/widgets/fushi_scroll_away_gesture_test.dart`：同次手势跨阈值、反向显示、jumpTo/animateTo 负向。
- **备注**：运行结果见 `docs/reviews/2026-10-06-project-review.md`；未完成真实设备验收，不宣称实机修复验证通过。
