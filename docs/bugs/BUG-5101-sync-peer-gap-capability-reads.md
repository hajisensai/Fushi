## BUG-5101 · 互联对端缺能力判定每轮多读能力表、逐条墓碑重复记错、降级同步被说成没同步
- **报告**：2026-11-22（PR #4021「对端版本过旧统一报出」审查遗留）
- **真实性**：✅ 真 bug，三处：
  1. 明文会话（TLS 默认关，存量互联都是）上 `InterconnectSyncBackend.getRemoteServiceConfig`（`fushi/lib/src/sync/interconnect_sync_backend.dart`，原 :1364）本地判定后返回 `null`，与「老 host 404」共用一个返回值；`_syncServiceConfigLive`（`sync_orchestrator/aggregate.part.dart` 原 :55）一律走 `_notePeerGapLive` → `backend.liveLibraryCapability` → 每轮多一次 `GET /api/capabilities`，违背 PR 描述「正常轮次零额外请求」。老 host + 明文时还会误记一条 serviceConfig「版本过旧」（明文下新 host 同样不给）。且能力表没有按轮复用：各维度、PDF 推送、本地音频身份各自 `_readHostCapabilities()`，一轮里同一份能力表可读 5 次以上。
  2. `_pushDeletionTombstonesLive`（`sync_orchestrator/tombstones.part.dart` 原 :278）逐条墓碑调用 `_notePeerGapLive`；它的去重只看 `report.hasPeerGap`，能力表读失败 / 能力位为 true / declaredOff 不记时都不留痕，于是每条墓碑都再读一次能力表、再记一条 `peer capabilities unreadable`。
  3. `SyncPeerGapDimension.localAudioIdentity` 是降级同步（按显示名匹配，照样同步），`summarizeSyncReport`（`manual_sync_ui.dart` 原 :78）把所有 outdated gap 一律算进「$count 项没同步」。
- **[x] ① 已修复** —
  - 能力表按轮持有：`SyncRunReport._hostCapabilities` 挂本轮那一次读取（连同 backend），`_roundHostCapabilities`（`peer_gaps.part.dart`）供各维度 / PDF / 本地音频共用，成功与失败都复用同一个 Future，不跨轮；backend 去掉 `liveLibraryCapability` / `hostReportsLocalAudioContentId`，只留无缓存的 `readHostCapabilities()`，解析走纯函数。
  - `getRemoteServiceConfig` 改返回 sealed `RemoteServiceConfigPull`（Received / PlaintextSession / EndpointMissing），明文会话不问能力表、不记；只有 404 才判能力位。
  - `SyncRunReport._peerGapsJudged`：`_notePeerGapLive` 每轮每维度只判一次（含读失败的错误行）。
  - `SyncPeerGapDimension.degraded`（仅 localAudioIdentity），摘要分「没同步 / 只能降级同步 / 两者并存」三句（新 key `sync_now_peer_outdated_degraded` / `sync_now_peer_outdated_mixed`，经 i18n_sync 加）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_peer_gap_test.dart`：真 HTTP 老 host 计数「整轮能力表只读 1 次、下一轮重读」、明文 service-config 零请求零记录、能力表 500 时三条视频墓碑只读 1 次只记 1 条、摘要降级 / 并存文案；`interconnect_service_config_test.dart` 明文返回 `RemoteServiceConfigPlaintextSession`。
- **备注**：`snapshotListing`（BUG-3743 书阶段树列举）仍经 SyncBackend 接口自行读能力表（不在按轮复用范围内，书阶段一轮一次，非本 bug 引入）。
