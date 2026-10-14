## BUG-3337 · 同时下载多本对端书籍崩溃 / 合集内进度不实时 / 多选合集下载无效 / 下载完成书架跳顶
- **报告**：2026-10-14（用户：应用内反馈 FvgH1f3vZ_，Android 客户端从互联对端下载书）
- **真实性**：✅ 真 bug，四处根因：
  1. **并发下载互相写坏**：远端书 / 随书有声书 / 纯 SRT 有声书的临时落点只按书名派生
     （旧 `fushi/lib/src/pages/implementations/reader_history/remote.part.dart:1835-1842`
     `_remoteBookDestination` 及 `:1811` / `:1821` 两个有声书落点，键 = `_safeRemoteBookKey`，
     非 ASCII 一律打成 `_`）。日文书名大面积撞成同一个 `_.epub`：同时点几本，几条下载往同一
     个 `.part` 里写、`.part.etag` 互相顶掉，导入读到拼坏的 zip（用户日志
     `ReaderFushiHistoryPage.downloadRemoteBook: FormatException: Could not find End of Central
     Directory Record`），甚至把 A 书字节当 B 书入库。附带：`EpubImporter` 解包临时目录只用
     毫秒戳（`packages/fushi_engine/lib/epub/epub_importer.dart:32/71/276`），同毫秒两次导入解进
     同一目录。
  2. **合集内进度不实时**：远端卡的下载态角标在书架页 State 里 `ref.watch`
     （旧 `remote.part.dart:354`），订阅挂在书架上；合集详情页是 push 在书架之上的独立路由，
     成员卡由书架经 `memberCardBuilder` 造出来但不随书架重建，卡停在点击那一刻的状态。
  3. **多选勾合集「下载」无效**：批量栏下载按钮可用态 / 派发只认散卡远端键
     （旧 `reader_history/books.part.dart:503` `enabled: remoteKeys.isNotEmpty`），只勾合集时恒灰。
  4. **下载完成书架跳顶**：书集合一变 `fushiBooksProvider` 因依赖（`_epubBookKeysProvider`）
     变化重算进 reload 态，`books.when` 默认 `skipLoadingOnReload: false` 把整个网格换成转圈
     （`reader_fushi_history_page.dart` `books.when(`），CustomScrollView 被卸掉重建 → 滚动归零、
     卡片进场动画重放。
- **[x] ① 已修复** —
  1. 新增 `fushi/lib/src/sync/remote_download_temp_file.dart`：落点 = `<root>/<任务身份摘要>/<原 basename>`，
     任务身份即 `InterconnectDownloadManager` 去重键（`book:<downloadId>` / `srt:<uid>`），并发任务
     互不共享文件、同任务重试仍可续传；三处落点统一走 `_remoteTempFile`。`EpubImporter.nextTempDirName()`
     加进程内单调序号。
  2. 远端卡（EPUB / 纯 SRT）的下载态在卡自己的 `Consumer` 里订阅，合集内外同一组件同一进度来源。
  3. 构建期按 shelfGroups 记下每个合集格子里的云端成员（`_remoteMembersByCollection`），批量下载
     可用态与派发并入勾中合集的成员（按任务身份去重、仍逐本串行）。
  4. `books.when(skipLoadingOnReload: true, …)`：重算期间保留旧数据，新数据到了原地替换。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_remote_concurrent_download_test.dart`
  （落点身份隔离 + 同毫秒临时目录唯一 + 详情页进度实时 + 只勾合集批量下载 + reload 不跳顶）。
- **备注**：用户所说的「崩溃」日志里没有原生崩溃记录（只有上面那条坏 zip 导入失败）；若修复后
  同时下载仍有进程级闪退，需要用户补 logcat / 崩溃转储再看（低内存机型上多本并行导入的内存峰值
  是未证实的候选）。
