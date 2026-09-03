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
    `fushi.db` / 旧名 `hibiki.db` 开头、但不是本体及 `-wal`/`-shm`/`-journal` 侧车；**这条黑名单
    口径本身有数据丢失 bug，已被下面 ③ 的白名单 + 所有权门控取代**）+
    `listDatabaseSnapshotFiles` / `deleteDatabaseSnapshotFiles(supportRoot)`，与产快照的代码同源，
    活库/侧车结构上删不到；
  - `StorageEntryUsage` 加 `kind`（`book` / `dictionary` / `databaseSnapshots` / `readOnly`），
    可删性从「按类目」改为「按条目」，视图里 `category == books ? … : …` 的特判随之消失；
  - `_scanDatabase` 把全部快照残留聚成**一条** `databaseSnapshots` 条目（标题
    「数据库备份快照（N 个文件）」，字节数=各文件之和，`paths`=清单），活库与其它 support
    子项仍只读单列；删除经 `settings_schema_storage.dart` 接 fushi_core 原语（提交 `50a8610e62`）。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_core/test/database_snapshot_files_test.dart`：口径正/反例、只列直接子层、
    删除只动快照且活库逐字节不变、幂等、根不存在不抛（**这批负例全是恒真的**，见 ④）；
  - `fushi/test/storage/storage_usage_service_test.dart` `BUG-1870：database 明细把主库快照残留聚成
    一条可删条目…`：聚合条目 id/bytes/paths、其余条目全只读且一个不多不少、类目总量不重不漏；
    另一条断言无残留时不出现空聚合条目；
  - `fushi/test/pages/storage_usage_view_test.dart` `BUG-1870：数据库快照残留聚成一条带文件数的
    可删条目…`：真 widget 行为——原始文件名不再出现、翻译标题带文件数、整个类目只有它有删除按钮、
    确认框文案、确认后走注入原语真删文件、活库不动、重扫后聚合条目消失。
- **[x] ③ 首轮修复引入的数据丢失 bug，已根治（代码审查发现，同条追修）** —
  - **根因**：首轮的识别口径是**黑名单**——「以主库名开头 且 不是 `-wal`/`-shm`/`-journal`
    ⇒ 可删」。但 `backup_service.dart` 把一整族**活控制文件**放在同一个 support 根、且同样以
    `fushi.db` 开头：`fushi.db.sync-preserve.json`（`:692` `_preserveSidecar`，待恢复标记，是
    JSON 不是副本）、`fushi.db.merge-preserve.json`（`:2577`）、`fushi.db.merge-src[-wal|-shm]`
    （`:2578`）、`fushi.db.merge-preview-src`（`:2756`）。失败场景：覆盖导入的 device-local 表
    replay 没跑完 → `backup_service.dart:2555-2566` 刻意保留 sidecar + `pre-restore.bak` 等下次
    启动修复（注释原文 “recoverable at the next startup, **but only while BOTH artifacts
    survive**”）→ 用户此时进存储页看到「数据库备份快照（2 个文件）」（确认框还写着「活库不受
    影响」）点删 → 下次启动 `recoverPendingRestore`（`:2905`）第一行 `if (!sidecar.existsSync())
    return;` 静默返回 → LAN 配对、同步基线、被排除的 settings/profiles 层永久丢失，零提示。
  - **为什么黑名单不行**：它的默认值是「可删」。往 `backup_service` 里新加一个以主库名开头的
    控制文件，忘了同步补一行排除，就自动变成用户一键可删——错误方向是丢数据。白名单的默认值
    是「不认识 ⇒ 不碰」，新增控制文件默认安全，代价只是新命名的真残留暂时删不掉（可见、只读）。
  - **改成两层判据**（`packages/fushi_core/lib/src/database/database.dart`）：
    - 层 (a) **形态白名单** `databaseSnapshotMainFileName` / `isDatabaseSnapshotFileName`：只认代码
      真产过的整文件副本命名——`<主库名>.corrupt-bak-<数字戳>.db[-wal|-shm]`（`_rebuildSidecar`
      实际产的是 `.db*` 后缀，PR 注释里的 `[-wal|-shm]` 写错了，已按代码订正）、
      `<主库名>[-wal|-shm].bak.v<数字>.<数字戳>`（已删除的降级救援分支遗留）、
      `<主库名>.pre-restore.bak` / `.pre-merge.bak`。命中即返回它所属的主库名。
    - 层 (b) **所有权门控** `databaseSnapshotOwnerFileName` + `isDeletableDatabaseSnapshot(name,
      siblingNames)`：`pre-restore.bak` 由 `sync-preserve.json` 拥有、`pre-merge.bak` 由
      `merge-preserve.json` 拥有；**sidecar 还在 ⇒ 被它拥有的副本是活的恢复输入，不列出不删除**，
      sidecar 走了才是孤儿。可删性因此由「有没有活的恢复流程指向它」这个真实关系决定。
    - `listDatabaseSnapshotFiles` 的兄弟名集合取自同一次 `listSync`；`_scanDatabase` 复用它已有的
      support 根子项清单做门控，不做二次 IO。dartdoc 里那句「它们都只是整文件副本，没有任何表、
      偏好或引用指向它们」是**假的**，已删除。
  - **删除容错**：`deleteDatabaseSnapshotFiles` 从 `await f.delete()` 裸调用（一个文件被占用就
    抛，剩下几十个一个都不删）改为逐文件 try/catch，返回
    `DatabaseSnapshotDeletionResult{deleted, failures}`；`storage_usage_view.dart` 据实提示失败
    原因，且**部分成功也重扫**（否则页面数字停在删除前的旧值）。
  - **label**：`storage_usage_service.dart` 的 fallback label 不再写死 `support/fushi.db.*`
    （用户机器上那 80 个文件全是 `hibiki.db.*`，一个都描述不到），改为按实际命中的库名生成，
    两个都命中时输出 `support/{fushi.db,hibiki.db}.*`。
- **[x] ④ 本轮补的测试** —
  - `packages/fushi_core/test/database_snapshot_files_test.dart`：**真负例**——原有 4 条负例
    （`local_audio_*.db` / `youtube_stream_cache.json` / prefs / 图标）没有一条以主库名开头，
    第一行 `startsWith` 就短路，测的是平凡性质。新增：`sync-preserve.json` /
    `merge-preserve.json` / `merge-src` / `merge-src-wal` / `merge-src-shm` /
    `merge-preview-src`（新旧两个库名）一律不是快照；形似但不在白名单的名字（戳非数字、缺
    `.db` 后缀、`pre-restore.bak` 挂侧车名、手工改名）一律不认；`pre-restore.bak` 的
    **两向**用例（有 sidecar 不列不删 / 无 sidecar 才清掉，真临时目录）；一个文件被占用
    （Windows 写句柄）时其余照删且失败原样回报。
  - `fushi/test/storage/storage_usage_service_test.dart`：活控制文件留在只读明细里、
    `pre-restore.bak` 的两向门控、label 按实际命中库名生成。
  - `fushi/test/pages/storage_usage_view_test.dart`：部分失败时仍重扫（真 widget 行为）。
  - 五处变异实测均确认对应测试转红并按唯一锚点还原（三个产品文件的 sha256 与变异前逐字节一致）。
- **备注**：`support/local_audio_*.db`（用户机器上 6.2 GB + 1.2 GB 的本地发音库副本）仍是只读
  条目——它们被 `local_audio_dbs` 偏好引用，删除必须走发音库自己的管理入口，不在本条范围。
  其它类目（封面/缩略图/字幕副本等）的只读设计保持不变（有 DB 引用或墓碑护栏）。
  白名单收紧的**已知代价**：用户机器上手工改名的 `hibiki.db.WIPED-*` /
  `hibiki.db.before-v20-realtest-*` / `hibiki.db.v19-discarded-keep` 之类（全仓 git 历史里查无
  产出代码，是人工留底）不再命中，仍按只读单项显示。这是刻意的保守取舍：假阴性只是「留在盘上、
  看得见」，假阳性是永久丢数据。要清它们请手工删或另开一条明确口径。
