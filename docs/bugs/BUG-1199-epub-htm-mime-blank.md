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
   → **不注入阅读器样式、不注入分页脚本、不做 `sanitizeXhtml` 净化**；
2. `_contentEncodingForMime` 也返回 null（无 utf-8）；
3. `WebResourceResponse` 以 `application/octet-stream` 下发 → WebView 根本不把它当文档渲染。

结果 31 章全空白。只有 spine 第一项 `titlepage.xhtml` 扩展名对得上，所以能显示封面页——用户看到的就是「打开后没有正文」。

`.xht`（同为 EPUB 3 允许的内容文档扩展名）有一样的问题。

**为什么一直没暴露**：日语 EPUB 内容文档几乎清一色 `.xhtml`；`.htm` 主要出现在英文出版社/Calibre 重打包的书里。

**为什么不改成用 OPF 声明的 mediaType**（考虑过并否掉）：项目是**故意**把 XHTML 按 `text/html` 下发的——配合 `ReaderResourceSanitizer.sanitizeXhtml` 规避 BUG-079（`<script/>` 吞整页）与 BUG-737（`<a id=".."/>` 包住全章正文导致查词失效）。若改用 OPF 的 `application/xhtml+xml`，WebView 会转成严格 XML 解析，反而破坏那两个已修的 bug。所以扩展名表就是此处的正确真相源，它只是**不完整**。

- **[x] ① 已修复** — `packages/hibiki_core/lib/src/utils/mime_types.dart` 补 `'htm'` / `'xht'` → `text/html`，与既有 `'html'` / `'xhtml'` 齐平；`packages/hibiki_anki/lib/src/anki_models.dart` 的镜像副本同步（由 `hibiki/test/sync/mime_types_test.dart` 守卫逐项一致）。
- **[x] ② 已加自动化测试** — `hibiki/test/epub/epub_book_utils_test.dart` 新增 `BUG-1199` 组：对 `xhtml`/`html`/`htm`/`xht` 四种扩展名断言阅读器拦截器**同一个**「是否当 HTML 文档处理」谓词为真（不只查表，谓词语义退化也会红），并补 `CHAPTER.HTM` 大小写用例。`test/epub/` + `test/sync/mime_types_test.dart` 共 216 test 通过，`flutter analyze` 零问题。

- **备注**：同一本书还暴露出**另一个独立真 bug**（未在本次修复范围内）：`EpubParser` 用 `p.canonicalize` 生成章节/资源路径，该函数在 Windows 上会**整体小写化**，于是这本书的 `OEBPS/Dick_*.htm` 被记成 `oebps/dick_*.htm`。Windows 文件系统不区分大小写所以侥幸能读，但在 **Android / Linux 上 31/32 章的 `existsSync()` 会全部失败被静默跳过**，只剩 `titlepage.xhtml` 一章。`_safeArchivePath` 早已为 TODO-739 修好了**解压**侧的大小写保留，但 `_parseSpine` / `_itemRelHref` / resources map 三处仍在用 `canonicalize` 的结果当真实路径。已实测确认：31/32 章、33/38 资源的路径大小写与磁盘不符。
