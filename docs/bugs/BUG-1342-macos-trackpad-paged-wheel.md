## BUG-1342 · macOS触控板一次滑动连续翻三到四页
- **报告**：2026-08-01（用户：macOS 触控板左滑一次会连续翻 3–4 页，方向键只能准确翻一页）
- **真实性**：✅ 真 bug。分页 `wheel` 监听曾把触控板的一次惯性手势当作每个 DOM `WheelEvent` 独立回传；Dart `_paginate` 的 450ms 固定窗口限频会在持续 1–1.5s 的同一惯性流中反复放行，因此一次手势稳定触发多次相邻页步进。另有斜向事件方向用 `deltaY > 0 || deltaX > 0` 判断，主轴为负、噪声轴为正时会反向。根因见 `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:1369-1396`。
- **[x] ① 已修复** — `df3b89200`：分页 wheel 输入边界改为尾沿静默手势聚合器；首 tick 只发一次翻页，后续惯性 tick 只续租静默计时，完整静默 `wheelPageTurnInterval` 后才解锁下一次手势。方向统一取绝对值更大的主轴，零位移忽略；Dart 入口 rate-limit 保留作跨输入源防线。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_paged_wheel_gesture_behavior_test.{dart,js}` 真抽取并执行生产 JS：1.5s/60ms 惯性流只翻一页、静默后下一手势才翻第二页、斜向主轴/反弹/零位移与 `preventDefault` 全覆盖；`page_turn_direction_intent_test.dart` 同步锁纯函数主轴语义。
- **备注**：代码、Node 行为测试和相关 reader 测试已通过；按用户要求本次不等待 macOS 真机编译验收，原始触控板路径仍待设备肉眼复测。
