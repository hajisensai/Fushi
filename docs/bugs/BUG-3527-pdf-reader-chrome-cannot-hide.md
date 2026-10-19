## BUG-3527 · pdf-reader-chrome-cannot-hide
- **报告**：2026-10-18（用户：PDF 阅读页没办法关闭上下两条栏，附手机截图）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_pdf_page.dart` 的 `build` 把顶栏 `_buildFloatingHeader` 无条件放进 Stack、底部翻页胶囊只按「就绪且页数 > 1」显示，整页没有任何显隐状态；`onGeneralTap` 点背景直接 `return false`、点页内空白静默 return，没有任何手势能收起 chrome。
- **[x] ① 已修复** — 新增 `_chromeVisible`：顶栏包进 `FushiChromeReveal(visible: _chromeShown)`，翻页胶囊条件加 `_chromeVisible`；点页面外背景、或页内空白 / 图片 / 无文本层页（`_lookupAtDocumentPosition` 改为返回是否命中字）时 `_toggleChrome`，命中字照旧查词。文档未就绪（加载中 / 文件丢失）时 `_chromeShown` 恒真，iOS 唯一出口返回键不会被收走。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_pdf_chrome_toggle_guard_test.dart`（源码形状守卫：PdfViewer 依赖 pdfium 原生库，widget 测试起不来真实文档）。
- **备注**：未做真机验证。
