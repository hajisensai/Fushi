## BUG-4136 · 视频播完等下一集倒计时期间，自动续播路径把当前视频从头重播
- **报告**：2026-11-01（反馈 ji9GSMzD4E，Windows，3.2.0-debug.22820：「未开单视频循环，视频播完、等待下一视频播放的 5s 内，会自动重播当前视频」）
- **真实性**：✅ 机制已沿代码坐实；用户这次具体是哪条自动续播路径触发的，日志没有证据（见备注）。
  - media_kit 1.2.6 `Player.play()`（`lib/src/player/native/player/real.dart:382`）在 `state.completed` 为真时先 `seek(0)` 再取消暂停，「播完再按播放」就是重看。网页后端（`web_video_platform_player.dart`）同理：HTML `<video>` 在 ended 态调 `play()` 也从头播。
  - 视频页播完只起倒计时（`video_fushi/episode.part.dart` `_handlePlaybackCompleted` → `_startAutoAdvanceCountdown`），播放器停在 completed 态 5 秒。
  - 「非用户发起的续播」点此前都直调 `VideoPlayerController.play()`，和用户显式播放共用一条路，没有一个检查媒体是否已播完：
    1. 查词浮层整栈关闭（含悬停离开自动关）`video_fushi_page.dart` `_popNestedPopupAt`（`_pausedForLookup`）
    2. 选词光标会话结束 `video_fushi/subtitle_caret.part.dart` `_finishSubtitleCaretSession`（`_pausedForLookup`）
    3. 回前台续播 `video_fushi_page.dart` `_resumeAfterBackgroundIfNeeded`（`_pausedForBackground`）
    4. 编辑字幕对话框关闭 `video_fushi/subtitle_text_edit.part.dart` `_editCueText`（`wasPlaying`）
  - 在 completed / 倒计时期间能触发的：1、2 两条最直接——查词时的暂停是 fire-and-forget（`lookup_favorite.part.dart` 的 `unawaited(controller.pause())`），片尾最后一刻起查词时「暂停没落地 EOF 先到」，`_pausedForLookup` 已置位；倒计时里关浮层 / 鼠标移开（悬停离开自动关）就把视频播回开头。另外 `_pausedForLookup` 在浮层开着时被别的方式恢复播放（遥控 / 快捷键）后不会清，播完后再关浮层同样走到这里。3、4 需要暂停期间媒体推进到结尾，只有同样的竞态窗口。
  - 手机遥控查词的续播（`video_remote_host.dart` `_resume`）已经按 `remoteControlRevision` 判「桌面有没有人动过」，查词开始时已播完则 `wasPlaying` 为假、不会续播；只剩同一个「暂停没落地 EOF 先到」的窄竞态，未改（改它要动 4 个 binding 实现的 `command` 协议）。
  - 用户显式播放（播放键 / 空格 / 遥控 play / 「从这里继续观看」/ 波形试听）在播完处照常重看，不是 bug。
- **[x] ① 已修复** — `VideoPlayerController` 把两种语义分开：`play()` 仍是用户显式播放；新增 `resumePlayback()`（自动续播）与 `isAtNaturalEnd`（`player.state.completed`，seek / 换片即清），媒体停在自然播完处（倒计时期间恒为真）时自动续播不执行。上面 1–4 四个自动续播点全部改走 `resumePlayback()`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_resume_playback_natural_end_test.dart`：真 `Player`（网页后端，completed 由页面上报推导）上验播完处自动续播不下发播放、片中照常续播、播完后 seek 回片中可续、显式 `play()` 在播完处照常下发；并对四个自动续播点做接线守卫（必须调 `resumePlayback()`、不得直调 `play()`）。同步更新 `video_lookup_resume_static_test.dart` / `video_hover_leave_resume_test.dart` 的旧字面量断言。
- **备注**：反馈附带日志只有 WGC 帧捕获生命周期、更新器与 SRS 报错，没有任何播放 / 播完 / 查词事件，没法从日志坐实用户这次是哪条路径；修复覆盖了全部自动续播点，所以不依赖这一点。未在真机复测原始失败路径（视频页依赖 libmpv，无法 headless 起）。`_pausedForLookup` 在浮层开着时被外部恢复播放后不清这一点仍在（播完以外的影响：浮层开着时用户先恢复又自己暂停，关浮层仍会被续播），没在本修复里动。
