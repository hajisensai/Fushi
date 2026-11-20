## BUG-5037 · 远端起播默认字幕下载没有读超时，字幕站不回数据时页面永远停在「正在下载字幕」
- **报告**：2026-11-20（来源：路线图 #3722 c47 的 video-8 与「顺带」两处，回到代码复核成立）
- **真实性**：✅ 真 bug。远端起播时默认字幕挡在开流之前（`fushi/lib/src/pages/implementations/video_fushi_page.dart` `_downloadRemoteBackendDefaultSubtitle` → 各 client 的 `getRemoteVideoSubtitle`，阶段显示 `_VideoLoadPhase.downloadingSubtitle`），而几条下载路径都没有读超时：
  - 在线源：`fushi/lib/src/media/video/online/anime_source_video_client.dart` `getRemoteVideoSubtitle` 直接 `_httpClient.get(subtitleUri)`，响应头与正文都无上限；
  - 直链流：`fushi/lib/src/media/video/url_stream_video.dart` `getRemoteVideoSubtitle` 同样裸 `_httpClient.get`；
  - Jellyfin / Emby：`fushi/lib/src/sync/jellyfin_video_client.dart` `JellyfinApi.downloadToFile` 只给「拿到响应头」挂了 15 秒，`await for (... in res.stream)` 正文无空闲超时；
  - Plex：`packages/fushi_engine/lib/media/video/media_server/plex/plex_api.dart` `PlexApi.downloadToFile` 同上。
  第三方字幕站 / 兼容层接了连接却不回数据（或回了响应头和半截正文后停住）时，`await` 永不返回，播放页永远停在「正在下载字幕」。
- **[x] ① 已修复** — 新增 `packages/fushi_engine/lib/utils/net/deadline_get.dart` 的 `getWithDeadline`（`http.AbortableRequest`，到点先抛 `TimeoutException` 再中止底层传输，不留孤儿连接），在线源与直链流的字幕 GET 改走它，总预算 `kRemoteSubtitleFetchTimeout`（20 秒，client 构造参数可调）；Jellyfin / Plex 的 `downloadToFile` 正文流加空闲超时 `kDownloadIdleTimeout`（45 秒，与在线源整集下载 / 互联下载同口径），只加空闲、不加整体超时（所有者定）。起播的默认字幕下载不并行化（所有者定）。超时后播放页既有的 `catch` 照常起播、不挂这条字幕。分支 `pr/remote-stream-timeouts-resume`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/remote_subtitle_read_timeout_test.dart`：真实本机 HTTP 服务端分别模拟「不回响应头」与「回了响应头 + 半截正文后停住」，断言 `getWithDeadline`、直链流 `getRemoteVideoSubtitle`、Jellyfin / Plex `downloadToFile` 都在预算内抛 `TimeoutException` 且不留半截文件（修前挂住直到用例超时）；`fushi/test/media/video/online/anime_source_video_client_test.dart` 覆盖在线源 client 同一场景。
- **备注**：未在真机 / 真字幕站复测（本轮所有者定不做设备验证）。
