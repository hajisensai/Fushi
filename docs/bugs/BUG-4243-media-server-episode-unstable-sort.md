## BUG-4243 · 媒体服务器剧集无集号时 List.sort 不稳定，超过 32 集顺序被打乱
- **报告**：2026-11-09（用户：应用内反馈 VF5D4O_Tyx，iPad / Jellyfin：E13 排第一、E01 跑到第 13 位）
- **真实性**：✅ 真 bug。该 Jellyfin 剧集条目没有 `IndexNumber`，集卡编号回落 `episodeNumber ?? index + 1`（`fushi/lib/src/pages/implementations/media_server/media_server_detail_view.dart:1075`），所以显示的「E13」其实就是列表位置。列表在客户端被重排：`JellyfinVideoClient.listEpisodes` / `listSeasons`（`fushi/lib/src/sync/jellyfin_video_client.dart:2905`、`:2948`）用 `List.sort(_bySeasonThenEpisode)`，比较器（`:2958`）对缺集号的条目一律给同一个哨兵值 → 全返回 0。Dart 的 `List.sort` 在 >32 个元素时走双轴快排、**不稳定**，注释里写的「保持稳定」并不成立：整季 37 集全相等，被打成 E13 E02…的乱序。`PlexVideoClient`（`fushi/lib/src/sync/plex_video_client.dart:431`、`:449`）同一写法同一问题。
- **[x] ① 已修复** — 两个客户端的季 / 集排序改用 `package:collection` 的稳定 `mergeSort`，比较器不变；同号 / 缺号条目保持服务器原序。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/media_server/jellyfin_media_server_test.dart`（37 集全缺 `IndexNumber` 保原序；有号的排前、34 个缺号条目排后且保原序）、`fushi/test/sync/plex_video_client_test.dart`（37 集全缺 `index` 保原序）。
- **备注**：缺集号时集卡显示 `index + 1` 当集号、以及 `mediaServerCollectionOf` 的 `sortIndex` 把缺号当 0，属展示 / 产品口径，未改。未在真机 Jellyfin 上复测。
