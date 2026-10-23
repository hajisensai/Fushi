## BUG-3677 · RWKV 每评一张卡全量重算分数
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：RWKV 每评一张卡就全量重算分数。
- **真实性**：✅ 真 bug。根因：`_instantReviews` 缓存键含 changeFingerprint（`packages/fushi_engine/lib/srs/srs_db_store.dart` 约 3303 行），每答一题重查全部候选；Dart 侧 `_queryIdentities` 镜像。改为原生常驻分数表增量（作答→出下一张约 400→160–200 ms）。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_rwkv_service_test.dart、native/fushi_rwkv/tests/journal.rs`
- **备注**：无。
