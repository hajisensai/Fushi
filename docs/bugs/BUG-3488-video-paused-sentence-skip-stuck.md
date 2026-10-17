## BUG-3488 · 视频暂停时上/下一句跳不动，字幕约 2 秒后弹回原句
- **报告**：2026-10-17（用户：应用内反馈 kGkpsMzkpZ / lij_Ydf-ME，Android vivo V2339FA，2.10.0-debug.19358，违国日记 13 集 8:20，Aniyomi 在线源）
- **真实性**：✅ 真 bug（沿代码路径定位；录屏里按「下一句」后字幕先换成下一句、约 2 秒后弹回原句、画面不变，与下述机制吻合）。
  - 根因 `fushi/lib/src/media/video/video_player_controller.dart` `_applySeekTargetSnap`（修前 4119-4121 行）：[skipToCue] 置跳转目标快照 `_seekTargetCueIndex` 并充 16 拍（2 秒）在途宽限；tick 读到的位置仍是跳转前旧位置时，每拍无条件扣一格宽限。**暂停态**下 media_kit 的 position 不推进，在线流 seek 要先拉目标分片、长 GOP 要解到目标帧，回报常超过 2 秒——宽限耗尽即清快照，字幕按旧位置弹回原句。
  - 连锁：再按「下一句」时 `nextCueIndexFor` 的锚点（`_seekTargetCueIndex`）已被清，按旧位置 floor 又算出同一个目标句，于是「这句跳不动」；只有在 2 秒内连按（锚点还在）才前进，即「狂点才过去」。mpv 实际已 seek 到下一句，所以按播放从下一句开始。
  - 「只有这句」：取决于该句 seek 目标是否落在已缓冲区间外 / 长 GOP 中段（回报慢于 2 秒），与句长无直接关系。普通 seek 的同类在途保护 `_reconcileSeekInFlightPosition` 早已是「暂停态无限期保持目标」，只有 cue 跳转这条漏了。
- **[x] ① 已修复** — `_applySeekTargetSnap` 仅在播放态消耗在途宽限，暂停态保持跳转目标直到 position 落进目标句或用户别的 seek / 播放后有界放弃（与普通 seek 在途调和同一语义）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_player_controller_test.dart`「暂停态 seek 回报迟迟不到：快照不过期，连按下一句逐句前进」；原「在途 seek 宽限有界」用例改为播放态下验证。
- **备注**：在线源扩展本机没有，未在真机复现原始路径；测试层用「暂停 + position 不随 seek 变化」模拟回报滞后。
