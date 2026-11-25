## BUG-4259 · 有声书音画同步偏移未作用于点句跳转 / 单句试听停止点 / 上下句导航
- **报告**：2026-11-09（用户：应用内反馈 G5xYgLcp4p，Android HONOR ROD2-W09）
- **真实性**：✅ 真 bug。音画偏移 `delayMs` 的时基契约是「cue 在音频里真实出现于 `startMs + delayMs`」——播放 tick 侧按 `effectiveMs = pos - delayMs` 查当前句（`fushi/lib/src/media/audiobook/audiobook_controller.dart` `_updateCurrentCue`），片段导出侧 `clipCueSpansWithDelay`（`audiobook_clip_export.dart`）同样平移 +delay，视频播放器上/下一句也按 `cue.startMs + delayMs` seek。但有声书的反方向换算漏了：
  - `audiobook_controller.dart` `_positionForCue`（原 :2663-2668）直接返回 `cue.startMs`，`skipToCue` / `playCueOnce` / `playCueAndContinue` / `replayCurrentCue` / `skipByCues` / `skipToCueIndex` 等所有点句跳转都落在偏移前的位置；
  - `playCueOnce` 的停止点 `_stopAtPositionMs = cue.endMs`（原 :1944）没加偏移，与 tick 的音频时基位置比较，单句试听提前 / 推迟停下；
  - `skipToPrevCue` / `skipToNextCue` / `replayCurrentCue` / `skipByCues` 在没有当前句时按原始 `position.inMilliseconds`（原 :1990 / :2008 / :2027 / :2074）在 cue 时基里查句，偏移不为 0 时选错邻居。
  结果：设置偏移后高亮对得上，但点句 / 上下句 / 单句试听都落在偏移前的位置，用户以为「跳转逻辑有问题」。
- **[x] ① 已修复** — `_positionForCue` 经 `_positionMsForCue(delayMs:)` 统一换算到音频时基（`startMs + delayMs`，下界 0）；`playCueOnce` 停止点改为 `_audioMsForCueMs(cue.endMs)`；按位置查句的导航改用 `_cueTimePositionMs`（`pos - delayMs`，下界 0），与 tick 侧同一变换。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/audiobook_controller_seek_test.dart` 组「cue navigation honours the A/V sync offset (BUG-4259)」：真 `AudiobookPlayerController` + 假 just_audio 平台，断言正 / 负偏移下 `skipToCue` 的 seek 目标、`playCueOnce` 起止点、无当前句时 `skipToPrevCue` / `skipToNextCue` 选中的邻居与 seek 目标。
- **备注**：反馈里「歌词模式下不方便调同步」属于 UX 取舍，未在本条处理。真机复测原始失败路径未做。
