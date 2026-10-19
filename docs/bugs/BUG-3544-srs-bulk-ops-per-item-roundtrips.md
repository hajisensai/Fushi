## BUG-3544 · 复习：作用于多张卡 / 多条笔记的批量操作逐条往返，规模一大就慢（批量改卡、重置、换类型、导出、同步、恢复…）
- **报告**：2026-10-19（随 BUG-3543「删除牌组奇慢」一并要求：类似的全部根本性修复）
- **真实性**：✅ 真 bug，与 BUG-3549 / BUG-3543 同一根因：库在后台 isolate，每条语句一次跨 isolate 往返，而批量操作
  逐项读现值 / 读笔记 / 读历史，缓存刷新逐卡查库；个别地方还逐项全表扫描或平方级过滤。语句计数基准
  `packages/fushi_engine/test/srs/srs_bulk_ops_roundtrips_test.dart`（40 → 160 条笔记，即 80 → 320 张卡），行号是修前（提交 9fda0951b2）：

  | 操作 | 入口 | 问题模式 | 修前 file:line | 语句（40 / 160 笔记）修前 → 修后 |
  |---|---|---|---|---|
  | 删牌组（含子牌组） | 牌组列表菜单 | 每卡一事务 + 每事务一次全表扫描 | 见 BUG-3543 | 1105/4345 → 27/35 |
  | 批量移动 / 暂停 / 搁置 / 旗标 | 浏览页 `_cardFieldBatch` | 每实体读现值 2 次；刷新每卡 ~7 次 | `srs_db_store.dart:1812`、`:1388` | 687/2727 → 16/24 |
  | 批量改标签 | 浏览页 `srsBatchEditTags` | 每笔记 `note()` 3 次 + 每实体现值 2 次 | `srs_browse_ops.dart:143` | 336/1299 → 22/27 |
  | 批量删笔记 | 浏览页 `srsBatchDeleteNotes` | 每实体现值 2 次 | `srs_db_store.dart:1812` | 216/819 → 19/23 |
  | 重置 / 设置到期 / 撤销 | 浏览页、撤销栈 | 每卡 `history()` 4–5 次 | `srs_db_store.dart:1868/1890/1911` | 808/3208 → 19/33（撤销 806/3206 → 17/33） |
  | 立即重排整组 | 牌组设置 | 每卡 `history()` + 每卡重读整棵牌组树（O(卡×牌组)） | `srs_db_store.dart:2027-2045` | 1299/5139 → 24/38 |
  | 更改笔记类型（含旧 Lapis 迁移） | 浏览页 / 迁移页 | 每笔记读两遍笔记 + 一遍卡 + 每实体现值 2 次 | `srs_note_type_store.dart:491/508`、`srs_db_store.dart:1536` | 957/3719 → 49/55 |
  | 删笔记类型 | 笔记类型页 | 每笔记现值 2 次 | `srs_note_type_store.dart:265` | 224/827 → 27/31 |
  | 删字段前的计数 | 笔记类型编辑 | 每笔记 `note()` 3 次 | `srs_note_type_store.dart:127` | 124/484 → 7/8 |
  | 旧 Lapis 预演 / 补迁 / 角标 | 迁移页、牌组列表 | 每笔记 `note()` 3 次；类型逐个物化 | `srs_legacy_lapis_migration.dart:526/599/704` | 同上一行量级（逐条读笔记），已改分块 |
  | 导出 .apkg | 牌组列表 | 每笔记 3 次 + 每卡 4–5 次；每笔记把全部卡行过滤一遍（O(笔记×卡)） | `apkg/srs_apkg_export.dart:123/142/145` | 411/1611 → 15/21 |
  | 优化器取数 | 牌组设置 | 每卡 `history()` | `srs_optimizer.dart:111` | 294/1134 → 12/17 |
  | 同步：应用对端事件 | `applyRemote` | 每事件先查再写 4–5 次 | `srs_db_store.dart:2849` | 2720/10403 → 26/34 |
  | 同步：取发件箱 | `unpublishedEvents` | 每事件最多 4 次 | `srs_db_store.dart:2770` | 1456/5656 → 9/21 |
  | 重新入队 / 服务器时刻 | 恢复后、同步 | 每事件 2 次 | `srs_db_store.dart:2840/2871` | 1187/4547 → 8/11 |
  | 按时间点恢复 | 复习备份页 | 上面几项的组合 + 每卡 `history()` | `srs_point_in_time_restore.dart:367` | 随上面各项一并改 |
  | 备份合并（另开副本 applyRemote + requeue） | 备份合并 | 同「应用对端事件」「重新入队」 | `srs_backup_merge.dart:420` 经 store | 随上面一并改 |
  | AnkiConnect suspend / addTags | 外部工具 | 每卡 / 每笔记一个事务一次刷新 | `ankiconnect/srs_ankiconnect_handler.dart:1100/1121` | 改为一个批次 |
  | 牌组树（所有页面） | `deckTree` | 每牌组 2 次；导入时每建一个牌组重读一遍（O(牌组²)） | `srs_db_store.dart:968` | 2×牌组+1 → 常数 |
  | 每次改卡 / 评分的缓存刷新 | 全部写入 | 找后继卡按无索引 `field_key` 全表扫描（20 万条修改记录桌面实测 ~75 ms / 次） | `srs_db_store.dart:1178` | 部分覆盖索引，只扫前身链接 |
  | 改牌组名 / 挪牌组（改父牌组）/ 收起展开 | 牌组列表 | 单条修改记录，不触发卡刷新 | — | 无问题 |
  | 查找替换 / 批量改字段 / 清空卡 | — | 复习模块没有这些功能 | — | 不存在 |
  | 笔记编辑器改牌组（逐卡 moveCard） | 笔记编辑器 | 每条笔记的卡数有上界（模板数） | `srs_note_editor_page.dart:276` | 无问题（有界） |
  | 词状态查询 | 阅读器 / 弹窗 | 一次一个词，2 次往返 | `srs_db_store.dart:2450` | 无问题（单项） |
