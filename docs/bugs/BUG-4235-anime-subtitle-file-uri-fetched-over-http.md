## BUG-4235 · 在线视频源本地 file:// 字幕被当 HTTP 去取
- **报告**：2026-11-07（崩溃报告 `#o3voUUPYKz` 日志附带；ZTE A103ZT，3.3.0）
- **真实性**：✅ 真 bug。日志三次 `VideoFushi.remoteSubtitle`：`Invalid argument(s): No host specified in URI file:///data/user/0/app.fushi.reader/cache/subs751647215311001519.srt`，栈 `AnimeSourceVideoClient.getRemoteVideoSubtitle`（`fushi/lib/src/media/video/online/anime_source_video_client.dart:478`）← `_VideoSubtitle._applyRemoteEmbeddedSubtitle`（`subtitle.part.dart`）。
  - 根因：Aniyomi 扩展可以把字幕先解出 / 转换写进宿主 `cacheDir`，`Video.subtitleTracks[].url` 回的是 `file://` 本机路径；`getRemoteVideoSubtitle` 不分 scheme，一律 `_httpClient.get(subtitleUri)`，`dart:io` HttpClient 对无 host 的 URI 直接抛 ArgumentError，字幕挂不上。
- **[x] ① 已修复** — `getRemoteVideoSubtitle` 对 `file:` scheme 直接读本机文件写到 `dest`，不经 HTTP；网络轨照旧（同站带流的头）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/online/anime_source_video_client_test.dart`「扩展把字幕落在本机（file:// 链接）→ 直接拷文件，不走 HTTP」：HTTP 客户端零请求、`dest` 内容与本机字幕一致、进度回 1.0。
- **备注**：同一份日志里 Mihon `filtersAnime` 的 `IllegalFormatConversionException: d != java.lang.String` 是扩展自身的格式化 bug（扩展代码里 `%d` 配了字符串），不在宿主侧。未在真机复测（需要会回 `file://` 字幕的扩展）。
