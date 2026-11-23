## BUG-5233 · 旧 Lapis 补迁预演把每条待补字段的全文攒在迁移页里
- **报告**：2026-11-22（2026-11-22 项目审查 HBK-AUDIT-209，PR #4111 / BUG-5176）
- **真实性**：✅ 真 bug（源码确认）。`packages/fushi_engine/lib/srs/srs_legacy_lapis_migration.dart` 旧 :924 `previewLapisBackfill` 虽然按块物化候选笔记（BUG-5176），判出的 `fill`（目标字段 → 要补的全文）仍逐条存进 `fills`，`SrsLapisBackfillPreview` 整个留着它，迁移页（`srs_legacy_lapis_migration_page.dart` 的 `_backfill`）一直持有。已改类型、旧 Lapis 字段里留着大量长释义的库，预演峰值内存仍随「待补正文总量」线性增长，与 BUG-5176「Dart 不攒逐条内容」的修复意图矛盾。而消费方只用笔记数与字段计数，真正补迁由内核逐条算（`applyLapisBackfill` → `writeRetype`）。
- **[x] ① 已修复** — `SrsLapisBackfillPreview`（`srs_legacy_lapis_migration.dart:556`）只留 `notes` 与 `fieldCounts`；`previewLapisBackfill` 每条判完只累计计数、值随块丢掉（:930 起）。逐条结果只经 `@visibleForTesting` 的 `onFill` 交给测试核对。
- **[x] ② 已加自动化测试** — 新增 `packages/fushi_engine/test/srs/support/srs_lapis_preview_fills.dart` 的 `previewFills`：经 `onFill` 收逐条结果，并断言预演对象的 `notes` / `fieldCounts` 与逐条结果一致；`srs_legacy_lapis_backfill_scale_test.dart`（随机数据与修前实现逐条等价、规模守卫）与 `srs_legacy_lapis_migration_test.dart`（分块一致、只补空字段）改用它。预演对象不再有持有正文的字段，由类型本身保证（旧代码拿 `.fills` 的用法编不过）。
- **备注**：预演判定仍在 Dart 按块做（BUG-5176 现状）；若以后把预演也收进内核（与 `writeRetype` 共用一套判定），可删掉 Dart 的 `srsPlanLapisFieldFill` 预演路径，属另一项重构，本次不做。
