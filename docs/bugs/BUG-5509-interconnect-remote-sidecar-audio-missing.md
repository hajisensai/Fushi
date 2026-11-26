## BUG-5509 · 互联远端播放 host 的本地视频拿不到外挂音轨
- **报告**：2026-11-25（开发者应用内反馈 M9OEh1PeYH：「通过互联播放本机视频时仍然拿不到外挂音轨……这类问题要根本性修复，不能总缺东西」）
- **真实性**：✅ 真 bug（BUG-5475 备注里登记的缺口）。本机播放器起播时按 `listSidecarAudioTracks` 挂视频旁的外挂音轨，但 host 侧 `packages/fushi_engine/lib/sync/fushi_sync_server/video.part.dart` `/streamurl`（修前 `:207-257`）只下发 `sidecarSubtitles`，既没有音轨发现结果，也没有 client 能取的音轨流路由；client 的 `RemoteVideoStreamUrls.fromJson` 早就认 `externalAudioTracks`、播放页也把它交给 `audio-add … auto`，只是 host 从来不发。同目录 / `Audio 5.1/` 子目录里的配音、评论音轨在远端音轨面板里永远选不到。
- **[x] ① 已修复** — 一次补齐「发现 → 下发 → 取流」三段，发现判据只有一份：
  - 引擎 `video_sidecar.dart` 新增 `discoverSidecarAudioTrackFiles`（目录 IO + `listSidecarAudioTracks` + `sidecarAudioLabel`，从 app 侧 `video_local_sidecar_audio.dart` 收进来），本机播放器与 host 共用，两边认出的音轨不会不一样；app 侧只剩形状转换。
  - 新可选 host 能力 `VideoSidecarAudioListHost.listVideoSidecarAudioTracks`（与 `VideoSidecarSubtitleListHost` 同范式），`LocalLibraryHostService` 实现：按 `_resolveEpisodeVideoPath` 取这一集，网络流 / `.strm` / 光盘标题不列。
  - `/streamurl` 下发 `externalAudioTracks[]`（label / language + 同一张流 token 的 `.../sidecaraudio?token=&n=` URL）；新路由 `sidecaraudio` 与 `/stream` 同待遇（豁免 Basic、校验 token 绑定视频与集、签发凭据吊销即作废、`n` 只能落在 host 此刻枚举出的音轨表里、Range + ETag），流票 `streamrelease` 连带作废；能力位 `videoSidecarAudio`。老 host 不发列表，client 照旧。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/sync/fushi_sync_server_sidecar_audio_test.dart`（真 server + 真 host：host 列表与本机判据一致；`/streamurl` 下发两条音轨、URL 带同一张流 token；不带 Basic 裸 GET 拿到各自字节、Range 206；缺 token 401 / 错 token 403 / 越界与穿越 404 / 释放流票后 403；能力位；老 host 不发）。app 侧 `fushi/test/media/video/video_local_sidecar_audio_test.dart` 照旧覆盖本机发现。
- **备注**：真机远端播放未复测（本轮无两台设备）；client 挂音轨走的是在线源外挂音轨同一条已验证路径（`buildExternalAudioAddCommands` + `nativePlaybackUri`，https host 同样过本地中继）。
