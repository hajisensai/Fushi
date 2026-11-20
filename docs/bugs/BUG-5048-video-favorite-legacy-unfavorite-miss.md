## BUG-5048 · 视频旧 text-only 收藏带集下标时星标亮着却取消不掉
- **报告**：2026-11-20（来源：路线图 #3722 c51 遗留）
- **真实性**：✅ 真 bug。镜像键 `videoFavoriteCacheKey`（`fushi/lib/src/pages/implementations/video_fushi_page.dart`）在 `normCharOffset` 为空时一律算旧 text-only 键（不看 `sectionIndex`），星标据此亮；取消收藏时的库内匹配 `_matchingVideoFavorites`（`lookup_favorite.part.dart`）在带 cue 的分支却要求 `normCharOffset == null && sectionIndex == null`，`normCharOffset` 为空但 `sectionIndex` 非空的旧条目匹配不上——点星标删不到，下一次重填星标又亮。两处各写一份判据是根因。
- **[x] ① 已修复** — 新增 `videoFavoriteLookupKeys`（一句字幕认哪些键）作为唯一判据：镜像查询 `videoSentenceFavoritedInMirror` 与库内匹配 `videoFavoriteMatchesSentence`（条目的镜像键落在这组键里）都从它取，`_matchingVideoFavorites` 改用后者。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_lookup_favorite_mirror_test.dart`：纯函数组「镜像判据与库内匹配同一组键」（旧条目带集下标、cue 键条目逐格比对两边一致）；页面用例「旧 text-only 条目带集下标：星标亮着，取消收藏删得到」（修前取消后库里仍有一条）。
- **备注**：
