## BUG-1311 · 互联同步每轮都报「认证失败」：明文 host 上无条件请求 service-config
- **报告**：2026-08-01（用户：develop 全量体检，主行=2452 第⑤组）
- **真实性**：✅ 真 bug，生产回归。根因 `hibiki/lib/src/sync/sync_orchestrator.dart:366`
  对每条互联通道无条件调用 `_syncServiceConfigLive`，而
  `hibiki/lib/src/sync/interconnect_sync_backend.dart:685` 的
  `getRemoteServiceConfig()` 只对 404 降级、不判传输是否为 HTTPS。
  host 侧 `hibiki/lib/src/sync/hibiki_sync_server.dart:2197-2199` 在
  `_securityContext == null`（明文 HTTP）时**必然**返回
  `403 HTTPS required for service config`——这是有意拒绝（API key 不得降级到明文），
  不是故障。403 经 `hibiki/lib/src/sync/webdav_ops.dart:259-262` 的 `checkStatus`
  被压成 `SyncAuthError('Authentication failed')`（body 里的真实原因被丢弃），
  再由 `sync_orchestrator.dart:527` 的裸 `catch (e)` 降级成一条
  `report.errors` 日志行。
  **爆炸半径**：TLS 默认是关的——`sync_repository.dart:619-620` 的
  `getServerTlsEnabled()` 默认 `false`，且 `applyFirstHostingTlsDefault()`
  只对全新设备置 true，存量 host 一律保持明文。故**所有存量明文互联用户**从
  `df660a55e`（feat(sync): share service config over interconnect）起，每一轮同步
  都稳定拿到一条 `service config live sync: SyncAuthError: Authentication failed`：
  设置页「立即同步」副标题恒显「N 项失败」（`manual_sync_ui.dart:37-39`），
  每轮自动同步向 `ErrorLogService` 打一条噪音（`sync_auto_trigger.dart:121-125`），
  并把用户引去反复重配 token——而 token 根本没问题。
  引入 commit `df660a55e` 新增了无门控调用却没碰
  `hibiki/test/sync/sync_orchestrator_live_*.dart`，故这三条红精确地从它开始。
- **[x] ① 已修复** — `hibiki/lib/src/sync/interconnect_sync_backend.dart`
  `getRemoteServiceConfig()` 开头按会话 scheme 门控：非 `https` 直接返回 `null`，
  不发请求。答案本地就已知，别问。`null` 与「旧 host 404」「host 关掉该能力 404」
  归一到同一条「对端不提供此能力」语义，和 host 自己在 `/api/capabilities` 广播的
  `'serviceConfig': _securityContext != null && ...`
  （`hibiki_sync_server.dart:1188-1189`）逐字一致。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/interconnect_service_config_test.dart`
  新增「明文互联会话不得请求 service-config」：起一台会记录命中路径的明文 HTTP host，
  断言 `getRemoteServiceConfig()` 返回 `null` **且该路径命中数为 0**（不是只断返回值——
  只断返回值的话，把门控删掉换成 `catch` 吞异常也能骗过）。
  同时 `sync_orchestrator_live_{audio,book,progress}_test.dart` 的
  `expect(report.errors, isEmpty)` 由红转绿，是同一根因的端到端复现。
- **备注**：本轮**未**动 `webdav_ops.dart:259-262` 把 401/403 一律压成
  `SyncAuthError('Authentication failed')` 这一层——它被 webdav/ftp/sftp 等多个 backend
  共用，改动面远大于本 bug，且修好门控后该路径在正常配置下不再触发。但它确实是独立缺陷：
  403「策略不允许」和 401「认证失败」语义不同，且 response body 里的真实原因被丢弃。
  另：`sync_orchestrator.dart:527` 是全仓唯一对 `SyncAuthError` 完全不分流、
  与普通网络抖动一视同仁的 catch 点，一并留作后续清理条件。
