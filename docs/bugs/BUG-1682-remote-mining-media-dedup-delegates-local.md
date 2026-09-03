## BUG-1682 · 制卡到已配对设备时媒体去重委派本地仓库，手机上整区隐藏
- **报告**：2026-08-16（用户：手机看不到 anki 媒体存储优化）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/anki/remote_mining_anki_repository.dart` 的 `supportsMediaMaintenance => _local.supportsMediaMaintenance`（连同 `runMediaDedup` 也委派 `_local`）。

  开了「制卡到已配对设备」时卡片落在**主机**的 Anki 上，重复媒体也堆在主机的 `collection.media` 里，客户端本机连那个目录都没有。委派本地的后果：Android 上本地是 AnkiDroid（`supportsMediaMaintenance` 恒 false），于是明明主机能去重，手机上整区隐藏；而同一屏上方的 note type 编辑（`supportsNoteTypeEditing => true`）**已经**走远端。同一个「制卡到已配对设备」模式下，两个维护动作指向两台不同的机器，自相矛盾。

  把「配置类方法一律委派本地」这条规则套到了不该套的地方——去重不是配置，是对媒体库的实际改写，必须跟随卡片落点。
- **[x] ① 已修复** — `RemoteMiningAnkiRepository` 的 `supportsMediaMaintenance` 恒 `true`，`probeMediaMaintenance` / `runMediaDedup` 转发远端；新增主机端点 `POST /api/anki/media/dedup/probe` 与 `/run`（`fushi/lib/src/sync/fushi_remote_api_handlers.dart` + `fushi_sync_server.dart`），主机侧经**自己的** `AnkiMediaDedupRunner` 执行，审计 journal 与「上次去重时刻」落在真正发生删除的那台机器上。`AnkiMediaDedupReport` / `MediaDedupDeletion` 补 `fromJson`（派生值 `duplicatesRemoved` / `bytesSaved` 从 `deletions` 重算，不从 wire 上读）。

  诚实降级：进度与取消跨不过这一次 HTTP 往返，因此新增 `supportsMediaMaintenanceProgress`（本地 true / 远端 false），进度弹窗据此**不画**取消按钮——一个点了没反应的取消按钮比没有更糟，用户会以为已经停了。远端 `dryRun` 缺省是 `true`（真删的决定权在客户端用户手里，缺字段的旧客户端绝不能被解读成「删吧」）。
- **[x] ② 已加自动化测试** — `fushi/test/anki/remote_mining_anki_repository_test.dart` 新增「媒体存储优化经互联作用于主机端」组（恒 true 不被本地遮蔽 / 探测问主机 / 转发带 dryRun / 不支持进度取消 / 主机不支持返回 null 不谎报「没有重复」）；`fushi/test/sync/anki_media_dedup_response_test.dart` 守主机端点契约（缺 dryRun → 干跑、类型错 → FormatException、报告可完整序列化还原）。
- **备注**：与 BUG-1680 / BUG-1681 同批。真机验证仍缺：需要手机 + 桌面主机各一台跑一次端到端。
