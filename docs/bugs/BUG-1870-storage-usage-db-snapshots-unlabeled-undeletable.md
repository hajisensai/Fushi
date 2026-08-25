## BUG-1870 · 存储页「数据库与内部数据」把几十个数据库快照残留按原始文件名逐条列出且无法删除
- **报告**：2026-08-25（用户：「存储里面好多磁盘占用名字没正常显示，并且没办法删除」）
- **真实性**：✅ 真 bug。用户机器 support 根（`D:\APP\HIBIKI_date\support`）实测有 ~80 个
  `hibiki.db.bak.v16.<stamp>` / `hibiki.db-wal.bak.v20.*` / `hibiki.db.WIPED-*` /
  `hibiki.db.corrupt-*` 之类的旧迁移快照（当前代码只产 `fushi.db.corrupt-bak-<stamp>[-wal|-shm]`，
  见 `packages/fushi_core/lib/src/database/database.dart` `_rebuildSidecar`），存储页
  `StorageUsageService._scanDatabase`（`fushi/lib/src/storage/storage_usage_service.dart`）把
  support 根**每个直接子项一条**按 `support/<原始文件名>` 铺出来（前 20 条 + 「其余 N 项」），
  在用户眼里就是一堆看不懂的名字；而 `StorageUsageView._buildEntryRows`
  （`fushi/lib/src/pages/implementations/storage_usage_view.dart`）的可删性按**类目**判定
  （`id == books || id == dictionaries`），数据库类目整体只读——用户无法清掉这些没人引用的
  副本。书籍/词典条目不受影响（22 本书标题全非空，已按 DB 复核）。
- **[x] ① 已修复** —
  - fushi_core 新增主库快照的**唯一识别口径** `isDatabaseSnapshotFileName`（以主库名
    `fushi.db` / 旧名 `hibiki.db` 开头、但不是本体及 `-wal`/`-shm`/`-journal` 侧车）+
    `listDatabaseSnapshotFiles` / `deleteDatabaseSnapshotFiles(supportRoot)`，与产快照的代码同源，
    活库/侧车结构上删不到；
  - `StorageEntryUsage` 加 `kind`（`book` / `dictionary` / `databaseSnapshots` / `readOnly`），
    可删性从「按类目」改为「按条目」，视图里 `category == books ? … : …` 的特判随之消失；
  - `_scanDatabase` 把全部快照残留聚成**一条** `databaseSnapshots` 条目（标题
    「数据库备份快照（N 个文件）」，字节数=各文件之和，`paths`=清单），活库与其它 support
    子项仍只读单列；删除经 `settings_schema_storage.dart` 接 fushi_core 原语（提交 `<hash>`）。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_core/test/database_snapshot_files_test.dart`：口径正/反例（现行 corrupt-bak、
    pre-restore、历史 bak.v16 / WIPED / before-v20 命中；新旧活库与三种侧车、`local_audio_*.db`、
    prefs、图标不命中）、只列直接子层、删除只动快照且活库逐字节不变、幂等、根不存在不抛；
  - `fushi/test/storage/storage_usage_service_test.dart` `BUG-1870：database 明细把主库快照残留聚成
    一条可删条目…`：聚合条目 id/bytes/paths、其余条目全只读且一个不多不少、类目总量不重不漏；
    另一条断言无残留时不出现空聚合条目；
  - `fushi/test/pages/storage_usage_view_test.dart` `BUG-1870：数据库快照残留聚成一条带文件数的
    可删条目…`：真 widget 行为——原始文件名不再出现、翻译标题带文件数、整个类目只有它有删除按钮、
    确认框文案、确认后走注入原语真删文件、活库不动、重扫后聚合条目消失。
- **备注**：`support/local_audio_*.db`（用户机器上 6.2 GB + 1.2 GB 的本地发音库副本）仍是只读
  条目——它们被 `local_audio_dbs` 偏好引用，删除必须走发音库自己的管理入口，不在本条范围。
  其它类目（封面/缩略图/字幕副本等）的只读设计保持不变（有 DB 引用或墓碑护栏）。
