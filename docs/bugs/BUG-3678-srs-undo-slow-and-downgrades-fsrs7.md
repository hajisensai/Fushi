## BUG-3678 · Ctrl+Z 撤回极慢且撤回后降级成 FSRS-7
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：Ctrl+Z 撤回极慢，撤回后降级成 FSRS-7。
- **真实性**：✅ 真 bug。根因：`_appendNew` 遇 undo 日志判定历史改写 → 后台全量重建，期间 preparing → preview/answer 带 rwkvUnavailable 走 FSRS-7（`packages/fushi_engine/lib/srs/srs_rwkv_service.dart`）。改为原生撤销日志。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_rwkv_service_test.dart、native/fushi_rwkv/tests/journal.rs`
- **备注**：无。
