## BUG-1458 · 集合同步墓碑用例在develop稳定红-疑日期敏感
- **报告**：2026-08-07（Fushi 改名全量门跑出，agent 定性）
- **真实性**：✅ 真红（在干净 `origin/develop`（a5022cd56 基）本机复跑 2 次稳定失败，与改名分支零 `lib/src/sync` 改动无关）
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：失败用例 `test/sync/sync_orchestrator_collections_test.dart` group「finding1 no self-resurrect on 2nd sync (file lastWrittenAt fold)」，两个 case 交替失败：「same device 2nd sync, peer file unchanged: removed member stays gone」（Expected ['y','z'] / Actual ['x','y','z']，被删成员 x 复活）与「peer republishes member later than tombstone → intentional re-add wins」。时间线证据：2026-08-06 晚同套件同用例绿，2026-08-07 连干净 develop 都红，代码未变 → 高度疑似 lastWrittenAt 折叠逻辑或测试夹具存在日期/时间边界敏感（如跨日、相对时钟基准）。修复者从该 fold 的时间比较处入手复现。
