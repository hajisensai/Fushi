## BUG-4912 · 视频查词浮层收藏星标每查一词全量读库解析，与字幕条星标各存一份
- **报告**：2026-11-20（来源：路线图 #3722 c51 的 video-25，复核「部分成立」，只做复核认可的那一半）
- **真实性**：✅ 真问题。根因（基准 `origin/develop@7745effa2e`，`fushi/lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart`）：
  - `:132` 每次查词都 `unawaited(_refreshVideoSentenceFavorite())`，`:171-187` 经 `_matchingVideoFavorites`（`:525` `getAll()`）把全部收藏句 JSON 读出、解析、排序，只为判一个星标；代价随收藏总量增长。
  - 浮层星标读库、字幕条 / 跳转列表星标读内存镜像 `_favoritedVideoSentences`，同一个状态两份。页内两处互相维护，但镜像首次填充（`_refreshFavoritedCueCache`，`:477`）不补刷浮层星标。
  - `:264` 浮层收藏写镜像时用未 trim 的 `sentence` 作键，而镜像填充与 `_isCueFavorited` 都用 trim 过的文本：带首尾空白的查词句收藏后，字幕条星标要等下一次全量重填才亮。
  - 复核否掉的那一半（「互不通知」）不做：页内两份本来互相维护；页外来源（收藏夹页、同步合并）改动后镜像不刷新是仍在的局限，见备注。
- **[x] ① 已修复** — `video_fushi_page.dart` 新增纯函数 `videoSentenceFavoritedInMirror`（与取消收藏时的库内匹配同口径），浮层星标（`_refreshVideoSentenceFavorite` 改同步）与 `_isCueFavorited` 共用；`_refreshFavoritedCueCache` 填完同一次 rebuild 里补刷浮层星标；镜像键一律 trim；本页增删收藏时递增 `_favoriteMirrorRevision`，全量重填读库期间有过本页写入则丢掉旧快照重读（否则刚收藏的句子会被旧快照盖掉）。取消收藏时那一次全量读（按 id 删库）保留。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_lookup_favorite_mirror_test.dart`：判据纯函数（cue 键、旧 text-only 兼容、远端多集按集区分）+ 经真实页面 State 与真实 `FavoriteSentenceRepository`：镜像已填时星标同步就是实心；查词早于镜像填充时填完补刷；带空白的查词句收藏后字幕条星标立刻认得、取消后库里删干净。变异（去掉补刷 + 键不 trim）下两条红（实测）；旧实现的异步库读下第一条按构造必红。
- **备注**：未做设备复测（本轮所有者定不做）。页外来源（收藏夹页删除、同步合并）改动后镜像不刷新——修前浮层星标读库能看到，修后浮层与字幕条一样要等下次重填（开播 / 换集 / 远端 `favoritesChanged`）。这是路线图修法已接受的取舍；要根治需要收藏仓库提供变更通知，记为遗留。
