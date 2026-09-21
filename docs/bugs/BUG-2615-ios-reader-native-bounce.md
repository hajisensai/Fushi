## BUG-2615 · iOS 竖屏连续滚动模式上下滑动触发正文回弹
- **报告**：2026-09-21（用户：iOS 竖屏连续滚动模式；上下滑动正文区域会回弹）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:1911` 只设置了 Android 的 `overScrollMode`；iOS 的 WKWebView 使用独立的 `UIScrollView.bounces`，默认仍开启，因此正文区域上下拖动会出现橡皮筋回弹。
- **[x] ① 已修复** — 创建阅读器 WebView 时设置 `disallowOverScroll: true`，由 iOS 插件关闭 `UIScrollView.bounces`，不禁用连续模式的滚动轴（本提交）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_webview_overscroll_never_guard_test.dart` 覆盖 Android/iOS 回弹开关及连续模式滚动轴保持可用。
- **备注**：Dart 守卫无法模拟 WKWebView 原生橡皮筋；需在真实 iOS 竖屏设备/模拟器复测上下拖动与沿书写轴连续滚动。
