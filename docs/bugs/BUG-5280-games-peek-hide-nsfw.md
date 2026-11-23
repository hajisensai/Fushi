## BUG-5280 · 游戏速览无视「隐藏成人向」偏好
- **报告**：2026-11-22（用户：侧栏速览卡要与点进去的页面一致；只读审查发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_nav_peek.dart:493-496`（develop 06c73737a2）`_loadGames` 只滤 `lockVisibility.hidesGame`；游戏首页 `_shows`（`galgame_home_page.dart:232-233`）与库页 `matchesGalgameFilters`（`mining/galgame_library_query.dart:206`）还会按 `GalgameLibraryView.hideNsfw` 藏掉成人向条目，三处各写一份判据，速览漏了这一条。
- **[x] ① 已修复** — 判据只写一次：`galgame_library_query.dart` 新增 `galgameHiddenByNsfwPref`（库页筛选改用它），`mining/galgame_home_selection.dart` 新增 `galgameShownOnHome`（隐藏成人向 + 上锁），游戏首页 `_shows` 与速览 `navPeekGamesFeed` 都用它；速览按 `GalgameLibraryView.decode(appModel.galgameLibraryView).hideNsfw` 读偏好。（提交 1c515c6992 + 速览接线提交）
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_nav_peek_mirrors_page_test.dart`「隐藏成人向：库页筛选、首页判据与速览一起藏」+ 接线守卫。
- **备注**：未在应用里肉眼复测。
