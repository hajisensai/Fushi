## BUG-2926 · 排行榜后台同步 GET /v1/me 30 秒超时（本机网络间歇丢新 TCP 连接）
- **报告**：2026-10-04（用户：贴 `error_log.txt` 一条 `HomePage.leaderboardSync` `LeaderboardTimeoutException after 0:00:30: leaderboard GET /v1/me timed out`，栈 `LeaderboardClient._sendOnce` → `_ShelfSyncRun._decideReset`（`fushi/lib/src/leaderboard/leaderboard_sync.dart:590`）→ `LeaderboardService.maybeSyncInBackground`）
- **真实性**：❌ **未复现为 app / 服务端缺陷——是本机网络（代理 / TUN）间歇性丢新 TCP 连接，对任何域名都一样**。证据：
  1. **不是持续故障**：同一账户 `lastSyncAt` = 2026-10-04 01:14:51（一次完整同步成功），报错那次 01:45 是 30 分钟节流后的下一次后台尝试。`error_log.txt` 10-03~10-04 共 6 次 `/v1/me` 30s 超时、1 次 `HandshakeException`、1 次 `POST /v1/shelf` 60s 超时，其间也有成功同步。
  2. **服务端排除**：`services/leaderboard/src/worker.js:107` 的 `/v1/me` 只是 `selfView(viewer)`，无外部依赖；未签名 curl 恒 ~0.35s 回 401。
  3. **传输层实测（curl，`--max-time 35`）**——卡死形态全部是 `time_connect=0`、恰好 21s 放弃（Windows SYN 重传上限 = TCP 连接从未建立）：
     | 目标 | 卡死 / 次数 |
     |---|---|
     | rank.fushi.moe 直连（fake-ip 198.18.2.255） | 5 / 40 |
     | rank.fushi.moe 经系统代理 127.0.0.1:34151 | 1 / 40（连本机代理口都没连上） |
     | www.cloudflare.com | 4 / 30 |
     | api.github.com | 2 / 30 |
     | fushi.moe | 7 / 30 |
     与排行榜无关的域名同样 7%~23% 丢连接，故障点在本机代理 / TUN 软件，不在 app。
  4. **app 行为符合设计**：app 经 `createAppHttpIoClient()`（`packages/fushi_engine/lib/utils/net/app_http.dart`）走系统代理；`connectionTimeout` 20s 只覆盖到代理口的 TCP 连接，代理接受后上游 CONNECT / TLS 卡住由 `kLeaderboardRequestTimeout`（30s，`leaderboard_client.dart:82`）兜底抛 `LeaderboardTimeoutException`，`home_page.dart:638-646` 记日志、30 分钟后再试——有界、不挂死、不丢数据（同步状态未推进，下次全量重算）。
- **[x] ① 无需修复** — app 侧没有可修的根因；加重试 / 延长超时只会掩盖本机网络故障，违反根因修复原则。
- **[x] ② 无需新测试** — 超时与后台节流路径已有覆盖（`packages/fushi_engine/test/leaderboard/leaderboard_client_test.dart`、`fushi/test/leaderboard/leaderboard_service_test.dart`）。
- **备注**：用户侧排查方向：代理软件（fake-ip / TUN 模式）的新建连接丢弃率；可用 `curl -w "%{time_connect} %{time_total}"` 对任意站点循环 30 次复核，`000` + 21s 即同一症状。
