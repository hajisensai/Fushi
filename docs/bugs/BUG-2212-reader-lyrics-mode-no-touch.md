## BUG-2212 · 歌词模式听书播放态不喂空闲门，听一小时只计 10 分钟
- **报告**：2026-09-06（用户：）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart:554-598`（修复前）`_onCueChanged` 歌词模式分支只 `__lyricsSetCue` 高亮 + `_syncPositionFromCurrentCue`，从不 `touch()`；空闲门唯一的喂点是 `navigation.part.dart:361` `_refreshProgressFromScroll`，而歌词页没有滚动回传。听一小时歌词模式只计到空闲门 10 分钟。`study_clock.dart:27/294` 注释里「查词喂门」也与实现不符（查词走词典弹窗，不经 `touch()`）。
- **[x] ① 已修复** — 提交：`003149107a`；`_onCueChanged` 开头 `if (controller.isPlaying) _studyClock?.touch();`——播放态每次 cue 推进喂一次门（非歌词模式跟随顺带经过，与滚动回传 touch 幂等；暂停态被动高亮不喂）。不改字数口径。`study_clock.dart` 两处注释与 `docs/agent/statistics.md` 写入面一行改准确：查词不喂门，听书播放态 cue 推进喂门。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_study_clock_gate_guard_static_test.dart`「BUG-2212：_onCueChanged 在歌词模式分支之前按 isPlaying touch」。
- **备注**：
