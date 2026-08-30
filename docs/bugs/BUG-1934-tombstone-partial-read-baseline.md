## BUG-1934 · 远端删除墓碑单条读失败被跳过，基线照常推进 → 该条删除永久不再提示

- **报告**：2026-08-29（用户：同步报告里出现 4 条
  `deletion tombstone "favoritesentence__…_video_Hibike__Euphonium_2_-_01…json" unreadable:
  HandshakeException: Connection terminated during handshake`）
- **真实性**：✅ 真 bug（不是单纯网络噪音——它会留下**永久**后果）
  - 根因 `fushi/lib/src/sync/sync_orchestrator.dart:1119-1131`（消费循环里读失败只
    `report.noteError(...) + continue`）配合 `:1155-1160`（候选循环无条件
    `report.noteDeletionHighWater(_scope, at)`）。
  - 删除消费基线（`sync_deletion_tombstones_baseline_ms`，`SyncRepository
    .setDeletionTombstonesBaselineMs`）是**标量**：UI 复核完一批候选后
    （`fushi/lib/src/sync/deletion_prompt.dart:356-363`）把它推到本轮最大 deletedAt。
  - 于是「本轮没读出来的标记」被本轮读出来的同伴连坐：设 early(deletedAt=1000) 读失败、
    late(deletedAt=9000) 读成功，用户复核 late 后 baseline=9000；下一轮 early 读得出来了，
    却落进 `if (at == null || at <= baseline) continue;` 的旧闻分支——**永远**不再进候选。
    对端删掉的东西在本机静默留存，用户永远看不到那条确认框。远端标记不做 GC（Phase F），
    所以它就这么一直躺着且永远不可行动。
  - 一次 TLS 握手失败就够触发；用户日志里的 4 条正是这个形态（同一云通道、部分失败）。
  - 同源第二形态：`fushi/lib/src/sync/sftp_sync_backend.dart:372-383` 把读失败
    （`SyncBackendError`）映射成 `null` 而不是抛，于是消费侧 `parseDeletionTombstoneJson(null)`
    返回 null → 静默 `continue`，**连一条错误都不记**，同样的永久压制无声发生。
  - 互联（interconnect）通道无此问题：`_syncDeletionTombstonesLive` 一次
    `getRemoteDeletionTombstones()` 取回全部墓碑，失败即整体抛出，不存在部分观测。
    推送侧 `_pushDeletionTombstonesLive` 早已用 `retryable` 标志实现了同一条纪律
    （异常 → 不推进基线），消费侧只是漏了。

- **[x] ① 已修复** — `sync_orchestrator.dart` 引入「完整观测不变式」：本轮把列出的标记
  **全部**读成 marker 才登记 high-water（=允许 UI 推进基线），少读一条就闭嘴、候选照常上报，
  下轮读全了再推进。三种形态分开对待：
  - 抛异常 → `scanComplete = false`（扣住基线，自愈）；
  - 读回 `null`（后端吞错，如 SFTP）→ 同样按未观测处理，并补记一条 `unreadable`；
  - 内容非法（截断上传/坏文件）→ 这是**永久**状态，重试不会变好，**不**扣基线（否则一个坏
    文件把基线永久钉死、用户每轮重看同一批确认框），但改为如实记一条 `malformed`，不再静默丢。
  扣住基线时额外记一条 `deletion tombstones scan incomplete; consumption baseline held
  until a complete read`，让「为什么这轮没推进」在报告里留痕。
  提交：见本分支 `worktree-tombstone-partial-read-baseline`。

- **[x] ② 已加自动化测试** — `fushi/test/sync/deletion_tombstone_partial_read_test.dart`
  （5 条，跑真的 `SyncOrchestrator.syncDeletionTombstones` + 可控故障后端 `_FlakyBackend`）：
  - 基准：全读成功照常登记 high-water（防止修过头 → 反复骚扰）；
  - 一条抛异常：候选照出、high-water 为空、报告里有 `scan incomplete`；
  - **核心回归**：第一轮部分失败 + 用户复核推进基线 → 第二轮读全后，被跳过的 early 仍能弹出；
  - 读回 null 同样扣基线；
  - 内容非法不扣基线但记 `malformed`。
  变异实测：把 `if (scanComplete)` 改成 `if (true)`（=还原 bug）后 5 条里红 3 条（含核心回归
  条），另 2 条按设计不依赖该守卫；源文件已按 SHA-256 校验字节还原。

- **备注**：
  - 未动 SFTP 后端那处 `SyncBackendError → null` 的映射（它分不清「文件不存在」和「读失败」，
    根治要在 `_guarded`/`_downloadJson` 层区分 not-found）。消费侧现在把 `null` 当未观测，
    已经堵住它造成的静默压制；后端层的区分留作独立改动。
  - 代价：观测不完整的那一轮，用户若在确认框里**保留**（不勾）某条候选，下一轮会再问一次。
    这是有意的取舍——「多问一次」可见可恢复，「静默丢删除」不可见不可恢复。
