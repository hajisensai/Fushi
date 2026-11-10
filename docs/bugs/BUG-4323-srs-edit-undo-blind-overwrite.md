## BUG-4323 · srs-edit-undo-blind-overwrite
- **报告**：2026-11-10（用户：内部审查，SRS 撤销语义统一任务）
- **真实性**：✅ 真 bug。SRS 的编辑类撤销是 Dart 闭包把内存里记的旧值原样写回，不看库里的修改记录：做 A → 同步拉进来别处的改动 / AI 改同一张卡 → 撤销 A，后来的改动被无提示覆盖。根因位置（修复前 `50879a4c35b`）：
  - 复习页暂停 / 搁置 / 旗标 / 移牌组 / 删笔记 / 改字段 / 编辑笔记的撤销闭包：`fushi/lib/src/pages/implementations/srs/srs_review_page.dart:1252` `:1266` `:1291` `:1314` `:1359` `:1453` `:1592`
  - 浏览页批量暂停 / 搁置 / 旗标 / 牌组 / 标签 / 删除：`packages/fushi_engine/lib/srs/srs_browse_ops.dart:55` `:169` `:202`
  - 批量改笔记 / 原地改字段：`packages/fushi_engine/lib/srs/srs_note_batch_edit.dart:385`（Dart 侧按值比、不在写锁里）
  - 操作目录（AI）撤销：`fushi/lib/src/ops/op_descriptions_srs.dart:373` `:429` `:452` `:527` `:615`（按内存快照比值；合并整体 superseded）
  - 恢复内置模板的撤销：`packages/fushi_engine/lib/srs/srs_builtin_template_restore.dart:65`
  修复前对照：`srsBatchSetFlag` → B 改旗标并同步 → 撤销，旗标被写回 0（临时 worktree 上复现测试红）。
- **[x] ① 已修复** — 每次可撤销写入在写锁里记撤销凭据（改前值 / 改后值 / 内核分配的 dot，`packages/fushi_engine/lib/srs/srs_edit_undo.dart`）；撤销时内核 `undo_check`（`native/fushi_fsrs/src/store/sync2/undo_check.rs`、`registers.rs` 的 `undo_verdict`）按修改记录只读裁决，只写回之后没被别人动过的键，被动过的保留现值并经 `SrsEditUndoResult.kept` 返回；标签按 OR-Set 差量撤。评分 / 重置 / 改期的日志撤销不变。
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/store/sync2/tests_undo_check.rs`、`packages/fushi_engine/test/srs/srs_edit_undo_test.dart`、`packages/fushi_engine/test/srs/srs_builtin_template_restore_test.dart`、`fushi/test/ops/op_undo_srs_test.dart`、`fushi/test/ops/op_srs_note_batch_test.dart`
- **备注**：没撤成的键在复习页 / 浏览页 / 模板恢复给 warning 提示（`srs_undo_kept_changed`），操作目录撤销结果为 `partial`（全没撤成为 `superseded`），message 列出键与现值。
