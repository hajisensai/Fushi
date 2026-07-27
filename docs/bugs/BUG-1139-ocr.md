## BUG-1139 · 漫画全卷 OCR 后密集命中层导致阅读器黑屏
- **报告**：2026-07-27（用户：高频翻页与查词压力测试）
- **真实性**：✅ 真 bug。真实《Sieger 2026-27》的 100 页 Lens 结果生成约
  21.6 MiB `manga.json`；旧窗口一次展开 5 个 spread，约 2.5 万个字符区域各自
  重复整段内联 CSS，Windows WebView2 `loadData` 连续超过 10 秒未完成，阅读器只剩
  黑底和页码。根因位于
  `hibiki/lib/src/media/manga/manga_overlay_html.dart:319` 与
  `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:996`。
- **[x] ① 已修复** —
  - 字符命中框的公共布局移入单一 `.ocr-char` CSS 规则，保留精确像素矩形、
    UTF-16 偏移和横/竖排标记；
  - 全部图片页以 lazy `<img>` 常驻稳定 strip，仅当前 spread 物化密集 OCR 节点；
  - 翻页时原位移除上一 spread 的 OCR 节点并注入目标 spread，不再 `loadData`
    整份文档，也不会让 DOM 随翻页无限增长。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/manga/manga_overlay_html_test.dart:116` 钉住公共字符样式不重复内联；
  - `hibiki/test/media/manga/manga_overlay_html_test.dart:618` 钉住图片 strip 全量常驻、
    OCR 只按指定页面物化。
- **修复提交**：`c3be39d63`
- **备注**：Computer Use 修复后从首页重新进入同一本书，36–37 页在 2.5 秒内完整显示；
  之后跨 30–51 页连续翻页、100%/110%/120% 缩放、动态 OCR 注入后的单击查词均通过，
  未再出现黑屏或重新 OCR。
