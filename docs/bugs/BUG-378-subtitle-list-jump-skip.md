## BUG-378 · 字幕列表点句多跳一句(skipToCue seek 在途瞬态越过目标句被采纳)
- **报告**：2026-06-21（用户：TODO-664）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_player_controller.dart` 的 `_applySeekTargetSnap`（在途 seek 宽限只保护「远早于窗口」、不保护「越过目标句尾」）+ `cueSnapIndex` 越界判据用 startMs 而非 endMs。
- **[x] ① 已修复** — `cueSnapIndex` 越界判据 startMs→endMs + `_applySeekTargetSnap` 在途宽限期对「越句尾瞬态」也保护（snap 回目标，撑到 seek 落定），对齐有声书 `_explicitSeekInFlight` 抑制范式。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_player_controller_test.dart`：纯函数 `cueSnapIndex` endMs 边界 + 实链路 `skipToCue`→在途越句尾瞬态 tick→断言不多跳（red→green 已验：撤保护时 Expected 1/0 Actual 2/2）。
- **备注**：纯逻辑+源码定位（无头无法播放视频）；真机复测见报告。

### 现象
视频字幕列表点某一句，有时高亮/播放跳到下一句（多跳一句）。播放态、列表点句（`_handleSubtitleJumpTap`→`skipToCue`）路径，「有时」=取决于目标句长 / seek 在途瞬态位置。

### 验真与根因
- 排查交互层（子代理证伪）：列表项点击闭包捕获正确（`video_subtitle_jump_panel.dart:521-539/748/943`）；高亮 `selected=rawIndex==currentIndex`（:524）不经 raw→visible 映射；`itemExtentBuilder` 紧约束（Flutter `sliver_fixed_extent_list.dart:263-271` min==max）使估算行高=实际布局高，**不存在点击命中相邻行**。交互层与页面层（`subtitle.part.dart:79-82` 直通 `skipToCue(cue)`，无 index 转换）干净，真因在控制器。
- 控制器真因：`skipToCue`（:1690）seek 到 `cueStartMs-180`（`kCueSeekPreRollMs` 吸收 media_kit 关键帧吸附，BUG-259），置 `_seekTargetCueIndex=N`+`_seekSnapGraceTicksLeft`，由 `_applySeekTargetSnap`/`cueSnapIndex` 在 seek 落定前后把高亮 snap 回 N（TODO-565）。但旧 `_applySeekTargetSnap` 的在途 seek 宽限**只**保护「effectiveMs < startMs-preRoll（远早于窗口，情形2）」；对「effectiveMs >= startMs（越过句首，情形1）」**无条件清快照**并采用 `findCueIndex` 命中。
- seek 在途时 media_kit position 不随 seek 同步更新（读旧/中间位置），且对**短目标句**关键帧吸附落点会越过整个目标句进下一句。这两种在途瞬态都使 `effectiveMs > 目标句`：旧逻辑情形1 立即清快照 + 采用 `findCueIndex`（命中 N+1 / 旧句）→ 点第 N 句高亮 N+1（多跳）或停旧句。宽限救不了（只管情形2）。

### 修复（消除特殊情况）
1. `cueSnapIndex` 新增 `targetEndMs` 参数：越界判据从「越过句**首** `eff>=startMs`」收紧到「越过句**尾** `eff>targetEndMs`」。落点在 `[startMs-preRoll, endMs]`（preRoll 引导窗口 **或** 目标句区间内，含吸附越句首落句内）一律 snap 回目标句、保留快照。
2. `_applySeekTargetSnap`：在途 seek 宽限（`_seekSnapGraceTicksLeft>0`，position 首次真正落入目标句前）期间，**无论瞬态在目标句之前还是之后**，都消耗宽限、snap 回目标句（撑到 seek 真落地）；position 首次进入目标句（情形3 作废宽限）后才恢复「越句尾清快照」的正常自然播放语义；宽限耗尽（慢设备/seek 丢弃，对齐 BUG-179）放弃保护。与有声书 `AudiobookPlayerController._explicitSeekInFlight` 落定前抑制瞬态同范式。

### 测试 red→green（已实测）
- `cueSnapIndex` 纯函数：endMs 边界（句内 snap 回目标 / 越句尾清快照）+ 短目标句吸附越 endMs 进下一句仍 snap 回目标。
- 实链路 `skipToCue`：①短目标句在途瞬态越句尾(1150)→断言 currentCueIndex=1(非2)；②点靠前句 stale 旧高位置(6500)→断言=0(非2)。临时撤「越句尾在途宽限保护」时两测试转红（Expected 1/0、Actual 2/2），恢复后绿。
- 全量：video 目录 + 字幕列表守卫 891 绿、video+audiobook 1303 绿、`flutter analyze` 0。
