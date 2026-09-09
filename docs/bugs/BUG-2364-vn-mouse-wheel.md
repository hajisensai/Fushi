## BUG-2364 · VN模式鼠标滚轮被分页器能力门误拦截
- **报告**：2026-09-09（用户：Windows 桌面，Fushi 的 VN 模式不能用鼠标滚轮）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:1490` 的正文 `wheel` 监听仅允许连续模式或带 `paginationMetrics` 的普通分页器；VN 分页器在 `reader_visual_novel_scripts.dart` 提供 `paginate(direction)`，但按设计没有 CSS 分栏指标 `paginationMetrics`，所以每次 VN 滚轮输入都在共享 `onWheelPaginate` 桥之前直接返回。
- **[x] ① 已修复** — `8f5a4b444e`：能力门显式放行 VN，让它复用既有 `onWheelPaginate → _paginate` 方向归一、触控板手势聚合、节流和跨章处理；其它无分页能力的壳仍保持拒绝。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vn_wheel_page_turn_test.dart` 直接执行生产 wheel 回调，覆盖 VN 无 `paginationMetrics` 仍路由、普通分页不回归、其它无指标壳及空 reader 仍拒绝；并与既有分页滚轮守卫合跑，共 14 项通过。
- **备注**：定向 `flutter analyze --no-pub` 通过；尚未在 Windows 真机 WebView2 内对用户原始 VN 书籍做鼠标滚轮肉眼复测。
