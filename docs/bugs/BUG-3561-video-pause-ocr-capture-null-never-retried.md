## BUG-3561 · video-pause-ocr-capture-null-never-retried
- **报告**：2026-10-19（用户追问 BUG-3560：「暂停后如果截图失败，同一帧不会再试——为什么会截图失败」，随后「修」）
- **真实性**：✅ 真 bug（代码路径确认；用户现场是否命中这条无直接证据——截帧失败以前不留任何日志）。暂停 OCR 覆盖层 `_recognize`（`fushi/lib/src/media/video/video_graphic_subtitle_ocr_overlay.dart`，旧版 `if (bytes == null || stale()) return;`）在截帧返回 null 时直接放弃；帧键（位置 + 字幕轨）此后不再变化，这一帧永远不会再识别，状态静默回空闲。media_kit 1.2.6 `Player.screenshot` 只在 mpv `screenshot-raw` 失败时返回 null（`media_kit-1.2.6/lib/src/player/native/player/real.dart:3088-3096`）；据 mpv 源码，暂停态 seek / 跳句 / 逐帧步进会先清掉当前帧，新帧显示前截帧必然失败，网络流缓冲、长 GOP 时新帧晚于 250ms 防抖。另：网页播放后端 `WebVideoPlatformPlayer.screenshot` 恒返回 null（`web_video_platform_player.dart:366`），覆盖层照样挂、照样截。
- **[x] ① 已修复** — 截帧无图按 250ms / 500ms / 1s / 2s 退避重截同一帧（挂在 `_settle` 上，帧一变由 `_reset` 一并作废），用完记一条错误进 error_log；网页后端在 `_currentKey` 直接不识别。重截是外部时序兼容层：media_kit 1.2.6 不暴露 `playback-restart`、`seeking` 观测会合并翻转，拿不到可靠的「新帧已显示」信号；清理条件写在 `kGraphicSubtitleOcrCaptureRetryDelays` 注释。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_graphic_subtitle_ocr_overlay_test.dart` 组「BUG-3561」：前两次无图后识别成功、一直无图时重截有上限且记一条错误、重截途中继续播放即作废、网页后端不截帧。
- **备注**：未在真实 libmpv 上复现「seek 后截帧失败」的时序（widget 测试注入截帧）。
