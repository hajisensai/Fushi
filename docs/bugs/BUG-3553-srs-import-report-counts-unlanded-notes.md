## BUG-3553 · 复习：导入报告把落库时已存在的笔记也算作新增
- **报告**：2026-10-19（PR #2336 审查遗留，协调要求根本性修复）
- **真实性**：✅ 真 bug，测试复现：导入读过「本机已有笔记」之后、同一 guid 的笔记落库（同步应用了对端迁移），报告 notesAdded 仍是 63（实际新建 62）。根因（修前）`packages/fushi_engine/lib/srs/apkg/srs_apkg_import.dart` `_importNote` 在攒草稿时就 `report.notesAdded++` / `cardsAdded += cards.length`；落库时这些初值草稿可能被 `_dropAuthoredInitials` 去掉、身份记录也已存在。
- **[x] ① 已修复** — `SrsDbStore.importDrafts` 在写锁内返回本批身份记录里落库前已存在的实体 ID（`_existingEntityIds`）；导入器把新笔记记进 `_pendingNewNotes`，`_flush` 落库后按实际新建计 notesAdded / cardsAdded，已存在的计 notesSkipped。
- **[x] ② 已加自动化测试** — `srs_apkg_import_test.dart`「报告按实际新建计数…」（进度回调里落库同一 guid 的笔记）；变异实测：忽略 importDrafts 的返回值，测试红（notesAdded 63）。
- **备注**：
