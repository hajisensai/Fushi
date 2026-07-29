## BUG-1242 · 查词弹窗横滑手势阻塞正文滚动
- **报告**：2026-07-29（用户）
- **真实性**：✅ 真 bug。弹窗最外层 `HorizontalDragGestureRecognizer` 与 WebView 正文滚动竞争；Windows `CustomPlatformView` 通过 raw pointer 注入 WebView2，父层赢竞技场时会向平台视图发 cancel，稍带横向抖动的纵滑因而表现为多次才响应。
- **[x] ① 已修复** — `_BodySwipeDismissDetector` 改成不参与竞技场的 opaque `Listener` 旁路观察触摸；8px 后按 1.5 倍轴向判定，只有明确横向触摸才跟手滑关，纵向/斜向永久交还 WebView。鼠标正文拖选不触发本体滑关。
- **[x] ② 已加自动化测试** — `dictionary_popup_layer_body_swipe_close_test.dart` 保留双向滑关、阈值、动画测试，新增纵向主导不横移/不关闭与源码无横拖 recognizer 守卫。
- **备注**：顶栏专用滑关入口保持不变。
