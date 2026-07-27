## BUG-1135 · 漫画页码已翻但 WebView 仍显示旧页面
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:758`
  把 WebView2 `loadData` Future 完成误当作新文档已显示，并立即解除翻页锁；旧文档的
  `onLoadStop` 与后续翻页可交错，使 `_loadedSpreads`/页码已更新但画面仍是封面。
- **[x] ① 已修复** — 每份窗口文档嵌入单调 generation；保持导航锁直到活 WebView
  通过 JS 回报相同 generation，再重新应用目标 spread 平移。迟到的旧文档回调被忽略。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/manga/manga_overlay_html_test.dart` 守卫 generation 与目标
  spread 均写入文档；真实 WebView2 验证页码 16–17 时画面确为对应雪鞋目录。
- **备注**：这也是此前“点到的 OCR 词和画面不一致”的独立原因之一。
