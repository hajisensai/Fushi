## BUG-5583 · 页面静止时仍以接近屏幕刷新率持续出帧（视频库页 / 视频合集页）
- **报告**：2026-11-27（BUG-5582 测速中发现，用户未单独报告）
- **真实性**：🔎 待定位。profile `video_collection_perf_itest`、安装版真实库只读拷贝（glass 设计系统、4K、165 Hz）：视频库页静止 1 秒出 76–142 帧，视频合集页 145–150 帧；同时 `transientCallbackCount=0`（没有 ticker 挂帧回调），`UiActivityProbe` 记到 `build=0`（不是 setState）。常驻装饰动画按设计只有约 30 fps（`ambient_ticker.dart`），所以这是别的来源：渲染对象在帧外被弄脏（`markNeedsPaint` / `markNeedsLayout` → `requestVisualUpdate`）或直接 `scheduleFrame` / `ensureVisualUpdate`。视频库页静止一帧 raster 5.5–6.4 ms，持续出帧意味着 GPU 一直在忙。
- **[ ] ① 未修复** — 下一步：生产 binding（`FushiWidgetsFlutterBinding`）的要帧归因 `fcb=` / `fvis=` 在 itest 的 binding 下不生效，要在真 app（状态监测）或给 itest 补等价钩子拿到要帧来源再修。
- **[ ] ② 未加自动化测试** —
- **备注**：BUG-5582 的转场快照不受影响（快照期间子树重绘不重拍）。
