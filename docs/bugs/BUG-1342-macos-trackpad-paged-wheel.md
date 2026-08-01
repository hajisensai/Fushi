## BUG-1342 · macOS触控板一次滑动连续翻三到四页
- **报告**：2026-08-01（用户：macOS 触控板左滑一次会连续翻 3–4 页，方向键只能准确翻一页）
- **真实性**：✅ 真 bug。分页 `wheel` 监听曾把触控板的一次惯性手势当作每个 DOM `WheelEvent` 独立回传；Dart `_paginate` 的 450ms 固定窗口限频会在持续 1–1.5s 的同一惯性流中反复放行，因此一次手势稳定触发多次相邻页步进。另有斜向事件方向用 `deltaY > 0 || deltaX > 0` 判断，主轴为负、噪声轴为正时会反向。根因见 `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:1369-1396`。
- **[x] ① 已修复** — `c3796c723`, `6b048241c`：分页 wheel 每个 tick 只上报方向与主轴；横向触控板惯性由 reader Dart State 中的尾沿静默 gate 聚合，故翻章重建 WebView document 也不会在同一手势中重新放行。纵向鼠标滚轮不进此 gate，保留原有固定窗口节流；方向统一取绝对值更大的主轴，零位移忽略。
- **[x] ② 已加自动化测试** — `reader_paged_wheel_gesture_behavior_test.dart` 直接执行生产 `ReaderWheelGestureGate`：1.5s/60ms 惯性流（含模拟中途翻章）只放行一次，完整静默后下一手势才放行；`reader_mouse_paging_boundary_guard_static_test.dart` 锁定 JS 无 document-local 手势状态、横向才入 gate、纵向保留既有节流，方向纯函数测试覆盖斜向主轴与零位移。
- **备注**：静态分析及相关 reader 测试已通过；按用户要求本次不等待 macOS 真机编译验收，原始触控板路径仍待设备肉眼复测。
