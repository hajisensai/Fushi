## BUG-4908 · 续播恢复音轨用 200 ms × 20 次轮询，音轨超过 4 秒才出现时静默放弃，用户选过的音轨丢失
- **报告**：2026-11-20（路线图 #3722 c32 video-12，代码复核；非用户反馈）
- **真实性**：✅ 部分成立。根因（基准 `7745effa2e`）：
  - `fushi/lib/src/pages/implementations/video_fushi/audio_track.part.dart:36-45`（修前）：`_restoreAudioTrack` 每 200 ms 查一次 `controller.audioTracks`，最多 20 次，第 4 秒还没找到目标 id 就直接返回，不留日志、不提示。
  - 复核收窄：「真有超过 4 秒才出音轨的片源（大 REMUX、慢盘、慢网络流）」是推断，没有找到实测证据；但这个上限本身是时长猜测，不是终止条件——真正该停的时刻是换片、卸载、用户自己选了轨，这三样轮询里只覆盖了前两样（用户在 4 秒内手动选轨后，轮询仍可能把恢复的轨盖上去）。
- **[x] ① 已修复** — 控制器新增事件驱动的 `VideoPlayerController.waitForAudioTrack(id)`：订阅 `player.stream.tracks`、每次复读 `state.tracks.audio`，目标轨出现即返回；换片（load 令牌变 / Player 被换掉）、Player 销毁（流结束）、等待期间有显式选轨（`_audioSelectionSeq` 变）返回 null。页面 `_restoreAudioTrack` 改为等它，删掉轮询与固定延时。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_player_controller_handles_test.dart`「续播恢复音轨的等待（video-12）」：轨列表变化 30 次后目标轨才出现也能等到；已在列表立即返回；换片、用户先选了轨、Player 销毁各自返回 null。`fushi/test/pages/video_menu_guard_test.dart` 的音轨守卫改钉新契约（走 `waitForAudioTrack`、不再轮询 / 固定延时）。
- **备注**：
  - 真机未验：慢盘 / 大 REMUX 上选非默认音轨后退出重进，看音轨是否恢复。
  - 等待中的订阅最长活到下一次轨列表变化或 Player 销毁；换集复用同一 Player 且新片轨列表与上一集完全相同（media_kit 的 `distinct` 不发事件）时，那一份订阅会挂到下一次轨变化 / 销毁为止，期间不会误切（每次醒来先校验 load 令牌）。
