## BUG-1578 · 互联 401 登出的是云会话：鉴权错误不带通道身份
- **报告**：2026-08-12（用户：审计）
- **真实性**：✅ 真 bug（沿手动「立即同步」的真实异常路径核实）

### 根因
互联链路的鉴权失败经 `SyncAuthError` 抛出
（`fushi/lib/src/sync/interconnect_sync_backend.dart:33-110` 的候选探测、
`fushi/lib/src/sync/webdav_ops.dart:117-120` 的 401 分支），裸着穿过 `runManualFullSync` 冒到
`fushi/lib/src/sync/manual_sync_ui.dart:207`。那里的处理是：

- `shouldSignOutOnAuthError`（`manual_sync_ui.dart:66-70`）对 `credentials` 类失败判 true；
- `manual_sync_ui.dart:218-224` 随即登出 `resolveSyncBackend(await repo.getBackendType())`
  —— 也就是**云备份后端**，并顺手 `repo.clearFolderCache()`。

异常不带通道身份，UI 只能按 `backendType` 猜；双通道并存后这一猜必然猜错一半：局域网互联对端
的一次 401（对端重置 token / 换了配对）会**登出用户的 Google Drive 会话并清掉云通道的目录
缓存**——被打坏的是用户没碰过的那条通道，真正出问题的那条一点没动。

### 修复
1. 异常自带通道身份：新增 `SyncChannelAuthError { SyncChannel channel; SyncAuthError error; }`
   （`fushi/lib/src/sync/sync_auto_trigger.dart`），由 `_runSyncChannel` 这个**唯一**通道执行
   chokepoint 包装，自动/手动两条路径都覆盖。
2. 副作用只作用于出错的那条通道：`manual_sync_ui` 改 `on SyncChannelAuthError`，登出
   `e.channel.backend`、只清 `e.channel.scope` 那格 folder 缓存（BUG-1576）。
3. **互联通道不登出**：`shouldSignOutChannelOnAuthError` 在互联通道上恒 false。
   `InterconnectSyncBackend.signOut` 会清空 `sync_hibiki_client_urls`（全部对端地址 + TOFU 指纹 +
   per-peer token），而 BUG-1550 把凭据做成 per-peer 的全部意义就是「一台对端拒了我不株连其余
   对端」——用一台的 401 去清空整份配对配置正是那条修复要消灭的行为。kind 的判据仍委托回
   `shouldSignOutOnAuthError`（BUG-1323 的 403 / browserTimeout 语义一字不动）。
4. 剩下的裸 `on SyncAuthError` 分支**不再做任何登出**：不知道是谁的会话坏了，就不许挑一个去毁。

无持久化键变更，无迁移。

- **[x] ① 已修复** — 见本文件所在提交
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_channel_scope_test.dart`
  （互联 credentials 不登出 / 云通道三种 kind 的原判据 / 通道身份随异常流出 / 槽位与
  manager·orchestrator 同源）+ `fushi/test/sync/sync_auth_error_kind_test.dart` 的源码扫描守卫
  （catch 走的是共享判断、登出对象是 `e.channel.backend` 而非按 backendType 猜）；
  变异实测：删掉 `if (e.channel.isInterconnect) return false;` → 用例红。
- **备注**：互联凭据失效的正确出口是重新配对，不是在同步失败路径上代劳。
