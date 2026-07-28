## BUG-1203 · EPUB 内容文档按扩展名分类导致怪扩展名章节整本渲染空白
- **报告**：2026-07-28（承接 BUG-1199 的审查结论：扩展名白名单是治标，下一本用别的扩展名的书会以完全相同的方式再空白一次）
- **真实性**：✅ 真 bug（沿真实代码路径定位；与 BUG-1199 同一根因，BUG-1199 只补了白名单的两格）
- **[x] ① 已修复** — 判据换成 EPUB 自己声明的 media-type，扩展名表降为兜底
- **[x] ② 已加自动化测试** — `hibiki/test/epub/epub_book_utils_test.dart`（`BUG-1203: content documents are classified by declared media-type` 组：真谓词行为 + 真查找链 + 源码守卫）
- **[ ] ③ 未做真机复测** — `_readerResourcePayload` 是 `_ReaderHibikiPageState` 的私有方法，挂不上单测；「怪扩展名的书真能渲染出非空正文」这一环只能真机/离屏真实 WebView 验证，本轮**未做**
- **备注**：见下

### 根因

`hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:167`（修复前）无条件

```dart
final String mime = fallbackMimeType(filePath);   // 只按文件扩展名查表
...
if ((mime == 'text/html' || mime.contains('xhtml')) && _settings != null) {
```

EPUB 规范只规定内容文档的 **media-type**（EPUB 3 = `application/xhtml+xml`，EPUB 2 另允许 `text/html`），**不规定文件扩展名**。所以任何扩展名白名单都必然漏：漏掉的章节被当二进制下发，`sanitizeXhtml`（BUG-079 / BUG-737）、样式注入、防闪烁全部跳过 → 书在书架上、目录也解析得出来，但正文一片空白，且**错误日志无任何记录**（不是异常路径，是判据取假）。

BUG-1199（PR#520）往 `mimeTypeForFilePath` 补了 `.htm` / `.xht` 两格，属有意的治标，根因未动。

真相源一直在手边：`EpubResource.mediaType` / `EpubChapter.mediaType`（`hibiki/lib/src/epub/epub_parser.dart:91` / `:473`）已从 OPF manifest 落库，`EpubBook.mediaType()`（`hibiki/lib/src/epub/epub_book.dart:56`）此前**全仓零调用**，而 `_readerResourcePayload` 所在的 State 本来就持有 `_book`。

### 修复

1. `hibiki/lib/src/epub/epub_book.dart` — 新增共享顶层谓词 `bool isHtmlMediaType(String)`，由 `EpubParser._isHtmlMediaType` 提升而来（原私有副本删除，解析器改调共享版），全仓**只此一份**，杜绝平行副本漂移。
2. `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart` — 分类改为 media-type 优先：用已 canonicalize 的 `filePath` 反推出与解析器建表同构造的相对 href，查 `_book?.mediaType(...)`；`EpubBook.mediaType` 自带「manifest 未声明则按扩展名兜底」，故 book 未就绪 / 资源不在 manifest / OPF 缺项三种情况都自然退回扩展名表。判据取 `isHtmlMediaType(declared) || isHtmlMediaType(ext)`——**只放宽不收紧**，OPF 把 xhtml 错标成 `text/plain` 时扩展名仍兜住。
3. **下发的 Content-Type 仍一律 `text/html`**，绝不回 `application/xhtml+xml`：后者让渲染器切严格 XML 解析，出版社 EPUB 普遍存在的 well-formedness 瑕疵会变成整页 parse error，而 BUG-079 / BUG-737 的 `sanitizeXhtml` 是为 HTML5 解析语义写的补偿，切走后不再防护那两类故障。分类与下发被明确拆成两件事。
4. `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` `_buildBookFromDb` — 该 DB 元数据回退路径（OPF 解析失败时走）此前不建 `resources`，media-type 真相源在那条路上是空的，判据会退化回纯扩展名。改为用 `chaptersJson` 里逐章存着的 `mediaType` 灌满 `resources`（key 与解析器同构造），主路径与回退路径共用同一份真相源，拦截器里无需分叉。

### 验证

- `flutter analyze` → No issues found!
- `dart run tool/flutter_test_failures.dart --no-pub test/epub/ test/reader/ test/pages/reader_hibiki_page_*`，VERDICT 见提交说明。
- **变异实测**：把拦截器判据退回 `fallbackMimeType` + 旧谓词后，BUG-1203 组转红（详见 PR 说明）。
- ⚠️ 未做真机复测（见上面 ③）。
