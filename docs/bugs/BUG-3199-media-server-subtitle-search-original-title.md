## BUG-3199 · 媒体服务器在线观看搜字幕用的是中文显示标题
- **报告**：反馈 fYLF2VFB6C（Emby 在线观看时番剧标题都是中文，搜字幕得自己输入原始标题）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` 的 `_buildJimakuSeed` 只从本地 DB 的刮削作品取原名与外部 ID；远端视频没有 DB 作品行，种子只剩显示标题（服务器的中文译名）。服务器条目明明带 `OriginalTitle` 与 `ProviderIds`。
- **[x] ① 已修复** — 本 PR：新增可选能力 `RemoteVideoTitleIdentityFetch`（`remote_video_client.dart`），Jellyfin/Emby 实现：`/Users/{uid}/Items/{id}?Fields=OriginalTitle,ProviderIds`，集跳到所属剧再取；`ProviderIds` 键转小写进种子——AniList ID 给 Jimaku 直搜、TMDB ID 给 OpenSubtitles，原名排第一预填搜索框。字幕搜索面板新增标题备选 chip，一键切回中文标题并重搜。身份取不到时照旧按显示名搜。
- **[x] ② 已加自动化测试** — `fushi/test/sync/jellyfin_title_identity_test.dart`（协议层 + 种子）、`fushi/test/pages/subtitle_search_query_alternatives_test.dart`（预填原名、chip 切换）。
- **备注**：种子目前只消费 AniList / TMDB 两种 ID（现有字幕源按 ID 搜只认这两种）；AniDB / IMDB 已取到但没有字幕源消费。
