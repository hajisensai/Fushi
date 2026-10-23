## BUG-3671 · 跳转卡片无防重入锁且加载慢、编辑页无法删卡
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：跳转卡片没有防重入锁且加载慢；编辑页无法删卡。
- **真实性**：✅ 真 bug。根因：`srsPushNoteEditor`（`srs_app_host.dart`）push 后即返回、无登记，可重复进入；编辑页 `_load` 调 `deckSummaries()`（`srs_note_editor_page.dart` 约 85 行）触发 RWKV 全量推理；删除入口只在冲突横幅里露出。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_push_note_editor_lock_test.dart、fushi/test/srs/srs_deck_choices_test.dart`
- **备注**：无。
