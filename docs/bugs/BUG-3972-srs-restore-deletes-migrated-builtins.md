## BUG-3972 · srs-restore-deletes-migrated-builtins
- **报告**：2026-11-02（审查 PR #2772 / #2775 发现：按时刻恢复到迁移之前会删掉没改过的内置牌组 / 笔记类型；冻结寄存器向量对拍红）
- **真实性**：✅ 真 bug，三处：
  1. `native/fushi_fsrs/src/store/sync2/timeline.rs:201`（`plan` 的 `created_after`）：实体「那一刻在不在」只看身份记录或任一条内容在不在截面里。迁移来的身份记录墙钟是迁移时刻，旧协议的身份事件不带 HLC；内置牌组（`{"builtin":"default"}`）和没改过的内置笔记类型（`{"builtin":"lapis",…}`）在旧库里一条修改都没有（名字 / 字段 / 模板跟随代码）。所以恢复到迁移之前的任意时刻，它们都会被当成「之后才建的」，写进 `deleted`。在迁移库上实测：修复前 `removed = 4`，内置实体全被删。
  2. `native/fushi_fsrs/src/registers.rs:732`（`note_type_view` 的字段说明循环）：`Entity::is_set` 的文档写了 `fieldDesc/` 也按「null = 未设」处理，但这个循环没有调 `is_set`。null 说明仍物化成空串，盖住内置字段的默认说明。时间线恢复写回的 null 因此还会清掉内置说明，与 BUG-3959 同属一类。
  3. `packages/fushi_srs/test/registers/register_vectors_test.dart`：BUG-3959 有意把生效值为 null 的 `f/` `fieldDef/` `tmplDef/` `fieldDesc/` 改成「未设」，冻结黄金向量的对拍没有跟着适配（343 / 368 行红）。
- **[x] ① 已修复** —
  - timeline.rs：只要任一条身份载荷带 `builtin`，就不算「之后才建的」。内置实体由代码定义，随 profile 一直存在。迁移之后本机做过的修改照常改回（名字改回「没有记录」，跟随代码）。非内置实体保持原规则（身份记录 / 内容的原始时刻）。没有用 `createdAt` 推断身份记录的原始时刻，原因有三：牌组一律写 0；Anki 导入写的是 Anki 里的创建时刻，早于进入本集合的时刻；现有测试 `timeline_restore_compensates_and_can_itself_be_undone` 里，本机新建的无内容笔记 `createdAt = 1`，用它判断就会被误留。
  - 旧 HLC 物理时刻改用 `crate::history::parse_hlc`，不再保留另写的那份解析，`sync2_history` 也改用同一个函数。
  - registers.rs：字段说明循环跳过 null（`is_set`）。
  - register_vectors_test.dart：新增显式调整器 `_withNullMapEntriesUnset`。它不重生向量，只按向量自己的输入改期望：笔记删掉这一项；非内置笔记类型删掉这一项；内置笔记类型回落到代码默认定义，并按 ord / id 重排；字段定义跟随内置时，null 说明回落到内置说明。同 ID 的重复记录按内核「同 ID 留最后一条」取值。实际改动向量 **33 条**，由 `expect(unsetAdjusted, 33)` 钉住。批量测试那一路同样套用这个调整器。
  - 下游核对：笔记缺字段一律按空串处理，涉及 `SrsNoteView.field`（entities.dart:360 `?? ''`）、apkg 导出（`n.field(f.id)`）、卡面渲染 `_fieldsByName`（srs_db_store.dart:4102 走 `n.field`），以及 Rust `NoteInfo` 字段查找（store/caches.rs:256 `map_or("")`）。
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/store/sync2/tests_timeline.rs`：
  - `restore_before_migration_keeps_migrated_builtins_without_edits`：迁移来的内置牌组 + 两个内置笔记类型，均无修改；迁移后本机改了内置牌组的名字；恢复到迁移之前，只删内容全在之后的非内置笔记。去掉修复后实测 `removed: 4`，测试判红。
  - `restore_removes_native_entities_created_after_but_never_builtins`：本机之后新建的无内容实体照删，内置的不删。
  - `packages/fushi_srs/test/registers/register_vectors_test.dart`：8 个测试全绿。用旧 prebuilt 库（没有 fieldDesc 修复）跑，内置说明向量会红。
- **备注**：仍未解决的同类根因：v1 的被支配修改在旧库里已经删除，迁移来的寄存器「那一刻的值」可能已经丢失。例如一个牌组建于 t 之前、t 之后改过名，旧库里只剩改名那条：按时刻恢复到 t 时，它会被当成「之后才建的」删掉；要是它的实体判为「那时已在」，名字又会被写回 null。要解决，迁移时得有可信的身份原始时刻，或者能区分「丢失的历史」和「未设」，旧数据里两样都没有。恢复本身有还原点，可以撤销。
