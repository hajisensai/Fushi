## BUG-1544 · 选集卡片序号用导入顺位号而非文件名解析出的真实集数
- **报告**：2026-08-11（用户：播放器「选集」浮层里卡片标 01/02/03/04，但正在播的第 3 张卡文件名是 `Young.Ladies.Dont.Play.Fighting.Games.S01E05.…`——前面有集缺失/未导入，顺位号与真实集号错位）
- **真实性**：✅ 真 bug。根因是**两处展示层把列表下标当集号**，与文件名里写着的集号无关：
  - `fushi/lib/src/media/video/video_episode_rail.dart:217`（旧）`'${index + 1}'.padLeft(2, '0')` —— 播放器选集浮层的卡片角标；同文件 `:156` 的 Semantics label 同样用 `index + 1`。
  - `fushi/lib/src/pages/implementations/media_collection_detail_page.dart:2158`（旧）`'${index + 1}. ${_episodeDisplayTitle(episode)}'` —— 合集详情页选集区。
  只要有一集没导入（或分季 tab 下用节内下标），下标就必然与集号错位；分季后节内下标每季从 1 重数，错位更普遍。
- **[x] ① 已修复** — 新增纯函数 `parsedEpisodeNumberOf`（`fushi/lib/src/media/video/video_filename_parser.dart`，走 `parseVideoPath` 同一个解析引擎）；`VideoEpisodeEntry` 加 `episodeNumber` 字段，卡片 `_displayNumber`（`video_episode_rail.dart:158`）= 解析集号 ?? 顺位号，角标（`:229`）与无障碍 label（`:168`）共用；播放器侧在 `video_fushi/episode.part.dart:237` 按 `path`（远端无路径时按 title）解析后喂进去；详情页 `_episodeDisplayNumber`（`media_collection_detail_page.dart:458`）同口径，用在 `:2169`。解析不出集号（PV / 特典 / 远端无路径）一律回落顺位号，行为与修复前一致。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/episode_display_number_test.dart`：纯函数 4 例（`S01E05` / dash 集号 / Windows 全路径 / 解析不出→null）+ widget 2 例（缺集场景断言第 3 张卡显示 `05` 且 `03`/`04` 不出现；无集号回落顺位号）。
- **备注**：集号是文件名里写着的事实，不是列表下标的函数。刮削集号（`video_scrape_meta.episodeNumber`）暂未参与显示——它与绝对集号/分季集号口径可能不一致，需要单独定口径再接。
