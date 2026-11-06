## BUG-3770 · srs-clock-skew-false-alarm-long-sync
- **报告**：2026-10-21（用户：「怎么说我系统时间不准 超过10分钟」；本机墙钟对比 HTTP Date 实测只差 2.5 秒）
- **真实性**：✅ 真 bug。服务器时间是 `SrsSyncEngine.syncOnce` 一轮开头写探针取到的（`packages/fushi_srs/lib/src/sync/sync_engine.dart:308`），而 `SrsSyncScheduler._syncWithBackend` 等整轮（上传 / 拉取 / 快照）跑完才 `store.anchorTime(serverTime)`（`fushi/lib/src/srs/srs_sync_scheduler.dart:247`），`SrsTrustedClock.anchor` 把锚点单调时钟取成「现在」（`packages/fushi_srs/lib/src/hlc.dart:133`）。于是 `wallSkewMs` 恰好等于整轮耗时，一轮超过 10 分钟（大库首次同步 / 导入大牌组后 / 慢后端）就误报 `srs_sync_clock_skew`；同时可信时间落后同样时长，之后的复习事件时间戳被系统性压早。
- **[x] ① 已修复** — `SrsTrustedClock.anchor` 增 `atMonotonicMs`（+ `monotonicNowMs()`），`SrsDbStore.anchorTime` 透传；调度器在跑引擎前记下单调时钟读数，校时按它算，误差只剩探针前的一次列目录。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_sync_scheduler_test.dart`「一轮同步跑很久：系统时间准就不提示，可信时间不落后整轮耗时」（runner 在一轮里推进 30 分钟测试时钟；去掉修复实测红为 `[SrsSyncNotice.clockSkew]`）。
- **备注**：若用户的后端是互联 host（另一台设备当服务器），服务器时间取自 host 文件 mtime，host 本身时钟不准时这条提示是真提示，与本 bug 无关。
