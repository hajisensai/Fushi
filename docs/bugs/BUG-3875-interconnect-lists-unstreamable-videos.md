## BUG-3875 · interconnect-lists-unstreamable-videos
- **报告**：2026-10-28（应用内反馈 `_xEjClqXTQ`，Android OnePlus：「无法加载该视频 网飞的」，截图《The Wild Robot》「视频加载失败 / 无法加载该视频。」）
- **真实性**：✅ 真 bug。日志连续 10 条 `VideoFushi.remoteEpisode` `SyncBackendError: Not found: GET /api/library/videos/video/stream/3944feb5541d/streamurl`：手机在电脑的互联媒体库里点开一本 Netflix 网页视频书。host 清单 `listVideos`（`packages/fushi_engine/lib/sync/local_library_host_service/videos.part.dart`）只滤掉了在线视频源与媒体服务器条目，网络流书（Netflix / YouTube 页、直链、rtsp）与 `.strm` 照常下发；而 `/streamurl` 靠 `resolveVideoFile` 找媒体文件，这类行恒 null → 404，对端只能显示泛化的「无法加载该视频」。
- **[x] ① 已修复** — `listVideos` 改按「host 有没有媒体字节可给」过滤：`isNetworkOnlyVideoPath`（含在线源 / 媒体服务器 / SFTP / http(s) / rtsp…）与 `isStrmPath` 一律不下发，与在线源 / 媒体服务器既有口径一致；光盘标题走盘共享，照常下发。
- **[x] ② 已加自动化测试** — `fushi/test/sync/fushi_library_host_service_video_test.dart`「网络流书（Netflix 页 / 直链 / 频道）与 .strm 不下发给对端」；原「在线视频源不下发」用例同步改口径，删去已失效的「.strm 文本大小」用例（那类行不再出现在清单里）。
- **备注**：电脑端更新后手机刷新互联库，这类条目就不再出现。Netflix 本身只能在 Windows 的网页播放器里播，手机上本来就放不了。
