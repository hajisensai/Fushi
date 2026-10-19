## BUG-3545 · 复习：本机修改记录的序号在落库前分配，并发写入时发件箱乱序、因果上下文声称看见了不存在的记录
- **报告**：2026-10-19（BUG-3549 回报遗留风险：「批量导入时修改记录序号在落库前分配，可能与并发本机写入乱序」；随 BUG-3543 要求根除）
- **真实性**：✅ 真 bug，已在测试里复现：导入攒批期间插进一条本机写入，发件箱里序号 1028 排在 752 前面。根因（修前行号，提交 9fda0951b2）：
  - `SrsEditWriter.create`（`packages/fushi_srs/lib/src/field_edit.dart:374`）分配 dot 时立刻并进 `applied`；之后任何写入
    的 ctx 都声称看见了它。
  - `packages/fushi_engine/lib/srs/apkg/srs_apkg_import.dart:1066/1158`（修前）：`newNoteEvents` / `newEditEvents` 在攒批时
    就分配序号，攒到约 1000 条才落库；期间别的本机写入（复习页改旗标、评分页暂停）分配更大的序号却先落库、先进发件箱。
    若此时同步发布了一批，对端收到的记录 ctx 覆盖了还没发出的 dot：对端把它们当「已看见」，之后本机这些记录到了，同一
    字段上会被误判为被支配而丢弃；本机若在落库前崩溃，持久化的 `applied` 里还留着永远不存在的 dot。
  - `packages/fushi_engine/lib/srs/srs_db_store.dart:1536/1812`（修前 `writeEdits` / `editFieldsBatch`）：「await 读一个实体的
    现值 → 分配一个实体的序号」交替进行，分配与落库之间夹着几百次往返，同样的窗口。
  - `srs_db_store.dart:2849`（修前 `applyRemote`）与本机写事务失败回滚时，内存里已分配 / 已并入的 dot、时钟、发件箱序号不回滚。
- **[x] ① 已修复** — 提交 ded1fcddc9：
  - `SrsDbStore.runExclusive`（`srs_db_store.dart:249`）：可重入（按 Zone 认）的写入独占区。全部写方法（改字段、批量写、
    建 / 删牌组、建笔记、评分 / 撤销 / 重置、导入、应用对端事件、重新入队、存同步状态、换类型、旧 Lapis 迁移…）都在里面
    完成「读现值 → 分配 → 落库 → 刷新 → 存本机状态」；`_emit` 断言在独占区内。
  - 导入改成草稿：`newNoteDrafts` / `newEditDrafts` 只记「写什么」，序号与 HLC 在 `importDrafts`（`:907`）落库的同一个独占区里
    由 `_finalize`（`:920`）分配——落库顺序 = 序号顺序。
  - `writeEdits` / `editFieldsBatch` 先预读全部现值再一次分配（BUG-3544）。
  - 写事务失败（`_transactionOrReload`，`:3199`）：从库里重读本机状态（丢掉没落库的 dot、时钟、发件箱序号、影响面）再抛出。
  - 按时间点恢复（`srs_point_in_time_restore.dart`）先进独占区再开事务（否则排队等锁的写入与外层事务互等）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_write_lock_order_test.dart`（后台 isolate 库）：
  「导入攒批期间插进来的本机写入：发件箱顺序 = 序号顺序」（修前代码上实测失败：`seq 752 after 1028`，修后通过）；
  「更改笔记类型期间插进来的本机写入」为独占区的性质守卫（修前那段时序在测试里不能稳定复现）。
  导入语义由既有 `srs_apkg_import_test.dart` 全部用例覆盖。
- **备注**：备份合并另开一个副本实例写同一个库，两个实例各有一把锁，互相不排队（既有设计，见 BUG-3544 备注）。
