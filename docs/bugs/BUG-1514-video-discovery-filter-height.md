## BUG-1514 · 视频发现筛选控件高度不一致
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_discovery_page.dart:518` 的年份输入框使用 Material 输入框固有高度，而国家、类型、排序在 `:624` 使用带独立垂直 padding 的 `FushiCard`，两类控件没有共享高度约束。
- **[x] ① 已修复** — 年份也改用与国家、类型、排序相同的下拉卡片，四个筛选控件统一使用 44px 高度。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_discovery_page_test.dart` 对年份、国家、类型、排序四个控件做等高回归断言。
- **备注**：按用户要求本轮跳过自动化测试，完成 Windows Debug 构建后直接启动实测。
