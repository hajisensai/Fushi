## BUG-5124 · web-novel-merge-entries-overwrite
- **报告**：2026-11-22（外部审计 HBK-AUDIT-034，Codex 2026-11-21 PR 审查，涉及 PR #3777 / #3805）
- **真实性**：✅ 真 bug（基线 cbdc2a45ed，沿代码路径确认 + 测试复现）。同一本网页小说书有三个写方，都是「读书行快照 → 改解压树 → 写回书行」，中间隔着网络 / isolate，互不串行：
  - 浏览器并章：`web_novel_reader_launch.dart:182` 预览前读书行，`:208` 等用户确认（可隔很久），`:226` 调 `WebNovelLibrary.save`（`web_novel_library.dart:208`），按**预览时**的快照与旧 `sourceMetadata` 整本就地重建（`:291` `_rebuild`）并把快照整份写回。预览期间阅读器追进来的章不在旧快照里，被直接丢掉（快照与 spine 都没了，正文文件也随重建消失）。
  - 阅读器追章：`web_novel_library.dart:627` 只在写盘前比一次 `current.sourceMetadata != snapshot.raw`，比完到 `:663` 写回书行之间又是多次异步写盘 + isolate；浏览器重建在这段时间落地时，追章把正文写进正被替换的树、把自己的快照写回，之后又被浏览器的快照覆盖，阅读器拿到的「第 i 章已取回」与盘上 / 书行对不上。
  - 开书补占位：`ensureTrailingPlaceholder`（`:253`）用开书时传入的旧行整本重建，同样无协调。
- **[x] ① 已修复** — 784eb9c35b：新增按书提交锁 `webNovelBookCommits`（`KeyedCommitQueue`，`web_novel_library.dart` 末尾），三个写方的提交一律在锁内进行，取页 / 取图留在锁外。锁内**重读书行**：浏览器提交（`save` → `_commitMerge`）在书行快照变过时把同一页重新并进**最新**快照、按最新解压树重建，返回最终序号给开书跳转；新书按作品身份串行「查书架 → 入库」，锁内发现已有就改为并进它（锁序：作品锁 → 书锁）；阅读器追章（`_commitChapter`）书行变过时先看这一章是否已被别处补上，否则重新并进当前快照、仍落在请求的位置才写；补占位在锁内以当前书行判定。
- **[x] ② 已加自动化测试** — `fushi/test/media/novel/web/web_novel_library_test.dart`：「HBK-AUDIT-034：浏览器预览期间阅读器追了新章…」「HBK-AUDIT-034：浏览器并章正在重建解压树时阅读器追章…」（真原生 Rust 连载会话 + 真解压树）。变异实测：去掉锁内重新并章 / 追章提交不进锁，两条各自变红。
- **[x] 审查补修** — 第四个写方：阅读器补取缺图（`WebNovelChapterLoader.retryMissingImages` → `retryChapterMissingImages`）在锁外「复核 → 写图与章节文件」，可夹进整本重建「读旧树打包 → 换树」之间，补到的图被重建冲掉或写进正在替换的树。`retryChapterMissingImages` 加 `commit` 钩子包住复核与写回，网页小说书传按书提交锁；测试「HBK-AUDIT-034：补取缺图的复核与写回进按书提交锁…」，变异实测去掉 `commit` 后该条变红。
- **备注**：真机未复测（审计类修复，取页依赖无界面 WebView，测试走测试缝）。
