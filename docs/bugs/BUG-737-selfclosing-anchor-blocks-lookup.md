## BUG-737 · 自闭合a锚点被HTML解析成未闭合a包裹正文导致点字查词被链接守卫拒绝
- **报告**：2026-07-11（用户：某些 EPUB 在 Hibiki 点/划字查不了词，别的 reader 能划、重新打包后又能查）
- **真实性**：✅ 真 bug（真实阅读器复现确认）
- **[x] ① 已修复** — 提交 `<pending>`
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_resource_sanitizer_xhtml_test.dart`（源码扫描/生成器守卫）+ 集成探针 `hibiki/integration_test/reader_lookup_realbook_probe_itest.dart`（真实阅读器行为）
- **备注**：见下

### 根因
出版社日文 EPUB（KADOKAWA/BookWalker 等）常在每个正文章开头放一个**自闭合空锚点** `<a id="toc-N"/>`（章节跳转目标）。这是合法 XHTML（空元素）。但 Hibiki 拦截器把正文一律以 **`text/html`** 服务（`hibiki/lib/src/epub/epub_book.dart:597` `fallbackMimeType` 把 `.xhtml`/`.html` 都回 `text/html`），HTML5 解析器**忽略非 void 元素的自闭合 `/`**，`<a id="toc-N"/>` 变成**未闭合的 `<a>`**。`<a>` 是 active formatting element，经 HTML 收养机制（adoption agency）在后续每个块级元素里被重构，于是**整章正文全被包进 `<a>`**。

点字取词入口 `hibiki/lib/src/reader/reader_selection_scripts.dart:981` `selectText`：
```js
if (document.elementFromPoint(x, y)?.closest('a')) { return null; }
```
命中链接即拒绝取词 → 整章任何字都查不了词。别的 XML 感知 reader 把 `<a/>` 当空元素故正常；重新打包 EPUB 重新序列化 → 锚点被正确闭合 `<a></a>` → 正文不再在 `<a>` 内 → 恢复查词（正是"重打包能修"的原理）。

`sanitizeXhtml`（`reader_resource_sanitizer.dart`）此前只规范化自闭合 **raw-text** 元素（script/style/title…，BUG-079），不管 `<a>`。

**真实阅读器复现证据**（离屏 Windows WebView2，样本 `ナミヤ雑貨店の奇蹟` p-001）：
- `realTapBlockedCount = 40/40`（每字的 `elementFromPoint().closest('a')` 都真）
- `underAChars = 34962/34962`（整章 100% 正文在 `<a>` 内）
- `firstAOuterHtml = <a id="toc-001"><span>第一章　回答は牛乳箱に</span></a>`
- `getCharacterAtPoint` 仍命中 38/40（它没有链接守卫，故单看它会误判"能查"——这是此前排查一度未复现的原因）。
- 对照 `文学少女…道化`（Calibre 重打包版）正文无 `<a>` → 查词正常（35/40，miss 全标点），佐证 per-file 差异就是这个锚点。

### 修复
`hibiki/lib/src/reader/reader_resource_sanitizer.dart` — 把 `sanitizeXhtml` 的"仅 raw-text 自闭合"泛化为"**所有非 void 元素的自闭合 `<tag/>` → `<tag></tag>`**"（Linus 式消除整类特殊情况：一条规则同修 `<a>`/`<span>`/`<i>` 等所有非 void；void 元素 br/img/hr/input/meta/link… 保持自闭合）。这是 XHTML→HTML 的严格正确归一化（XHTML 里 `<tag/>` ≡ `<tag></tag>`）。引擎在 `_buildSanitizedChapterHtmlBytes`（`reader_hibiki/webview.part.dart`）服务每章前调用，故正文喂进 WebView 前锚点已闭合。

### 验证
- `flutter test test/reader/reader_resource_sanitizer_xhtml_test.dart`（26 用例含新 `<a id/>`、非 void inline、void 集合保留、属性内 `/>` 不误判）全绿。
- 真实阅读器端到端：修复后重跑 namiya 探针（`realTapBlockedCount`/`underAChars` 应降到 ~0，正文可查）——见提交时的 `.codex-test/windows-itest/probe-namiya-fixed`。
