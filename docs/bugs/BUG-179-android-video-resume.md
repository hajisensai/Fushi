## BUG-179 · 安卓视频退出重进不从上次位置继续（恢复 seek 失败时守护永久挡住整程位置写入）
- **报告**：2026-06-11（用户：飞书巡检表第87行 / TODO-074「安卓视频播放现在没有断点记忆」）
- **真实性**：✅ 真 bug。位置持久化机制本身平台无关且完整（tick 每秒写、生命周期 flush、退出 await flush、dispose 兜底，见 `video_player_controller.dart` + `video_hibiki_page.dart`），无任何 `Platform.isAndroid` 门控旁路写入。唯一会在 Android 上系统性失效的环节是**恢复 seek 守护**。

### 根因
- **数据流**：进视频 `load(initialPositionMs=上次位置)`。`initialPositionMs > 0` 时设守护 `_restoreTargetMs = initialPositionMs`，等 `_waitUntilSeekable`（最多 5s 等 duration ready）后 `player.seek(target)`。守护期间三个写入点（125ms tick / `flushPosition` / `_forceSavePositionSync`）经 `_isRestoringPast(posMs)` 一律跳过写入，**避免 seek 落地前的过渡期小值（0）覆盖真实进度**（此守护本是 `9a5d27089` 修「每次进去回到 0」加的，方向正确）。
- **缺陷**：旧 `_isRestoringPast` **只**有一条清除路径——`posMs >= target - 1500`（position 追上目标）。但 media_kit/libmpv 在慢设备 / 大文件 / 软解（**Android 尤甚**）上，`open(play:false)` 后发出的 seek 可能被**丢弃或迟迟不落地**：position 停在 0 附近从头播放 → `posMs >= target-1500` **永不成立** → 守护**永久不清** → 这一程用户从头看的每一秒进度全被三个写入点跳过；退出时 `flushPosition` 同样被 `_isRestoringPast` 跳过 → **既没回到上次位置、这次的进度也没记住**，完全符合用户「现在没有断点记忆」。
- **为何桌面不明显 / Android 明显**：桌面 Windows/媒体硬解 open→可 seek→position 反映很快，seek 几乎总落地、守护正常清；Android 软解 / 大容器 / 低端机更容易让 seek 落不了地，命中这条死锁。
- 根因 `file:line`（修复前语义）：`hibiki/lib/src/media/video/video_player_controller.dart` 的 `_isRestoringPast`（守护只靠「追上目标」单条件清除，seek 失败即永久阻塞）。

### ① 修复
- **[x] ① 已修复** — 给恢复守护加**有界宽限**（不掩盖症状，是补全守护的终止条件）：新增 `_restoreGuardTicksLeft`（`load` 设守护时重置为上限 `_restoreGuardGraceTicks = 80`，约 10s @ 125ms tick，> `_waitUntilSeekable` 的 5s 上限）。`_isRestoringPast` 双清除路径——(1) position 追上目标（原逻辑，正常恢复立即清）；(2) 连续 80 次观测仍未追上 → 判定 seek 实际未落地（恢复失败），主动 `_clearRestoreGuard()` 放弃守护，让写入恢复正常。宁可这一程从 0 起记，也不再永久吞掉进度。正常恢复路径不消耗到配额底，零行为变化。
- 修复 `file:line`：`hibiki/lib/src/media/video/video_player_controller.dart:111`（`_restoreGuardTicksLeft`）/ `:119`（`_restoreGuardGraceTicks=80`）/ `:390,396`（`load` 重置宽限）/ `:599-621`（`_isRestoringPast` 双清除 + `_clearRestoreGuard`）。
- 提交：见分支 `codex/todo-074-android-resume`（填提交哈希）。

### ② 测试
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_player_controller_test.dart` 新增 group「BUG-179 恢复守护有界宽限」（经新测试钩子 `debugPrimeRestoreGuardForTesting` 在不实例化 libmpv `Player` 的前提下摆出「load 后正处恢复守护中」状态，用 `debugUpdateCueForPosition` 喂位置序列、观测 `onPositionWrite` 调用）：
  1. 正常恢复：position 追上目标后立即清守护、本次写入放行、之后照常持久化；
  2. 恢复失败兜底：position 始终远低于目标，宽限耗尽后守护被放弃，**这一程从头看的进度被正常记住**（修复核心）；
  3. 回归：喂超宽限上限、始终远低于目标的位置序列——旧实现守护永不清、`writes` 恒空（红），修复后 `writes` 非空（绿）。
- **TDD 红验证**：临时把 `_isRestoringPast` 宽限分支退回旧行为（`return true`），用例 (2)(3) 转红、(1) 仍绿（走追上路径），证明测试真抓根因；还原后 39 用例全绿、`test/media/video` 397 通过。
- **备注**：纯逻辑 + 测试钩子覆盖守护门控根因；但**真 Android 真机/真模拟器退出重进同一视频从上次位置续播**仍需用户真机复测留证据（media_kit headless 不可在单测里跑真实 libmpv seek，无法在 host 复现 Android 的 seek 落地失败本身）。
