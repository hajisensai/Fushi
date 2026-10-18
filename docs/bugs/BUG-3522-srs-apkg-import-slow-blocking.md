## BUG-3522 · 复习：Anki 包导入慢且阻塞在模态对话框里，不能后台导入
- **报告**：2026-10-18（用户：卡组导入慢，现在可能是同步导入，做成可以后台的）
- **真实性**：✅ 真 bug。基准 `packages/fushi_engine/test/srs/apkg/srs_apkg_import_bench_test.dart`
  （库开在临时文件上、`createInBackground`，与 app 同一种连接）：修前 1500 条笔记（3000 卡 / 9000 条 revlog）**58.2 s**，
  约 39 ms/笔记，语句计数 19730 次 SELECT。根因：
  - `packages/fushi_engine/lib/srs/apkg/srs_apkg_import.dart:988/996/1085`（修前）：每条笔记先 `store.note()` 查库，
    再 `store.createNote()`（身份记录与字段记录**两次事务**、两次缓存刷新），每张卡 `moveCard` / `setSuspended`
    又各一次事务；只有 revlog 攒批。
  - `packages/fushi_engine/lib/srs/srs_db_store.dart:412`（修前 `_storeRow`）+ `:651`（`_emit`）：每条事件「先查再写」
    2–3 次往返，进发件箱再「先查再写」一次；库在后台 isolate，每条语句是一次跨 isolate 消息。
  - `srs_db_store.dart:898`（修前 `_refreshNote`）：每条笔记、每张卡各自查身份记录 / 修改记录 / 服务器时刻 / 日志，
    同类型笔记每条都重新物化一遍笔记类型（模板 + CSS）。
  - `srs_db_store.dart:820`（修前 `_successorsOf`）：每张脏卡按无索引的 `field_key` 全表扫描修改记录表——
    导入几千张卡就是几千次全表扫，随表长成平方级（修后语句耗时从 8.8 s 降到 0.37 s 的大头）。
  - `srs_apkg_import.dart:51`（修前）：解 zip / zstd / 集合在 UI isolate 上同步跑。
  - `fushi/lib/src/srs/srs_import_entry.dart:192`（修前）：`showAppDialog(barrierDismissible: false)` + `PopScope(canPop: false)`
    模态进度框，导入期间整个 app 不可用。
- **[x] ① 已修复** — 提交 e3ad23b2d4：
  - 导入：新笔记 / 新卡的事件（`SrsDbStore.newNoteEvents` / `newEditEvents`，不落库）与日志一起攒批，每约 1000 条事件
    一个事务；开头一次读出本机已有笔记 ID，新笔记不再逐条查库。包解析放 `Isolate.run`。
  - 落库：`_storeLocalBatch` 按 ID 分块预读已有身份记录 / 日志 / 相关实体的修改记录，在内存视图上按序做与 `_storeRow`
    相同的判定，写入合成一个 Drift batch；发件箱 upsert 也成批。
  - 缓存刷新：每 200 条笔记一块，Zone 内预读（`_RefreshPrefetch`，只对本次刷新可见，不泄漏未提交行给并发读者），
    笔记类型每次刷新只物化一次，本次已重算的卡不再算第二遍；前身索引每次刷新一次扫描。
  - 后台化：`fushi/lib/src/srs/srs_import_task.dart` 的 `SrsImportController`（app 级串行队列，范式同
    `DictionaryDownloadController`）+ `startSrsBackgroundImport`（UI 导入与 Anki 一键迁移共用入口）；牌组列表最前的
    任务条（`srs_import_tasks_bar.dart`，MD3 / Apple 走 `FushiCard`，进出场 / 状态切换带尺寸 + 透明度动画）显示进度、
    结果与失败原因；完成 / 失败弹全局提示，并递增 `srsRevisionProvider` 让牌组列表重读。
  - 提速：1500 条 58.2 s → **3.5 s**（≈ 16×；SELECT 19730 → 439 次）；5000 条 ≈ 19 s、1 万条 ≈ 67 s（本机并发负载下）。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_engine/test/srs/srs_write_path_roundtrips_test.dart`：「导入 300 条笔记：SELECT 往返每条笔记不到 1 次」
    （修前约 13 次 / 笔记）、「再导入一次全部判为未变（幂等），不新增事件」；导入语义由既有 `srs_apkg_import_test.dart`
    全部用例覆盖（全绿）。
  - `fushi/test/srs/srs_import_task_test.dart`：控制器串行 / 进度 / 完成与失败回调 / 列表重读 / 临时包清理；任务条与
    牌组列表接线（MD3 + Apple）。
- **备注**：
  - 媒体仍在 UI isolate 上逐个解压 + sha1 + `flush: true` 落盘（`SrsMediaStore.store`）；媒体很多的包这一段仍慢，
    未在本次改（改成并行 / isolate 需要改 `SrsImportMediaSink` 契约）。
  - 导入中途 app 被杀：已提交的批次留在库里，重新导入同一个包幂等补齐。
  - 未做设备肉眼复测（真实大包 + 导入时切到复习页评分），待补。
