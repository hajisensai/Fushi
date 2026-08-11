## BUG-1580 · 同步冷却戳与聚合快照哈希共用：一条通道压住另一条
- **报告**：2026-08-12（用户：审计）
- **真实性**：✅ 真 bug（沿 app-open 自动 sweep 的真实代码路径核实）

### 根因
**① 冷却戳 `sync_last_sync_ms`**：`fushi/lib/src/sync/sync_orchestrator.dart:616-617` 在**每条**
通道整轮跑完时都写这个全局键，而 `fushi/lib/src/sync/sync_auto_trigger.dart:357-362` 在**通道循环
之外**读它一次，用一个闸门决定两条通道跑不跑。于是：

- 云通道刚跑完 → 局域网互联通道被一起压住 5 分钟（`_syncCooldownMs`）；
- 一条通道失败想在下次 app-open 重试 → 被另一条通道的成功戳压死。

冷却语义是「**这条通道**刚同步过」，不是设备的属性。

**② 聚合快照哈希 `sync_aggregate_last_pushed_hash`**：`fushi/lib/src/sync/aggregate_sync_service.dart:147`
同为全局单键。它是「本端上次推给**某一个远端**的快照内容」的去重记录，跨通道共用会让另一条通道
误以为对端早就有这份快照而跳过 PUT（当下被「远端确实还存在本端那份资产」这条附加判据挡住了大半，
但判据本身不该建立在一份跨通道串味的记录上）。

### 修复
两者都按 `SyncChannelScope`（BUG-1576 引入）分槽：

- `getLastSyncMs(scope)` / `setLastSyncMs(scope, ms)`；冷却判断**移进通道循环**，逐通道各判各的
  （`sync_auto_trigger.dart`）。全部通道都在冷却窗内时结局仍如实报 `cooledDown`，
  一条都没配置才是 `noChannels`——两者在 UI 上必须分得开。
- `AggregateSyncService(db, scope: ...)`，哈希键带槽位后缀。

**迁移语义**：冷却戳 per-channel 键无值时回落旧全局键（升级后第一轮不会把刚同步过的通道当成
从未同步、立刻再跑一轮）。聚合哈希**不做迁移**——纯缓存，代价上限是升级后每条通道多传一次快照，
而快照写入本身幂等。

- **[x] ① 已修复** — 见本文件所在提交
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_channel_scope_test.dart`
  （冷却戳分槽 + 旧全局键作初值 + 一条通道写不影响另一条；聚合服务槽位分离）；
  变异实测同族键（`setCollectionsSyncBaselineMs` 忽略 scope）→ 用例红。
- **备注**：`runCollectionsOnly` 轻量路径照旧不写冷却戳（TODO-1332 语义不变）。
