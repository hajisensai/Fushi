## BUG-1575 · 合并导入不 rebase srt_books 路径：迁移后有声书有字幕没声音
- **报告**：2026-08-12（用户：手机上 6 本 SRT 有声书「有字幕、没声音」，书架只给一个「重新定位」按钮）
- **真实性**：✅ 真 bug。用户的真实路径是三段：

  1. 旧包 `app.hibiki.reader` 里经**互联下载**拿到有声书。这一步本身是对的——
     `fushi/lib/src/sync/sync_asset_package_service.dart:247` / `:329` 把 `audioRoot` /
     `audioPathsJson` / `srtPath` / `coverPath` 四列全部写成本机解包目录
     `<documents>/audiobooks/<uid>` 下的绝对路径。
  2. 之后做 hibiki → fushi 改名迁移：`fushi/lib/src/pages/implementations/migration_import_page.dart:194`
     → `BackupService.mergeRestoreBackup`。
  3. 合并引擎 `fushi/lib/src/sync/backup_merge_engine.dart:143` 用
     `_insertMissing('srt_books', 'uid', ...)` 把 srt 行**逐列原样** INSERT（`INSERT INTO
     srt_books (<全部列>) SELECT ...`），四个路径列都是源设备的绝对路径。

  根因在最后一步之后：`fushi/lib/src/sync/backup_service.dart:3851` 的 `_rebaseContentPaths`
  只遍历 `getAllEpubBooks()`（:3866）和 `getAllAudiobooks()`（:3883）两张表，**全文件对
  `getAllSrtBooks` / `updateSrtBookPaths` 零命中**。于是 `srt_books` 行带着**旧 Hibiki 数据根**
  进了 Fushi 库，文件在新根下、行指向旧根 →
  `packages/fushi_audio/lib/src/audiobook/audiobook_storage.dart:193`（`missingPaths`）判定断链
  → 书架（`fushi/lib/src/pages/implementations/reader_history/books.part.dart:229`）只给「重新定位」。
  同一本书的 `audiobooks` 行**被 rebase 了**，字幕 cue 存在 `audio_cues`（不带路径），
  所以症状正好是「一半好一半坏 = 有字幕没声音」。

  这次漂开是**有案底的**：`fushi/lib/src/storage/data_root_migrator.dart:1532` 的注释白纸黑字写着
  「把改写逻辑抄两份（备份恢复侧与迁移侧）迟早漂开，`srt_books` 四列与 `video_books.cover_path`
  就是这么漂开的」——迁移侧 `_rebaseSrtBooks`（`data_root_migrator.dart:995`）一直有，备份恢复侧一直没有。
  守卫 `fushi/test/storage/path_rebase_coverage_guard_test.dart` 只比对**迁移侧**
  （规则 4：列名必须出现在 `data_root_migrator.dart` 里），结构上抓不到备份恢复侧的缺口。
- **[x] ① 已修复** — 两步，缺一不可：

  **A（根因）** `fushi/lib/src/sync/backup_service.dart` 的 `_rebaseContentPaths` 在 `canAudio`
  分支补 `srt_books` 段，四列全处理：`audioRoot` / `audioPathsJson`（逐条 rebase）/ `srtPath`
  （非空）/ `coverPath`（先按 audiobooks 根、再回退 books 根）。同时把 `audiobooks` 与 `srt_books`
  重复的 JSON 列表 rebase 抽成共享的 `_rebaseAudioPathsJson`（坏 JSON 保留原值 + debugPrint，
  绝不中断整次导入），并把 `_rebaseEither` 泛化成「两组可空 (old,new) 依次试」，消掉 srt 侧
  本来要多写的特例分支。DAO 新增 `FushiDatabase.updateSrtBookPaths`
  （`packages/fushi_core/lib/src/database/database_content_misc.part.dart:519`，**按 uid 定位**——
  独立字幕书的 `bookKey` 是空串哨兵且可重复，拿它做 WHERE 会一次改写全部独立字幕书）。
  只加方法不动表/列，**不需要** bump schemaVersion。

  **B（抢救已损坏数据）** 光改导入代码救不了用户手机上**已经**坏掉的 6 本书（迁移已完成、
  中转文件已删）。新增 `packages/fushi_audio/lib/src/audiobook/audiobook_path_relocator.dart`
  （`AudiobookPathRelocator`）+ `SrtBookRepository.repairMovedPaths`，在
  `SrtBookRepository.listAll()` 里列出时自愈——范式照抄仓库既有的
  `VideoBookRepository._repairMovedCoverPaths`（TODO-1255）。三条判据：
  ① 原路径在磁盘上存在 → 一律不动（天然幂等）；
  ② 只碰含 `audiobooks` 段的 app 自管路径（桌面「引用导入」的用户外部文件不猜）；
  ③ 先**后缀重锚**（`<旧根>/audiobooks/<dir>/01.mp3` → `<当前根>/<dir>/01.mp3`，确定解、无歧义）
  再退回**唯一同名**，命中多个就不猜并记日志。只有 basename 一条规则救不了真实用户——
  多本有声书里叫 `01.mp3` 的章节文件遍地都是，必然歧义。
  健康库零代价：先 stat 一遍，没有断链就**不解析数据根、不扫目录**直接返回。
  提交：（本轮由集成方统一提交）
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/backup_srt_path_rebase_test.dart`（A，3 条）：真的走一遍
    `mergeRestoreBackup` / `restoreBackup`，断言四列都 rebase 到新根**且文件真的解析得开**；
    坏 `audio_paths_json` 不中断导入、原样保留，另外三列照样 rebase。
  - `fushi/test/media/audiobook/srt_path_relocate_repair_test.dart`（B，9 条）：后缀重锚、
    有效路径不动、引用导入不碰、唯一同名回退、同名歧义不猜、Windows 路径重锚到 POSIX 根、
    四列一起修、幂等（第二遍 0 行）、只改坏行不碰健康行、健康库不解析数据根也不扫目录、
    `listAll()` 单独就能自愈（走生产的 `AudiobookStorage.documentsRootResolver` 接线）。
  - 变异实测（每条都真跑红过）：srt 循环空转 → A 的 3 条全红；坏 JSON 改 rethrow → 红 1；
    去掉「有效路径不动」守卫 → 红 1；歧义时改成取 first → 红 2；去掉「只碰 app 自管路径」
    守卫 → 红 1；去掉断链短路 → 红 1；`listAll` 不自愈 → 红 1；DAO 改按 `bookKey` 定位 → 红 1。
- **备注**：**未做、留作后续**——`path_rebase_coverage_guard_test.dart` 目前只把
  `kPathRebaseColumns` 与 `data_root_migrator.dart` 双向比对，备份恢复侧（`backup_service.dart`）
  没有对等守卫，所以「两侧漂开」这个**类**问题还会复发。要补得先给声明加上「哪些列归备份恢复侧
  的哪个根管」（backup_service 只管 books/audiobooks/fonts/localAudio/videos 五个根，
  `galgames.cover_path`、`media_collections` 等 documentsRooted 列不归它），一刀切会误判。
