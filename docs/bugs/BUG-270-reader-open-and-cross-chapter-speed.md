## BUG-270 · 开书/跨章提速（懒解析章节 + 跨章 LRU 缓存预取）

- **报告**：2026-06-14（用户：能不能每次导入的时候重构书籍，来优化加载速度和跨章速度）
- **真实性**：✅ 真性能问题（非崩溃；TODO-296）。瓶颈不在导入而在开书与跨章两条热路径，二者对所有已有书立即生效，不改 schema 无迁移。

### 根因
- **开书慢**：`EpubParser._parseSpine`（`hibiki/lib/src/epub/epub_parser.dart:303`）对每个 spine 章节调 `_readText(file)`（旧 `:307`）把整本 XHTML 读进 `EpubChapter.html`，开书 `parseBookOnly`→`parseFromExtracted`（`reader_hibiki_page.dart:314`/`:706`）白屏时间随书体线性增长。关键事实：WebView 渲染走 `_interceptRequest`（`reader_hibiki_page.dart:1687`）从磁盘**重新**读章节，根本没用 `_book.chapters[i].html`；内存里的全书 HTML 只服务 `chapterPlainText`（有声书对齐/`_chapterIndexForText`/导入对话框/sasayaki）、`isImageOnlyChapter`/`chapterImageSrc`（spread 分析）、`AudiobookBridge.searchBook`（书内搜索）。
- **跨章慢**：`_interceptRequest`（`reader_hibiki_page.dart:1699`）每次跨章都 `File.readAsBytes`+`utf8.decode`+`sanitizeXhtml`+正则注入 styleTag，无 HTML 缓存（只缓 CSS），正反翻章无命中、无下一章预取。

### A · 开书懒解析
- 改 `EpubChapter`（`epub_book.dart`）：拆成默认构造（eager `html` 内存字符串，DB/legacy 回退 + 导入对话框 + 测试用）与 `EpubChapter.lazy(filePath:)`（首次访问 `.html` 才从磁盘读+解码并缓存，缺文件降级 `''`）。`html` 收敛为单一 getter，消除调用点特例分支。
- `_parseSpine` 改用 `EpubChapter.lazy(filePath: absPath)`（文件存在性在 spine 解析阶段仍校验），开书不再一次性读全书。
- 抽 `decodeEpubText`（`epub_book.dart`，UTF-8/BOM 容错，HBK-AUDIT-033）作单一解码真相源，`_parseSpine`/`_readText` 与懒读共用 → eager 与 lazy 文本字节一致。
- **保有声书对齐**：`chapterPlainText(i)` 经 lazy getter 按同一 `absPath` 读同一文件，内容与旧 eager 完全相同；BUG-060/069 跨章高亮、BUG-061 从本句播放、`_chapterIndexForText` 等仍按需拿到正确章节文本。导入路径 `_computeCharacterCounts`（`epub_importer.dart:233`）在 isolate 内 rename 前读完，字符数计算与落库不变。

### B · 跨章 LRU 缓存 + 预取
- `reader_hibiki_page.dart` `_interceptRequest`：sanitize 后 HTML 进 LRU（按 filePath 键），正反翻章命中跳过磁盘读+decode+sanitize+注入。
- 翻章后台预取下一章（按当前阅读方向）暂存进同一 LRU，跨章近即时。

- **[x] ① 已修复** — A（`300459183`）：`epub_book.dart`/`epub_parser.dart` 懒解析+共用解码器；B（`6a52f5523`）：`reader_hibiki_page.dart` sanitize-HTML LRU + 翻章预取。
- **[x] ② 已加自动化测试** — A：`hibiki/test/epub/epub_lazy_chapter_test.dart`（懒读返回正确内容/删文件后访问证明非 eager/缓存稳定/eager 仍服务内存 html）；B：`hibiki/test/pages/reader_chapter_html_cache_test.dart`（LRU 命中/预取/失效）。
- **备注**：性能优化，非崩溃 bug。提交 A=`300459183` / B=`6a52f5523`（分支 `worktree-agent-import296`，基线 `2609de4a1`/integration/wave-1）。开书/跨章实际提速需真机；host 已验正确性（懒读内容、缓存命中/淘汰、样式失效清缓存）。全项目 `flutter analyze` 0 issue；epub+audiobook 481 绿、reader 405 绿、新测试全绿；`test/pages` 19 项预存红与本改动无关（video/image 守卫扫未改文件，已在基线 `2609de4a1` 复现同 19 项）。
