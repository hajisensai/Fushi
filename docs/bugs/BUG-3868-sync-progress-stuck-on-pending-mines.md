## BUG-3868 · sync-progress-stuck-on-pending-mines
- **报告**：2026-10-28（用户：「为什么一直要同步待发制卡」）
- **真实性**：✅ 真 bug（显示错误，不是真的在传卡）。① `fushi/lib/src/sync/sync_orchestrator.dart:932` 只要装配了 `pendingMineRelay`（`sync_auto_trigger.dart` 每轮完整同步无条件装配）就公布 `SyncPhase.pendingMines`，而 `PendingMineRelay.run` 在本机没认领落地、也没待中转卡时一个请求都不发；② 它是编排的最后一个阶段 tick，`orchestrator.run()` 返回后的后置步骤（复习同步 `syncChannelPostRunHook`，可能跑很久）与库页刷新都不发 tick，`syncProgress` 直到整轮结束才清（`_endSyncActivity`），进度行就一直挂着「同步待发制卡」。
- **[x] ① 已修复** — `PendingMineRelay.run` 新增 `onRemoteWork` 回调，只在确定要碰远端时调用一次，编排器在回调里才公布该阶段（判据只写一处）；新增 `SyncPhase.finishing`（「正在收尾」，i18n `sync_progress_finishing`），`_runSyncChannelInner` 在 `orchestrator.run()` 返回后、后置步骤之前发出。
- **[x] ② 已加自动化测试** — `fushi/test/anki/pending_mine_relay_test.dart`「onRemoteWork 只在真要碰远端时调用」。
- **备注**：收尾阶段的发出点在私有 `_runSyncChannelInner`，未单独加测试；`syncPhaseLabel` 的 switch 对枚举穷尽，漏标签编译不过。
