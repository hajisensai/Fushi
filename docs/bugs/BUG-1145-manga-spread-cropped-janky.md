## BUG-1145 · 漫画双页图片裁切且翻页卡顿
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。根因是 `hibiki/lib/src/media/manga/manga_overlay_html.dart:150`
  的旧布局只按槽宽计算页高，横屏时页高超过 WebView 后被裁切；同时
  `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:363` 的预载半径过小且
  翻到窗口边缘就提前 `loadData`，导致接近每页重建 WebView。
- **[x] ① 已修复** — 页尺寸同时受槽宽与 `100vh` 约束，跨页使用固定
  `100vw×100vh` 容器居中；扩大预载窗口并仅在真正越界时重建。修复提交见后续记录。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/manga/manga_overlay_html_test.dart` 覆盖单双页完整居中、
  RTL 稳定几何、预加载与无裁切尺寸约束。
- **备注**：Windows 真应用实测单页和双页均完整显示；书页与窗口宽高比不一致时
  保留必要留黑，避免以裁切换满宽。翻页窗口化路径已实测不再逐页白屏重载。
