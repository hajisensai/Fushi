## BUG-872 · 歌词模式重开书高亮跳回开头
- **报告**：2026-07-18（用户：）
- **真实性**：✅ 真 bug。根因 `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart:463`（`load()` seek 到保存位置后未重算 `_currentCue`）＋ `hibiki/lib/src/pages/implementations/reader_hibiki/lyrics.part.dart:113` 歌词窗口用依赖 `_currentCue` 的 `allBookCueIdx`。
- **[x] ① 已修复** — `load()` 恢复位置后 `_currentCue` 仍为 null（只由 125ms 播放 tick 的 `_updateCurrentCue` 填充，且 `idx<0` 裸 return），故重开书暂停态下 `allBookCueIdx == -1`；歌词窗 `LyricsCueWindow.select` 把 -1 clamp 成 0 = 跳回第一句，播放首个 tick 后才跳到正确行。播放器**位置**已正确恢复到 `savedMs`，`cueAtCurrentPositionInBook()` 立即可算出正确 cue（悬浮字幕 `displayCueForFloatingLyric` 早已用同款位置重算法回避这坑）。修复：新增位置驱动的 `allBookCueIdxAtPosition`（live cue 优先，null 时按播放器当前位置重算），歌词入场索引与窗口选择改用它。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/lyrics_restore_position_test.dart`：用 fake just_audio 平台以保存位置 `positionMs` load（暂停态、无播放 tick），断言 `allBookCueIdx == -1`（bug 前置条件：`_currentCue` 未填充）而 `allBookCueIdxAtPosition` 返回该位置对应 cue 的正确 allBook 索引。
- **备注**：与 in-flight PR#205（BUG-870/871 触控板滚动）避号，改用 872。
