## BUG-2990 · MD3 迷你播放条缺失跟随音频入口
- **报告**：2026-10-06（样式改版审查）
- **真实性**：真实入口丢失，MD3 迷你播放器样式提交 `35aedcd3ae2` 引入。
- **根因**：`fushi/lib/src/media/audiobook/audiobook_play_bar.dart:631` 附近的 Expressive 播放条仅构建封面、信息及三键播放组，遗漏原跟随音频按钮；`fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:3113` 原有去重仍过滤底栏配置里的跟随项，用户主动添加也不显示。
- **[x] ① 已实现修复** — MD3 迷你条恢复已有 `AudiobookFollowAudioButton`，复用 controller 与持久化回调，不改变用户布局去重策略。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/media/audiobook/audiobook_mini_player_follow_test.dart`，320/720px 下按钮可达、ActivateIntent 真正翻转跟随并调用 persist。
- **验证结果**：见 [审查报告 HBK-AUDIT-012 及最终验证记录](../reviews/2026-10-06-project-review.md)。
- **备注**：未完成真实听书、正文同步及窄屏设备验收，不宣称实机通过。
