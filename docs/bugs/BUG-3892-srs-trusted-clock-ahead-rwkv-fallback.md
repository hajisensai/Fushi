## BUG-3892 · srs-trusted-clock-ahead-rwkv-fallback
- **报告**：2026-10-31（用户：QQ 群反馈「Fushi 时钟偏差 >10 分钟时回退 FSRS-7，导致复习队列无限增长」；用户确认系统时间本身是准的）
- **真实性**：✅ 真 bug，系统时钟不是元凶，是 Fushi 自己推算的「可信时间」错了：
  - `fushi/lib/src/srs/srs_sync_scheduler.dart`（旧 852/880 行）一轮同步**开头**取单调时钟读数 `probedAtMono`，而 `report.serverTimeMs` 是 `packages/fushi_engine/lib/srs/sync2/srs_sync2_round.dart`（旧 318 行）在这一轮**末尾**写完 head 后列目录拿到的 mtime。两者配成锚点后，整轮同步的耗时（2.9 万张卡的大库、卡顿时十几分钟）被全部算成「本机时钟落后」：可信时间超前同样的时长，复习记录与 HLC 写进未来（反馈里是 +10 分 42 秒），并误报「该设备时钟明显超前」。
  - `packages/fushi_srs/lib/src/hlc.dart` 的 `SrsTrustedClock` 按「锚点 + Stopwatch 经过量」推算；Android 上 Stopwatch（CLOCK_MONOTONIC）不计深睡，睡醒后可信时间落后（反馈里手机侧慢约 44 分钟）。
  - 进程重启后锚点失效、退回墙钟，比刚记下的未来时间早 10 分钟：新评分早于已回放的最后一条，`SrsRwkvService._appendNew` 每答一题就全量重建，RWKV 处于「准备中 / 失败」；`SrsDbStore._previewOf` / `_instantInput`（旧 3071、3641 行）此时把 RWKV 牌组退回按 FSRS-7 存下的到期日排队、日志记 `alg: fsrs7`，于是出卡错乱。
- **[x] ① 已修复** — 可信时间改为「墙钟 + 校时偏移」，偏移由服务器 mtime 与写 head 那次上传同一刻的墙钟配对得出（`SrsSync2Report.serverTimeWallMs`），与同步耗时、睡眠无关；校时偏移持久化（同进程内）。删除 RWKV→FSRS-7 回退：RWKV 没就绪时 RWKV 牌组的复习卡一张不出（`SrsStudyState.rwkvPending`），复习页显示 RWKV 的下载 / 回放 / 失败状态并给「重试」，就绪后自动重新排队；日志 `alg` 对 RWKV 牌组恒为 `rwkv`。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/sync2/srs_trusted_clock_anchor_test.dart`（慢同步一轮几分钟后校时偏差 ≤ 半次上传；墙钟真慢 11 分钟时纠到服务器时间；睡眠后照样准；偏移只在本进程有效）；`packages/fushi_engine/test/srs/srs_rwkv_service_test.dart`「权重没下载、下载失败：RWKV 牌组的复习卡不出、标 rwkvPending，绝不退回 FSRS-7 到期日」。
- **备注**：真机复测（Windows 慢同步 + Android 睡眠）未做。peer 之间的时钟差仍可能让同步来的评分早于本机已回放的最后一条，从而触发一次 RWKV 全量重建；重建期间 RWKV 牌组暂停出复习卡（不再回退），这一点是本次修复后的预期行为。
