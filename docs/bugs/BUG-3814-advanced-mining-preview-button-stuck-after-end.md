## BUG-3814 · 高级制卡试听播完后按钮停在「停止」，下一次点击只是停止
- **报告**：2026-10-27（用户：应用内反馈 FDN66-xurt，Windows 3.0.0+19763，视频「高级制卡」句子音频试听）
- **真实性**：✅ 真 bug（沿代码路径确认，非设备复现）。区间播放的结局对调用方不可见：
  - `fushi/lib/src/mining/advanced_mining/advanced_mining_controller.dart:417-430`（修前）`togglePreview` 起播前乐观置 `previewing = true`，只在 `section.preview` 返回 false（`:426`）或 `stopPreview` 时清零，没有任何「这段播完了」的入口；
  - `fushi/lib/src/media/video/video_player_controller.dart:6010-6015`（修前）`playRangeMs` 起播即返回 `Future<void>`，到终点由 `_maybeStopAtPlayRangeEnd`（`:4313`）静默暂停并消耗 `_oneShotHoldUntilMs`，不通知调用方；
  - 于是播完后按钮仍是「停止」，下一次点击走 `previewing == true` 分支去 `stopPreview`（停一段早已结束的播放），要再点一次才重新试听——与反馈「点两次」一致。
  - 同病：阅读器 / 有声书的高级制卡试听（`reader_fushi_page.dart` `_previewMiningSentenceAudio` → `AudiobookPlayerController.playRange`，`audiobook_controller.dart:3097` `await clip.play()` 要播完才返回、返回 true 后同样不复位）。
- **[x] ① 已修复** — 区间播放把结局交给调用方：新增 `fushi/lib/src/media/range_playback.dart`（`RangePlayback` 句柄 + `RangePlaybackEnd{reachedEnd, interrupted}`）。`VideoPlayerController.playRangeMs` 返回句柄，`_oneShotHoldUntilMs` 的所有作废点（seek / `_rawSeekMs` / `setCues` / `stopPlayRange` / 下一段 / `dispose`）与终点暂停、媒体播完统一经 `_endPlayRange` 完成句柄；`AudiobookPlayerController.playRange` 同样返回句柄，`stopClip` / `stopPlayback` / 销毁收尾。`AdvancedMiningAudioSection.preview` 契约改为 `Future<RangePlayback?>`，`AdvancedMiningController.togglePreview` 跟着句柄复位 `previewing`（代际号挡住旧一段晚到的结局；起播途中被停时补停）。不用定时器估时长。
- **[x] ② 已加自动化测试** — `fushi/test/mining/advanced_mining/advanced_mining_controller_test.dart`「试听按钮跟着那段播放的结局走」组；`fushi/test/mining/advanced_mining/advanced_mining_dialog_test.dart`「BUG-3814：试听播完按钮自动回到「试听」，再点一次就重新播」；`fushi/test/media/video/video_player_play_range_test.dart`「playRangeMs 的结果句柄」组；`fushi/test/media/audiobook/audiobook_session_test.dart`「playRange 交回句柄：被 stopClip 收掉时以 interrupted 结束」。
- **备注**：未在真机 / 真视频上复测原始路径（单测覆盖控制器与播放器状态机；mpv 真实位置回调与 just_audio 真实完成事件未实机验证）。手机遥控的 `previewAudio` 是 HTTP 一次性命令、手机端没有试听切换按钮，不受影响，只是忽略句柄。
