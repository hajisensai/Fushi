## BUG-3783 · 有声书「上一句」在长句中后段只回到本句开头
- **报告**：2026-10-25（用户：「一句比较长的字幕读到中后段时按上一句只会回到这句开头，不会真正跳转到当前句的上一句」，附录屏：英文有声书播放中连按底栏「上一句」，高亮与底栏标题始终停在同一句）
- **真实性**：✅ 真问题（行为回归，非实现失误）。`88e8b6f5f7`（PR #2466，10-23 反馈批次）给 `AudiobookPlayerController._prevCueIndex`（`fushi/lib/src/media/audiobook/audiobook_controller.dart`）加了「已播进当前句超过 `prevCueRestartThresholdMs` = 1500 ms 先回当前句开头」的音乐播放器语义。播放中回到句首后音频继续走，两次按键间隔超过 1.5 秒就又被判「听进本句」，于是永远回句首、到不了上一句；句子越长越明显。所有「上一句」入口（底栏、迷你播放器、歌词模式、快捷键、音量键、媒体通知）都走这一处。
- **[x] ① 已修复** — 用户拍板改回严格语义：「上一句」恒跳当前 cue 的前一条（对齐 Sasayaki `prevCue()`），撤掉 `prevCueRestartThresholdMs` 分支。重播当前句已有独立入口 `replayCurrentCue`（歌词模式「重播本句」按钮 / 快捷键），不再由「上一句」兼任。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/audiobook_controller_seek_test.dart`：删掉钉「过阈值回本句」的 5 条，新增「长句中后段 / 句后静音里按上一句都去前一条」「首句中后段按上一句是章边界（null）」三条。
- **备注**：反馈 XUBiOO8VML / lPEaXxZNhn 要的「方便重播本句」改由 `replayCurrentCue` 满足。真机未复测（用户录屏里的书不在本机数据根），证据是纯决策函数单测。
