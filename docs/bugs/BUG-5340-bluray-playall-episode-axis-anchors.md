## BUG-5340 · 原盘「全部播放」按集换库身份后，时间锚点仍在整条播放列表时间轴上
- **报告**：2026-11-23（合并审查 PR #4278 / BUG-5312 时发现；开发者本人）
- **真实性**：✅ 真 bug（沿代码路径确认，未上真盘）。PR #4278 让菜单「全部播放」（被扫描切成集的 `00001.mpls`）的库身份跟着播放头在各集之间换（`fushi/lib/src/pages/implementations/video_fushi/disc_menu.part.dart` `_discMenuEpisodeProgress`、`VideoPlayerController.retargetDiscTitleBook`），但只有 `_persistPosition`（`video_fushi_page.dart` 的 `_persistPosition` / `_persistKnownDuration`）把位置换算成集内时间轴；其余按 `_activeBookUid`（= 当前集）落库或判定、却直接读播放器时间（整条播放列表时间轴）的消费者都没换算：
  - 观看统计 `VideoWatchTracker`（`fushi/lib/src/media/video/video_watch_tracker.dart` `_sample` / `stop` → `_checkCompletionAt`）：完成判定 = 整条播放列表的 `positionMs / durationMs ≥ 0.9`，第 1、2 集永远不报「看完」（媒体追踪不推进），末集刚过一大半就报；覆盖并集按集键（`videoWatchCoverageEpisodePrefKey(uid, 0)`）存却是播放列表时间，日后直接打开这一集时字幕计字去重对不上。
  - 收藏句（`video_fushi/lookup_favorite.part.dart` 写 `bookKey: _activeBookUid, normCharOffset: cue.startMs`）、制卡历史 / 回跳锚点（`video_fushi/lookup_mining.part.dart` 的 `miningPositionMs` / `cue.startMs`）：键是这一集、时间是播放列表时间，从收藏 / 历史回跳打开这一集（分集路径自己的时间轴从 0 开始）会落到错位置或越过片尾。
  - 跨集换身份时（`_discMenuEpisodeProgress`）没有重载收藏句缓存（`_refreshFavoritedCueCache`），新一集的已收藏句不显示。
- **[ ] ① 未修复** — 两条路，需拍板：(a) 播放页加一层「原盘分集时间轴」换算：当前集起点偏移统一作用于所有按集身份落库 / 判定的时间（tracker 用包一层的 `VideoPlaybackSource` 平移位置 / 时长 / 当前句，收藏、制卡、历史写入减偏移、读取加偏移），跨集时重载收藏缓存；(b) 菜单「全部播放」不按集换身份，回到一条整卷身份但不进合集选集列表（进度不同步到各集）。PR #4278 选的是 (a) 的一部分。
- **[ ] ② 未加自动化测试** — 修法定下后补：分集绑定下完成判定按集长、收藏 / 制卡锚点为集内时间。
- **备注**：真盘复测已按维护者意见取消。
