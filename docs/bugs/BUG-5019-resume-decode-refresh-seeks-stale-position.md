## BUG-5019 · 回前台重建解码链用可能陈旧的缓存位置原地 seek，后台期间 Dart 侧停摆时会把播放头往回拉
- **报告**：2026-11-20（路线图 #3722 c32 video-36d，代码复核；非用户反馈）
- **真实性**：✅ 真 bug（读代码确证，原注释自己写明了这条边界；未在真机量后台停摆时长）。根因（基准 `7745effa2e`）：
  - `fushi/lib/src/media/video/video_player_controller.dart:1678-1682`（修前）：`refreshDecodeAfterResume` 执行 `player.seek(player.state.position)`。`state.position` 是 mpv `time-pos` 事件最后一次被 Dart 事件循环消费到的值；视频页真后台不暂停播放，若后台期间系统冻结 / 不调度 Dart 而 mpv 仍在推进，这个值是旧的，seek 会把播放头往回拉，偏差 = 停摆时长。BUG-1863 把这条路径从「surface 重建时」扩到「每次真后台返回」，暴露面随之变大。
- **[x] ① 已修复** — seek 前经 `_getMpvProperty('time-pos')` 现读 libmpv 播放位置（`_livePlaybackPosition`），读取期间换片 / 销毁就放弃；读不到（非 libmpv 后端 / 尚无位置 / 非法值）退回缓存位置。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_player_controller_handles_test.dart`「回前台重建解码链（video-36d）」：缓存位置 10 s、`time-pos` 42.5 s 时 seek 目标是 42.5 s（修前是 10 s，红）；读不到 `time-pos` 时退回缓存位置。`fushi/test/pages/video_resume_decode_refresh_guard_test.dart` 原先钉着 `player.seek(player.state.position)` 字面，改钉「seek 到现读位置」。
- **备注**：
  - 真机未验：Android 上播放中切到后台停留一段时间（系统冻结进程），回前台看播放头是否回跳。
