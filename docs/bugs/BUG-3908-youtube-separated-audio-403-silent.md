## BUG-3908 · YouTube 分离音频流 403 后有画面无声，无回退无提示
- **报告**：2026-10-31（用户：应用内反馈 s3sOy3sD1J，Android 华为 DBY-W09，yt:e8IYs7gyJsQ；音轨列表只有 auto / no）
- **真实性**：✅ 真 bug（失败处理缺失；403 本身是 YouTube 侧限窗，不可控）。日志：`youtube_relay upstream 403 on first chunk bytes=0-2097151` → `Can not open external file http://127.0.0.1:…/yt/<token>`。外挂音轨在 `fushi/lib/src/media/video/video_player_controller.dart` 的 `load()` 里 `setAudioTrack(AudioTrack.uri(...))` 挂上，mpv 打不开就丢轨、画面照放；错误经 `player.stream.error` 只到 `video_fushi_page.dart` `_handlePlaybackError`（只记日志、不判决），没有任何回退或提示。
- **[x] ① 已修复** — 控制器按本次 load 外挂音轨的实际 URI 精确识别 `Can not open external file <uri>`（`isExternalAudioOpenFailure`），每次 load 至多上报一次 `onExternalAudioTrackFailed` 并记 `externalAudioTrackFailed`；页面复用解析器已取好的 muxed 流（制卡低清流 `miningVideoUrl` 且 `miningVideoHasAudio`，itag 18 不受无 PO token 限窗，`separatedAudioFallbackStreamUrl`）原位换流重载（保位置与字幕），OSD 说明已换低画质兼容流；没有 muxed 时 OSD 明确提示「音频流加载失败，当前没有声音」。载入在途时只记账，起播 / 切档收尾后再处理，避免 `_applyLoad` 重入。不重试同一条流。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/separated_audio_fallback_test.dart`（判据纯函数、回退流选择纯函数、页面接线源码守卫；真 libmpv 宿主上没有，页面层只能源码钉）。
- **备注**：未在 Android 真机 + 被限窗网络出口复现验证；muxed 流对该出口是否同样可用以解析器注释（BUG-2526 实测）为据，未独立复测。
