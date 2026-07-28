## BUG-1218 · EPUB 解析把路径折成小写，大小写敏感平台上整本章节静默失踪

- **报告**：2026-07-28（诊断 BUG-1199 / BUG-1203 那本书「`Do Androids Dream of Electric Sheep？.epub` 打不开」时发现的**第二个独立根因**）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/epub/epub_parser.dart`（`_parseSpine` / `_itemRelHref` / resources map / TOC nav+ncx 四处）+ `webview.part.dart` 三处 + `chrome.part.dart` 一处

### 根因

`p.canonicalize` 在 **Windows** 上会把整条路径**折成小写**（`path` 包 `lib/src/style/windows.dart:181` `canonicalizePart(part) => part.toLowerCase()`；POSIX style 无此覆写，见 `lib/src/internal_style.dart:89`——**macOS / Linux / Android 上并不折**。审查更正：原文把 macOS 一并算进来是错的；仓库既有注释 `reader_hibiki_source.dart:657` 也沿用了同一误解）。解析侧与阅读器侧共 8 处直接拿它的结果当**真实读写路径**，于是那本 Calibre/Sigil 重打包书里的

```
OEBPS/Dick_9780345508553_epub_c01_r1.htm   （磁盘上的真实条目）
oebps/dick_9780345508553_epub_c01_r1.htm   （解析后记下来的路径）
```

Windows 文件系统不区分大小写，所以在 Windows 上侥幸能读、问题被完全掩盖。

**审查更正（触发链）**：因为 POSIX style 不折大小写，「在 Android/Linux 上原生导入 + 解析 + 打开」这条路径**不会**触发本 bug——那里 `canonicalize` 算出的就是真实大小写。真正的触发链是**跨平台数据搬运**：在 Windows 宿主导入时路径被折成小写并**落库**（`coverPath` / `chaptersJson` / `tocJson`），随后经**备份还原或裸数据拷贝**到大小写敏感设备，而那些消费方**不重新解析**，于是 `File(join(extractDir, "oebps/images/cover.jpg"))` 找不到真实的 `OEBPS/Images/Cover.jpg`——这正是仓库既有的 TODO-1319 / BUG-612 在 `hibiki/lib/src/media/sources/reader_hibiki_source.dart:657-670` 记录、并靠**事后大小写不敏感重扫**兜底的场景。

因此本修复的价值是**根因修**：让 Windows 上落库的路径从源头就是真实大小写，根除这一整类问题，而不是继续让各消费方各自加兜底。原文「Android/Linux 上 existsSync 全部为 false、`_parseSpine` 把章节逐条静默跳过」描述的是**未经重新解析地直接使用已折小写路径**的情形，不是 Android 上原生解析的情形。

实测那本书：**31/32 章、33/38 个资源**的路径大小写与磁盘不符。

这与 BUG-1199 / BUG-1203（按扩展名猜 MIME 导致整本空白）是**两个独立根因**，恰好叠在同一本书上：那个让 Windows 上打不开，本 bug 让 Android/Linux 上打不开。

**为什么一直没暴露**：日语 EPUB 内部路径习惯全小写（`item/xhtml/…`、`text/…`），大小写混排主要出现在英文出版社/Calibre 重打包的书里；而项目主力验证平台是 Windows，那里这个 bug 不可见。

`_safeArchivePath` 早在 TODO-739 就为**解压**侧修好了同一个坑（其注释详细写了大小写折叠如何把 `META-INF` 写成 `meta-inf`，以及为什么必须「校验用 canonicalize、落盘用 normalize」两种形式分开），但**解析**侧四处一直没跟上这个结论。

- **[x] ① 已修复** — 新增 `EpubParser._resolveWithinExtract()` / `_relHref()`：**边界校验用 `p.canonicalize`**（大小写折叠，`../` 逃逸不被大小写差异绕过）、**真实路径用 `p.normalize`**（同样折叠 `.`/`..` 段但保留大小写），与 `_safeArchivePath` 同款。改用处：
  - `epub_parser.dart` 4 处：`_parseSpine`（章节 href + `File`）、`_itemRelHref`（封面）、resources map（键 + `filePath`）、`_parseToc`（nav + ncx）；
  - `webview.part.dart` 3 处：`_readerResourcePayload`（读取路径，并把 BUG-1203 的 `declaredHref` 反推基准同步换成 `normalize` 形式——两侧同时保留大小写，既能读到文件、又仍然对得上 resources 键）、`_chapterFilePath`、`_imageFileSizeBytes`；
  - `chrome.part.dart` 1 处：`_readerImageFileForUrl`（图片查看器 / 分享）；
  - **审查补漏的第 9 处**：`reader_hibiki_page.dart` `_buildBookFromDb`（BUG-1203 加的「OPF 解析失败」回退路径 resources 填充）原样留着 `p.canonicalize` 建键与 `filePath`。parser 侧和拦截器侧都改成保留大小写后，三方变成 2:1 不一致——混合大小写的书在这条回退路径上 `resources` **永远查不中**，BUG-1203 的「OPF media-type 优先」静默退回扩展名兜底；`filePath` 折成小写更让大小写敏感平台读不到文件。已按同款「校验 canonicalize / 读写 normalize」补齐。

  其中 `_chapterFilePath` **必须**同步改：它的注释明说要与拦截器 "cache keys line up"，只改一侧会让 BUG-270 的章节 LRU 两边 key 一个折成小写一个原样而**永不命中**。

- **[x] ② 已加自动化测试** — `hibiki/test/epub/epub_path_case_preserved_test.dart`（复刻用户书结构：根级 OPF + 混合大小写 `OEBPS/Dick_*` + `Images/COVER.jpeg` + `Meta/TOC.ncx`）：章节 href、资源键与 `filePath`、封面 href 分别与 `listSync` 列出的**真实磁盘条目名逐字节比对**；NCX 能被找到（路径折小写会让 TOC 静默变空）；zip-slip 防护不被削弱（逃逸条目仍被丢弃、合法章节仍保留）。

  逐字节比对而非 `existsSync` 是刻意的：**本地跑在 Windows 上 `File.exists` 不区分大小写，只断言 `existsSync` 根本抓不到这个 bug**。

  **测试有效性已验证**：把 `_resolveWithinExtract` 的返回值临时改回 `p.canonicalize`，该文件 5 条中 4 条立刻转红，报的正是 `Expected: Images/COV… Actual: images/cov…`，确认不是弱断言假绿。

- **[ ] ③ 未做真机复测** — 本机是 Windows，恰好是这个 bug **不可见**的平台；结论「Android/Linux 上章节会被跳过」由「解析出的路径与磁盘条目逐字节不符」推出，未在真机/模拟器上打开这本书复验。应在 Android 模拟器上走原始失败路径确认。

- **备注**：对存量书零影响——`chaptersJson` 在 `path_rebase_coverage.dart` 标注为 `notAPath`，开书走 `parseFromExtracted` 重新解析、DB 只复用字数；旧书 `tocJson` 里存的小写 href 由 `EpubBook.chapterIndexForHref`（TODO-796）既有的大小写不敏感兜底 pass 兜住，TOC 跳转不回归。另：`hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:346` 有同样的 `p.canonicalize(p.join(...))` 当真实路径的模式（漫画解压 zip/cbz 同样可能混合大小写），属独立子系统、独立导入与渲染路径，未在本次范围内。
