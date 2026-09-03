## BUG-1656 · Apple 漫画阅读器图片黑屏
- **报告**：2026-08-15（用户：macOS 打开在线漫画后章节存在但图片全黑）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/reader/manga_fushi_page.dart:3401` 在 Apple WKWebView 上仍只依赖 `shouldInterceptRequest` 接管 `https://manga.local` 子资源；WKWebView 不会把这些请求交给该回调，导致本地缓存图片永远没有响应。
- **[x] ① 已修复** — `63d15de4` 注册 `fushi-manga` 自定义资源 scheme，并在 `onLoadResourceWithCustomScheme` 中复用既有路径穿越校验与图片响应；macOS / iOS 共用该路径。
- **[x] ② 已加自动化测试** — `fushi/test/pages/manga_fushi_page_pure_test.dart` 验证自定义 scheme URL 生成，`fushi/test/pages/manga_interceptor_test.dart` 验证 scheme 解析与虚拟域隔离；相关 47 个 Flutter 测试通过。
- **备注**：用户已确认 macOS 原失败路径恢复显示。iOS 真机已配对，但本机 Xcode 对手机系统版本的 Device Platform 不可用，未下载 Simulator 或平台组件，待兼容 Xcode 环境补充肉眼复测。
