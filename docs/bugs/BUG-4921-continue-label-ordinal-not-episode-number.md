## BUG-4921 · 剧集页「继续看 第N集」用列表顺位号，与真实集号不符（只导入后半季时显示第1集而非第151集）
- **报告**：2026-11-20（用户：应用内反馈 1fHQK9I4hL）
- **真实性**：✅ 真 bug。三处续播文案的 N 都是续播成员在列表里的下标 +1，而集卡序号是真实集号（BUG-1544 / BUG-2369 口径），只导入后半季 / 缺前几集时两者错位：
  - `fushi/lib/src/pages/implementations/media_collection_detail_page.dart:2182`（hero 续播行）与 `:3876`（「接着看」卡）：`collection_continue_progress(n: _continueIndex + 1)`，没走集卡用的 `_episodeDisplayNumber`（`:1096`，文件名整批解析的真实集号）。
  - `fushi/lib/src/pages/implementations/home_video_page.dart:8809`（库页合集卡进度行）：`continueMemberIndex(progresses) + 1`。
  - `fushi/lib/src/pages/implementations/media_server/media_server_detail_view.dart:712`（媒体服务器剧详情 hero）：`index + 1`，而集卡只认服务器的 `episodeNumber`（VF5D4O_Tyx：不拿列表位置冒充集号）。
- **[x] ① 已修复** — 详情页新增 `_continueEpisodeNumber`（= `_episodeDisplayNumber(续播那集, _continueIndex)`），hero 续播行与「接着看」卡同用；库页合集卡改走新共用函数 `collectionMemberEpisodeNumber`（`collection_episode_slot.dart`，与集卡同一个 `parsedEpisodeNumbersOf` 整批解析、解析不出回落顺位号）；媒体服务器续播行改用 `episode.episodeNumber`，服务器没给集号时只写「继续观看 · 集名」，不编集号。
- **[x] ② 已加自动化测试** — `fushi/test/pages/collection_detail_continue_episode_number_test.dart`（helper 单测 + 详情页 widget：151 看完 → 「继续看 第152集」、无「第2集」）；`fushi/test/pages/home_video_collection_cover_card_test.dart`「BUG-4921 续播标签写真实集号」；`fushi/test/pages/media_server/media_server_detail_view_test.dart`「BUG-4921：续播行写服务器给的真实集号」。
- **备注**：分季视图下集卡序号解析不出时回落的是**节内**顺位号，续播行回落的是全局顺位号；仅在文件名解析不出集号时才会出现差异，本次未动（集卡回落口径属 BUG-1544 既有设计）。
