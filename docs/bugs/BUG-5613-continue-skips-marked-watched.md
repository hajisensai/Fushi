## BUG-5613 · 「继续看」落在已标看完的集上（锚点看完只取 +1，不跳过之后已看的集）
- **报告**：2026-11-28（用户：Jellyfin 入库的剧把第 1～9 集标成已看，详情页仍是「继续看 第3集」，视频首页仍是「正在看 第2集」）
- **真实性**：✅ 真 bug。用户库里该剧第 1、2 集有播放时刻（Jellyfin 回灌，11-22 / 11-23），第 3～9 集 `completedAt` 是当天的标记时刻、`lastPlayedAt` 为空（标记已看按设计不写播放时刻：`setVideoBooksWatched` 只动看完标记与断点）。各处「继续」锚点 = 最近播放的第 2 集（已看完），然后一律取 `anchor + 1` = 第 3 集，不看第 3 集已打勾：
  - 详情大卡 / 合集卡进度行：`fushi/lib/src/media/collections/collection_continue.dart:114` `continueMemberIndex`（旧实现 `anchor + 1`）；书籍合集（`book_continue.dart`）、仪表盘远端合并（`dashboard_remote_merge.dart`）同经它。
  - 视频首页「继续观看」：`fushi/lib/src/media/video/video_home_layout.dart:332` `continueWatchingSeriesIndex`（旧实现 `current + 1`），侧栏悬停速览同经 `selectVideoContinueCandidates`。
  - 「已更新未看」的起点：`video_home_layout.dart:313` `nextEpisodeAfterLatestPlayed`（调用方已自行跳过已看，结果未受影响，但判据同改以免分叉）。
  Jellyfin 自己的 Next-Up 是「最后播放那集之后第一集**未播放**的」，Fushi 媒体服务器详情页（`media_server_detail_view.dart` `_continueIndex`）也已按「第一集未播放」取，只有本地合集推导漏了这一步。
- **[x] ① 修复** — 新增唯一推进判据 `firstUnfinishedMemberFrom`（`collection_continue.dart`）：锚点看完后取它之后第一个非 `isFinished` 的成员（已标看完、或进度到片尾区的集跳过；已打勾但重看到一半的不跳过，BUG-3491 口径不变）。`continueMemberIndex` 之后全看完时落最后一个成员；首页两行之后全看完时返回 null（不占行）。锚点判据（最近播放）不变：正在看第 5 集时补标第 1～3 集已看，仍停第 5 集——所以没有选「标记已看时写 `lastPlayedAt`」这条路，那样补标旧集会把锚点拉回去。
- **[x] ② 自动化测试** — `fushi/test/media/collection_continue_test.dart`「锚点看完后跳过已标看完的集 (BUG-5613)」组（用户数据形状、片尾区 / 重看、补标旧集不动锚点、之后全看完、边界）；`fushi/test/media/video/video_home_layout_test.dart` 首页「继续观看」「下一集」与详情大卡三处同落第 10 集、之后全看完不占行。
- **备注**：纯推导函数修复，不改数据；用户库里现有数据刷新页面即生效。
