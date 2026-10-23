## BUG-3720 · 删除牌组（含连卡片删除）只写墓碑，永不物理清除
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：删除牌组（含连卡片一起删）只写墓碑，永不物理清除。
- **真实性**：✅ 真 bug。根因：删除只写删除寄存器、无清除生命周期；新增 `packages/fushi_engine/lib/srs/srs_purge.dart`：90 天后清正文/缓存/无引用媒体，保留复习日志（统计不变），未同步副本仅当场永久删除。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_purge_test.dart`
- **备注**：无。
