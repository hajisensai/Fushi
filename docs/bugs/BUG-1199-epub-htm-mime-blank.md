## BUG-1199 · EPUB 章节用 .htm 扩展名时整本渲染空白（MIME 表缺 htm/xht）

- **报告**：2026-07-28（用户：Windows 上「Do Androids Dream of Electric Sheep？.epub 打不开」）
- **真实性**：✅ 真 bug，根因 `packages/hibiki_core/lib/src/utils/mime_types.dart:31`（`kMimeTypeByExtension` 只有 `xhtml`/`html`，漏 `htm`/`xht`）

### 复现与验伪

用户文件本身**完全合法**，先排除了文件损坏：ZIP CRC 全通过、`mimetype` 为首条且 STORED、`META-INF/container.xml` 指向根级 `content.opf`、manifest/spine 的 41 条引用与包内条目一一对上，无缺失无孤儿。

`EpubParser` 也解析成功（本机跑通：32 章、TOC 32 条、封面与 38 个资源齐全），书确实已入库：

```
epub_books: book_key=Do Androids Dream of Electric Sheep%3F, chapter_count=32
extract_dir=D:\APP\HIBIKI_date\documents\hoshi_books\Do Androids Dream of Electric Sheep%3F  （41 个文件全部落盘）
```

导入后 `error_log.txt` 无任何相关记录 —— 是**静默**渲染失败，不是抛异常。

### 根因

这本书 32 章里有 31 章的扩展名是 `.htm`（Calibre/Sigil 重打包的常见产物），OPF 里 media-type 正确声明为 `application/xhtml+xml`。但阅读器 WebView 拦截器
（`hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:167`）**不读 OPF 声明**，改按扩展名走 `fallbackMimeType` → `mimeTypeForFilePath`。表里没有 `htm`，于是落到 `kFallbackMimeType` = `application/octet-stream`，接着：

1. `webview.part.dart:178` 的 `mime == 'text/html' || mime.contains('xhtml')` 取假
   → **不注入阅读器样式、不做 `sanitizeXhtml` 净化**（这个 if 里就是
   `_chapterHtmlBytes` → `sanitizeXhtml` + `markImagesLazy` + FOUC cloak + `_buildStyleTag`）；
2. `_contentEncodingForMime` 也返回 null（无 utf-8）；
3. `WebResourceResponse` 以 `application/octet-stream` 下发 → WebView 根本不把它当文档渲染。

分页/引擎 JS **不在**这个 if 里（它走 `onLoadStop` → `_onChapterLoadComplete`，不看 mime），
它的失效是「文档压根没被当页面渲染」的间接后果，不是本判定的分支。

结果 31 章全空白。只有 spine 第一项 `titlepage.xhtml` 扩展名对得上，所以能显示封面页——用户看到的就是「打开后没有正文」。

`.xht`（同为 EPUB 3 允许的内容文档扩展名）有一样的问题。

**为什么一直没暴露**：日语 EPUB 内容文档几乎清一色 `.xhtml`；`.htm` 主要出现在英文出版社/Calibre 重打包的书里。

**本次为什么只补扩展名表（治标，且是**有意**的治标）**：真正的真相源是 OPF `content.opf` 里每个 item 声明的 `media-type`，而且它在本层**够得着**——`EpubParser` 已把它存进 `EpubResource.mediaType` / `EpubChapter.mediaType`（`epub_parser.dart:385,92,473`）并落库进 `epub_books.chaptersJson`（`epub_importer.dart:123`）；`EpubBook` 上还有现成但**零调用**的 `mediaType(path)`（`epub_book.dart:56`）；解析器自己筛 spine 用的就是 media-type 判据 `_isHtmlMediaType`（`epub_parser.dart:426,779`，认 `application/xhtml+xml` / `text/html` / `*+html`）；而 `_readerResourcePayload` 所在的 State 就持有 `_book`（同文件 271 行已在拦截路径上读它）。

所以「不能用 OPF」的说法不成立，成立的只是「不能把 OPF 的 `application/xhtml+xml` **当作下发的 Content-Type**」——项目是**故意**把 XHTML 按 `text/html` 下发的，配合 `ReaderResourceSanitizer.sanitizeXhtml` 规避 BUG-079（`<script/>` 吞整页）与 BUG-737（`<a id=".."/>` 包住全章正文导致查词失效，见 `reader_resource_sanitizer.dart:30-44`）；改按 `application/xhtml+xml` 下发会让 WebView 转严格 XML 解析，反而破坏那两个已修的 bug。

**这两件事是可以拆开的**：用 OPF media-type 做**分类**（是不是内容文档），仍按 `text/html` **下发**。本次没这么做是权衡范围与风险后的选择，代价是**残留漏网面**：扩展名表仍是白名单，任何未列入的内容文档扩展名（无扩展名、`.xml`、出版社自造扩展名等）照样落 octet-stream 全书空白。后续应把拦截器的 HTML 判据换成 `_book` 的 media-type（`_buildBookFromDb` 无 `resources`，需退到 `chapters[].mediaType`；`_buildLegacyBook` 硬编码 `text/html`），此表退回它 doc 注释里自称的角色——「manifest 未声明 mediaType 时的兜底」。

同类白名单在别处也仍缺 `.xht`（都不影响开书渲染）：`reader_hibiki_page.dart:1937` 的解析失败降级路径、`drop_classification.dart`、`text_to_epub.dart`、`manga_archive_importer.dart`、`anki_media_dedup.dart`。

- **[x] ① 已修复** — `packages/hibiki_core/lib/src/utils/mime_types.dart` 补 `'htm'` / `'xht'` → `text/html`，与既有 `'html'` / `'xhtml'` 齐平；`packages/hibiki_anki/lib/src/anki_models.dart` 的镜像副本同步（由 `hibiki/test/sync/mime_types_test.dart` 守卫逐项一致）。
- **[x] ② 已加自动化测试** — `hibiki/test/epub/epub_book_utils_test.dart` 新增 `BUG-1199` 组：对 `xhtml`/`html`/`htm`/`xht` 四种扩展名断言「是否当 HTML 文档处理」为真，并补 `CHAPTER.HTM` 大小写用例。该谓词是拦截器判定的**复刻**，故另配源码守卫 `interceptor predicate is still the one replicated here`：切出 `_readerResourcePayload` 方法体，断言其中仍有 `fallbackMimeType(filePath)` 与谓词原文——实现侧改判据而复刻没跟，守卫先红（已用变异实测：把谓词改成 `mime.startsWith('text/html')` 后该组 FAILED）。
- **[ ] ③ 未做真机复测** — 「octet-stream 响应在 WebView2 中不渲染」这一环是按代码路径与浏览器行为推定，未在真机 app 打开这本书复验。合并后应由 debug 通道出包，用户走原始失败路径确认。

- **备注**：同一本书还暴露出**另一个独立真 bug**（未在本次修复范围内）：`EpubParser` 用 `p.canonicalize` 生成章节/资源路径，该函数在 Windows 上会**整体小写化**，于是这本书的 `OEBPS/Dick_*.htm` 被记成 `oebps/dick_*.htm`。Windows 文件系统不区分大小写所以侥幸能读，但在 **Android / Linux 上 31/32 章的 `existsSync()` 会全部失败被静默跳过**，只剩 `titlepage.xhtml` 一章。`_safeArchivePath` 早已为 TODO-739 修好了**解压**侧的大小写保留，但 `_parseSpine` / `_itemRelHref` / resources map 三处仍在用 `canonicalize` 的结果当真实路径。已实测确认：31/32 章、33/38 资源的路径大小写与磁盘不符。
