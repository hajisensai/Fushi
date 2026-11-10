## BUG-4281 · 主机更新跟踪中 host 回 404 时无限每 2 秒轮询、界面卡在进行中
- **报告**：2026-11-10（互联远程长任务审查 R10 成立部分）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/interconnect_host_update_tile.dart:237`（修复前）`_pollOnce` 里 `if (!mounted || status == null) return;`：`status == null` 既不进 catch 的重连窗计时、也不 `_stopTracking`，`Timer.periodic(pollInterval)` 一直跑到 dispose，`_trackingFrom` 不清、行尾一直是转圈。`null` 只来自 `interconnect_sync_backend.dart:1232-1234` 的 HTTP 404（host 回来后不再认 `/api/host/update`：降级、换成无头服务端，或解析到另一台不支持的 host）。修复前新测试实测：404 之后 11 秒内 status 调用数从 5 涨到 10。
- **[x] ① 已修复** — `b5c3460bc42` `_pollOnce` 收到 404 即 `_stopTracking(null)` 并置 `_status = null`、`_hostLacksFeature = true`，副标题复用 `interconnect_host_update_reason_unavailable`；404 是明确应答，不当断连进重连窗。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_host_update_tile_test.dart`「BUG host-update-tracking-null-loops」：触发更新 → 下载中 → host 回 404，断言之后不再轮询、转圈消失、副标题为「主机不提供远程更新」。
- **备注**：残余未修——跟踪期间若解析到另一台**支持**更新端点的 host，GET 回 200 且版本与 `_trackingFrom` 不同，会误报「已更新到 X」。根因是 `InterconnectSyncBackend.getRemoteHostUpdateStatus` 每次 `_reloadSessionFrom` + `_ensureResolved` 不钉 host，归 client-routing 包（跟踪期间按 hostId 钉住请求，或 status 响应带 hostId 由 tile 比对）。