- **[x] ① 已修复** — 提交 ded1fcddc9（根因修，不改语义）：
  - 读：`_entityEditsMany` / `notes()` / `noteTypesById()` / `histories()` / `deckTree()` 按 ID 分块（500 / 200）一次预读进
    `_RefreshPrefetch`，在 Zone 里复用原来的单项物化代码（同一套判定），只读、不写。
  - 写：`writeEdits` / `editFieldsBatch` / `_editEach` 先分块预读现值，再在同一独占区里一次分配序号、一次落库；
    `applyRemote` 改用与本机写同一个成批落库 `_storeLocalBatch`（按序在内存视图上判定重复 / 支配，删掉了逐条的
    `_store` / `_storeRow`），服务器时刻与发件箱序号成批合并（`_upsertEventLocal`）；`unpublishedEvents` 按块从四张表各读一次。
  - 缓存刷新：笔记块与「只有卡变了」的卡块都按 200 预读整条血统，写入合成一个 batch；找后继卡走 schema v119 新增的部分
    覆盖索引 `idx_srs_field_edits_history_from`（`packages/fushi_core/lib/src/database/database_srs.part.dart`；查询里
    `+entity_kind` 防规划器改挑 `(entity_kind, entity_id)` 索引）。
  - 立即重排：牌组树只读一次；导出：卡按笔记先分组（消掉 O(笔记×卡)）；优化器：分 1000 张一块取历史（内存只留一块）。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_engine/test/srs/srs_bulk_ops_roundtrips_test.dart`：上表每项「4 倍规模语句数只允许常数级增长」；
    后继查询的执行计划必须是 `COVERING INDEX idx_srs_field_edits_history_from`，前缀与 `SrsFieldKeys` 一致。
  - `packages/fushi_engine/test/srs/srs_bulk_ops_equivalence_test.dart`：批量移动 / 暂停 / 旗标、改标签、删笔记、重置 / 到期 /
    撤销、立即重排、更改笔记类型、删笔记类型、应用对端事件（含批内重复 / 支配 / 同 ID 重复）、服务器时刻 / 重新入队 / 发件箱、
    AnkiConnect suspend / addTags（含重复项）——每项与修前的逐条算法逐表逐字节相同，缓存与整体重建一致。
  - `fushi/test/database/migration_v119_srs_history_from_index_test.dart`：v118 → v119 建索引、计划走索引、数据不动、重跑幂等；
    其余迁移测试的当前版本断言 118 → 119。
- **备注**：
  - 1 万条笔记量级的批量操作仍在秒级，剩下的是逐卡的历史重放 / JSON 解析（UI isolate 上分块进行）；副本整体搬进后台
    isolate 需要改架构，未做。
  - 备份合并另开一个 `SrsDbStore` 实例写同一个库（各自的写入者 / 发件箱序号在各自内存里），是既有设计风险，未在本次改。
