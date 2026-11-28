## BUG-5614 · 同步编排各维度把取消与凭据失效吞成维度错误，整轮照常跑完
- **报告**：2026-11-28（架构审计顺带发现，审计文档见 PR #4614）
- **真实性**：✅ 真 bug。根因是错误边界**没有单一实现**：
  `fushi/lib/src/sync/sync_orchestrator.dart:869-872` 的 `_noteDimensionError`（各维度
  catch 记失败的唯一入口）只放行 `SyncPeerUnreachableError`；`SyncCancelledException` /
  `SyncAuthError` 是否透传靠各维度自己在 catch 前写 `on X { rethrow; }`，写法各异——
  `online_library.part.dart` / `stream_videos.part.dart` 只放行取消，`book_change.part.dart`
  只放行鉴权，`book_recovery_cloud.part.dart` / 书阶段两者都放行，而
  `tags.part.dart:33-35`、`media_links.part.dart:37-39` / `:104-106` 与其余三十多处裸
  `catch (e)` 什么都不放行。后果：模块在这些阶段途中被关掉时，取消被记成一条「N 项
  失败」、流水线接着跑后续阶段并写冷却戳；互联 401 / 云凭据过期被降级成报告行，`run()`
  不抛，手动同步的登出 / 重新配对分支（`manual_sync_ui.dart` 的 `on SyncChannelAuthError`）
  走不到。另有几处「尽力而为」catch 只 `debugPrint`（`audiobooks.part.dart` 延迟推送、
  `videos.part.dart` 播放进度推送、`book_change.part.dart` 本机清单读失败、
  `_importRemoteAudioIfPresent` 补下音频）同样吞掉这几类错误；书阶段与待发制卡阶段的
  `report.errors.add` 也绕过了 `_noteDimensionError`。
- **[x] ① 已修复** — 判据收成一处：
  - `sync_orchestrator.dart` 新增 `syncErrorAbortsRound(Object)`：取消、对端离线、
    以及 `syncAuthFailureAbortsRound(kind)` 为真的 `SyncAuthError` 中止整轮。鉴权按
    `SyncAuthFailureKind` 逐值 switch（编译器强制穷尽）：凭据失效 / 配对被拒 / 没配对 /
    授权超时或取消 → 中止；403 一族（`forbidden` / `htmlPage`）只属于那一个请求，仍记进
    报告并带类型进 `authFailures`（BUG-1311 / BUG-1324 的既有设计）。
  - `_noteDimensionError` 改为先过 `_rethrowIfAbortsRound`；尽力而为的 catch 也先过它。
  - 删掉 parts 与 `run()` 里 13+4 处各写各的 `on SyncAuthError/SyncCancelledException
    { rethrow; }`；书阶段 / 待发制卡阶段改走 `_noteDimensionError`（日志行逐字不变）。
  - 行为变化：403 一族在书阶段 / 书清单 / 补书阶段以前会冲出 `run()`，现在与其余维度
    一致记成一条带原因的失败、其余维度照常同步（它不触发登出，凭据也没坏）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_round_abort_boundary_test.dart`：
  判据表；标签 / 作品图谱 live 维度抛取消 / 401 / 配对被拒 → 原样冲出、不记报告行，抛
  403 → 只记一条且进 `authFailures`；云通道整轮 `run()` 在合集 / 作品图谱阶段抛取消 /
  401 → `run()` 向上抛、不进删除阶段、不写冷却戳，普通故障 → 记报告、跑完。修复前（把
  `_rethrowIfAbortsRound` 退回只放行对端离线）这些用例全红。
- **备注**：`SyncManager` 书阶段内部的逐本 catch 不在本次范围（不在编排器错误边界内）。
  真机 / 模拟器未复测。
