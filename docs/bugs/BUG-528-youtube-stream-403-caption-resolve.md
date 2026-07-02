## BUG-528 · 油管播放/制卡: 默认 client 流 URL 403 + 字幕接口空 body 炸掉整个 resolve + 防盗链 header 迟发致黑屏
- **报告**：2026-07-02（用户：TODO-1000「打开 https://youtu.be/fKMEsvCtlZA 一直黑屏加载」）
- **真实性**：✅ 真 bug（真网络+真 libmpv 复现）。三重根因：
  1. `youtube_source_resolver.dart` 用默认 `YoutubeExplode()`（内部 android/ios client）取流，其签发的 googlevideo 直链被 ffmpeg/libmpv 请求时 **403 Forbidden**（实测 itag=140/313 均 403）；`ANDROID_VR` client 签发的直链无此问题（无需签名解密、普通 UA 可拉）。
  2. 字幕：`closedCaptions.getManifest`（走 web 观看页派生的 timedtext URL）实测 **所有格式 body 都返回空**（YouTube 已对 web 端 timedtext 加 proof-of-origin 门槛），`.get(track)` 解析空 XML 抛 `XmlParserException` → **冒泡炸掉整个 `resolveYoutubeSource` → 视频根本打不开**。
  3. 防盗链 header 迟发：`video_player_controller.dart` 先 `player.open(Media(uri))` 再 `applyHttpHeaderFieldsToPlayer` 设 UA——googlevideo 对 open 时的首个请求就查 UA，libmpv 用默认 UA 请求即失败，`duration`/`position` 永远 0（**黑屏卡 loading**，正是用户报障现象）。
- **根因** `hibiki/lib/src/media/video/youtube_source_resolver.dart:83`（resolve，旧默认 client + 字幕未隔离）、`hibiki/lib/src/media/video/video_player_controller.dart:1045`（open 早于 header）。
- **[x] ① 已修复** — 提交 `<pending>`：
  - resolve 改用 `ytClients:[YoutubeApiClient.androidVr]` 取流（无 403），播放流 cap 到 ≤1080p（4K progressive 无自适应码率、网络下持续缓冲=黑屏）。
  - 字幕改从 `ANDROID_VR` player response 的 `closedCaptionTrack` 取 `fmt=srv1` URL（唯一仍可直取的字幕源），且**整段 try/catch 兜底**——字幕失败绝不再阻断播放。
  - `video_player_controller.dart` 把 header 走 `Media(uri, httpHeaders: …)` 构造参数下发（media_kit 用 `on_load` hook 在真正 open URL 前设 `http-header-fields`），赶在首个请求之前。
  - 制卡源拆分（见 [[BUG-529]]）：GIF/帧走低分辨率 `miningVideoUrl`（muxed 360p，从 4K 流抽 GIF 会超时），音频走 audio-only 流。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/video/youtube_resolver_impl_symbols_test.dart`：守卫 youtube_explode 内部符号（VideoController/WatchPage/PlayerResponse.closedCaptionTrack），升级破坏时编译期报警。
  - `hibiki/integration_test/youtube_stream_playback_itest.dart`（opt-in HIBIKI_YT_LIVE_ITEST=1）：真 libmpv 窗口播 androidVr 流，断言 position 前进 >1.5s（黑屏则恒 0）+ 制卡源接线正确。**实测通过：duration=564200ms、position 前进到 11100ms**。
  - `hibiki/test/mining/youtube_immersion_live_engine_test.dart`（opt-in）：resolve→真引擎从流源抽 GIF+音频，断言产出真媒体卡。
- **备注**：真机验证证据 `.codex-test/windows-itest/win-itest-20260702-171003-*`（播放前进）。字幕/流依赖 youtube_explode_dart 2.5.x + 反 YouTube 反爬，属外部系统契约，升级需重核（守卫测试兜底）。
