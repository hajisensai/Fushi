## BUG-4382 · 复习「立即同步」报完已同步后同步状态行仍空跑几轮（推送残留 + host 长轮询叫醒写者自己）
- **报告**：2026-11-11（用户：应用内反馈 MJjVyn22mR，复习「立即同步」提示已同步后同步状态行仍循环约 20 秒）
- **真实性**：✅ 真 bug（部分已由重做修掉，剩余部分仍在）。反馈时那一版的「一轮接一轮不停」主因是 BUG-3801（每轮都写 head → host 推进长轮询令牌 → 自己被叫醒再跑一轮），已由 31d1ddcf82（head 没变不写）与 4fdf675c4d（同步拉入不再触发推送）修掉；`syncNow` 现在等全部通道 / 本机目录 / 文件夹位置跑完才返回，提示不再早于这一轮。但最新 develop 上「已同步」之后仍会再跑几轮空同步、同步状态行再从「准备」走一遍：
  1. `fushi/lib/src/srs/srs_app_runtime.dart:550` `syncNow()` 只清推送的退避，`SrsLocalPush.resetBackoff`（`srs_interconnect_watch.dart:208`）还把排着的推送按去抖重新排上——「立即同步」已经跑遍全部通道，10 s 后互联 / 云盘两条推送（+ 本机目录）又各跑一轮，什么都不用推。
  2. `packages/fushi_engine/lib/sync/fushi_sync_server.dart:1256` host 收到任何 head 的 PUT 都推进长轮询令牌，不记是谁写的；`srs_interconnect_watch.dart:99` 客户端只看「令牌变了」就同步，于是写 head 的设备自己也被叫醒，空跑一轮。
- **[x] ① 已修复** — host 的 `SrsChangeFeed` 记最近 64 次推进的写者（已配对设备的专属口令；共享口令 / host 自己发布记为认不出），`/api/srs/changes` 回 `own`：这段推进全是提问设备自己写的。客户端 `SrsInterconnectWatcher` 遇到 `own` 只记新令牌、不跑一轮；老 host 不给 `own` 按 false 照常同步。`SrsAppRuntime.syncNow` 改走 `srsSyncSupersedingPushes`：先撤掉排着的推送（`SrsLocalPush.takePending`）由这一轮带上，这一轮有错 / 抛错再把撤掉的推送排回去。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/sync/srs_change_feed_test.dart`（ownOnly 判定、窗口、挂起中被自己叫醒）、`packages/fushi_engine/test/sync/srs_change_feed_host_test.dart`（真 host：已配对设备 PUT head 后自己的长轮询 `own=true`、别的设备 / 共享口令 false）、`fushi/test/srs/srs_interconnect_watch_test.dart`（ownOnly 不同步、立即同步撤掉排着的推送、失败排回、清退避）。
- **备注**：别的设备收段后 ack 变了会写 head、叫醒本机一轮（ack 供旧段回收），这是协议本身需要的，最多一轮、不循环，未改。「上传复习改动」阶段在没东西可发的一轮里也会闪一下（`srs_sync2_round.dart` 发件前固定报一次），现有阶段次序测试依赖它，未改。
