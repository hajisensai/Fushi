## BUG-2017 · EPUB 自闭合 script 标签吞掉正文导致章节纯文本为空、有声书匹配率 0

- **报告**：2026-09-01（用户：EPUB + 同名 SRT 配对，匹配率 0）
- **真实性**：✅ 真 bug，根因 `fushi/lib/src/epub/epub_book.dart:92`（原 `chapterPlainText` 里的 `html_parser.parse(chapters[index].html)`）
- **[x] ① 已修复** — `fushi/lib/src/epub/epub_book.dart`：新增 `normalizeSelfClosingRawTextTags()` + 统一解析入口 `EpubBook.parseChapterHtml()`，章节 XHTML 的四处 DOM 解析全部收敛到该入口
- **[x] ② 已加自动化测试** — `fushi/test/epub/epub_selfclosing_rawtext_tag_test.dart`（13 条，已做变异实测：把归一化改成直通后 8 条转红）
- **备注**：见下

### 复现

用户样本：`湊かなえ - Nのために  [双葉社].epub` + 同名 `.srt`（7445 条 cue），导入配对后匹配率 0%。

沿真实 Dart 链路（`EpubParser.parseSyncFromPath` → `epubSectionsFromExtractDir` → `SrtParser.parse` → `EpubSrtMatcher.match`）实测：

```
修复前：BOOK chapters=19  SECTIONS=19  TOTAL section text chars=0   MATCH 0/7445 (0.0%)
修复后：BOOK chapters=19  SECTIONS=19  TOTAL section text chars=145006  MATCH 7408/7445 (99.5%)
```

### 根因

EPUB 章节文件是 **XML**（`application/xhtml+xml`）。这本书由 kobo 工具链处理过，`<head>` 里带一行 XML 风格自闭合的 script，且全文**没有** `</script>`：

```html
<script xmlns="http://www.w3.org/1999/xhtml" type="text/javascript" src="../../js/kobo.js"/>
```

WebView 按该 MIME 走 XML 解析，这是合法空元素，所以**阅读器渲染一直正常**。但 Dart 侧 `chapterPlainText()` 用的是 package:html 的 **HTML5 解析器**，它不认 raw-text 元素的自闭合写法：`<script/>` 被当成未闭合的开标签，tokenizer 进入 script data 状态，一路把文档剩余部分（含整个 `<body>`）吞成该元素的文本。结果 `doc.body` 为空 → 每章纯文本为 `''`。

`epub_book.dart:84` 原有注释写着「same parsing semantics as the WebView」——这个前提对 XHTML 自闭合标签**不成立**，正是本 bug 的认知根因。

最小验证（package:html 实测）：

```
自闭合 <script/>：body.text = ''      ，正文 202 字符全落在 head 的 script 文本里
显式 </script>  ：body.text = 一月二十二日、午後七時二十分頃、
```

### 影响面（不止匹配率）

章节纯文本恒为空，波及所有以它为输入的消费方：

1. 有声书对齐 —— `audiobook_alignment_service.dart:78` 的 `EpubSection.text` 全空，matcher 必然 0（用户报的症状）
2. 每章字数落库 —— `epub_importer.dart:496` 的 `chapterCharacterCount` 恒 0，全书字数 0，阅读统计/阅读速度失真
3. 纯图片章误判 —— `isImageOnlyChapter` 的文本阈值恒满足，正文章被判成插图页，影响 `EpubSpreadMap` / `EpubSpreadAnalyzer` 跨页配对与图片合并，`manga_archive_importer.dart:243` 也据此判漫画
4. 章节图片索引 —— `chapterImageSrcs` / `images` 同样解析不到 `<body>` 里的 `<img>`

### 修复

单一入口 `EpubBook.parseChapterHtml()`：先把自闭合的 raw-text 标签归一化成显式闭合，再交给 HTML 解析器，使其与 WebView 的 XML 解析结果一致。章节 XHTML 的四处解析（`chapterPlainText` / `isImageOnlyChapter` / `chapterImageSrcs` / `images`）全部收敛到它。

归一化只动 HTML5 里内容读到显式结束标签才终止的元素（`kRawTextTags`：script / style / textarea / title / iframe / noembed / noframes / noscript / xmp / plaintext），且只在其自身以 `/>` 结束时改写；空元素（`<br/>` `<img/>` `<meta/>`）不碰——它们自闭合在两种解析器下本就等价。注释 / CDATA / DOCTYPE / XML 声明整段透传，属性值里的 `>` 由引号状态机跳过。因此对既有正常 EPUB 是恒等变换，向后兼容。
