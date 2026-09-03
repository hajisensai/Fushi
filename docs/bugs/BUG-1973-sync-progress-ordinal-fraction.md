## BUG-1973 · 同步进度文案到 2/2 时进度条仍停在一半
- **报告**：2026-08-30（用户截图：互联阅读数据阶段显示 `(2/2)`，下方进度条只有 50%）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/manual_sync_ui.dart:112` 把零基 `itemIndex` 加一显示成当前项序号，但 `fushi/lib/src/sync/sync_progress.dart:70` 在没有文件字节进度的小型 JSON 项上把缺省内层进度算成 0；因此第二项文案是 `2/2`，进度值仍是 `(1 + 0) / 2 = 50%`。
- **[x] ① 已修复** — 无可测字节进度的原子项按当前可见序号计整步；有 `fileFraction` 的大文件仍按字节比例混合，`2/2` 与进度条统一到 100%。提交：本提交。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_progress_test.dart` 锁定原子项 `2/2 → 1.0`，并保留可测文件从 0 起步、分数混合与钳位覆盖；`fushi/test/sync/sync_activity_visibility_test.dart` 同步校准 banner 行为断言。按用户要求本轮不等待执行 Flutter 测试。提交：本提交。
- **备注**：未做设备截图复测；由 PR CI 补跑完整套件。
