## BUG-4282 · 播放位置缺基线时退回跨设备墙钟 LWW
- **报告**：2026-11-10（用户：审计 sync-live 修复包 D4a）
- **真实性**：✅ 真 bug：`packages/fushi_engine/lib/sync/fushi_library_host_service.dart:2355-2365`（行号以 3e88ee9d208 为准）`resolvePlaybackPositionThreeWay` 在两端都有戳、位置不同且 `basePositionMs == null` 时比较两台设备各自墙钟的 `updatedAtMs`（较新者胜，平局取较远位置）。文档说只用于升级首轮，代码对任何缺基线的条目都这样做：多 host、从备份恢复的新设备、新配对的 host 上，时钟偏快的一端会静默盖掉另一端的真实进度；书籍进度 `resolveBookProgressThreeWay`（同文件 `:1371`）同情形早已判冲突，两条通道口径不一。新测试修复前实测：无基线、本端 (800, 10) / host (300, 20) 判 `applyRemote`，期望 `conflict`。
- **[x] ① 修复** — （见下方「修复提交」）：该分支改为 `return BookProgressSyncAction.conflict;`，与书籍同口径；函数文档删掉「退回旧口径 LWW 一次」，写明升级首轮的存量基线由按 host 分槽的领养（BUG-4281 `ensureBaselinesAdopted`）保住。两端都无戳「取较远位置」、一端无戳「另一端胜」两条分支不动（不比较时钟）。sweep、实时上报无基线路径（`reportLive` 对 `conflict` 返回 held）、对比弹窗都经 `InterconnectPlaybackPositionSync.decide` 走这一个函数，无需另改。
- **[x] ② 加自动化测试** — `fushi/test/sync/playback_position_conflict_test.dart`（纯函数：无基线、两端有戳且位置不同——本端戳新 / host 戳新 / 戳相等两种位置——全部 `conflict`，修复前红；无基线位置相同 → `synced`）；`fushi/test/sync/sync_orchestrator_live_progress_test.dart`（真 host + 真 client 编排器 sweep：无基线且位置不同 → 报一条冲突、两端都不写、不记基线；原用例断言旧 LWW，期望变化）；`fushi/test/sync/video_watched_mark_sync_test.dart`（setUp 注释写「上次同步已对齐」却没落基线，靠旧 LWW 通过；补上位置基线，断言不变）。
- **修复提交**：
- **备注**：
  - 影响范围：只有「从未记过基线、两端都有戳且位置不同」的条目改为判冲突、弹窗问一次（多 host 用户、从备份恢复的新设备、新配对的 host；`sync_baselines` 不随备份走）。冲突不丢数据，选完即有基线。单 host 带 hostId 的老用户与全是老条目的用户，存量基线经领养 / 无后缀行继续生效，升级首轮判定不变。
  - 降级回旧版后旧代码对这类条目仍走 LWW（旧行为），不受影响。
  - 播放页实时上报对这类条目返回 held，本次播放不向 host 上报，等弹窗裁决；开播判定与 sweep 同源化归计划步骤 10（BUG `remote-video-open-bypasses-three-way`）。
