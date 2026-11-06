## BUG-4143 · 打开同步冲突页把重复建议里每条笔记的全部修改记录读回，大库 22 万条 / 441 MB 后进程被杀
- **报告**：2026-11-06（应用内反馈 IBjxAjty39 附带日志：冲突页打开期间 `sql:SELECT srs_field_edits` 29 次、合计 22.5 万行 / 441 MB，内存涨到 1.7 GB 后进程消失）
- **真实性**：✅ 真 bug。冲突页 `_reload`（`fushi/lib/src/pages/implementations/srs/srs_conflicts_page.dart:209`）调 `duplicateNoteGroups()`（`packages/fushi_engine/lib/srs/srs_duplicate_notes.dart:62`），它把所有成组笔记 ID 交给 `_dismissedPairs`（同文件 `:95` / `:144`），后者走 `entityEditsMany(SrsEntityKind.note, ids)`（`:146`）按 500 个一块把这些笔记的**全部**修改记录（含字段正文 json）读回、交给寄存器内核物化，只为挑出 `notDup/` 键。两台设备各导入过同一个包的库几乎每条笔记都成组，29 次 = 一次调用的 29 个 500-ID 块（约 1.4 万条笔记），不是页面重复刷新。
- **[x] ① 已修复** — 新增 `SrsDbStore.noteFieldKeyPrefixValues(ids, prefix)`：`field_key` 前缀区间条件落在 `idx_srs_field_edits_profile_register` 上，只读这一类键的记录再交给寄存器内核；`_dismissedPairs` 改用它，读回行数只等于真有的「不是重复」记录数。状态仍归 SQL 存储 / 寄存器内核，Dart 不留镜像。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/sync2/srs_duplicate_notes_test.dart`「找重复组只读『不是重复』记录…」：5 组重复、标 1 组后断言读回行数恰为 2、无标记时为 0，且被标组不再建议；回退修复后该断言红（Expected 2, Actual 0）。
- **备注**：
