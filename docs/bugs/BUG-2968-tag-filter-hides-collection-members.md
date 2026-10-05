## BUG-2968 · 标签筛选时合集内打了标签的书找不到
- **报告**：2026-10-05（用户转述群友：书架「标签页选择也找不到书」）
- **真实性**：✅ 真 bug。成员级过滤 `keepMemberUnderTagFilter` 放行了自己命中标签的书，书随后被 `groupByCollections` 折进所在合集组；但库页紧接着按「合集自身是否命中全部选中标签」整组删除——书架 `fushi/lib/src/pages/implementations/reader_fushi_history_page.dart:1605`（旧 `shelfGroups.removeWhere(... !collectionFilter.contains(g.collection!.id))`）、视频库 `fushi/lib/src/pages/implementations/home_video_page.dart:4961`（旧 `collectionVisible`）。书打了标签、合集没打 → 书从库页消失，按标签筛选永远找不到它。
- **[x] ① 已修复（b01a89347b5）** — 组级判据收口为共享纯函数 `keepCollectionGroupUnderTagFilter`（`fushi/lib/src/media/collections/collection_grouping.dart`）：合集自身命中 **或** 组内任一成员自身命中即保留；书架与视频库同改。
- **[x] ② 已加自动化测试（b01a89347b5；页面级回归另见 3565b1fe665 的 `fushi/test/pages/reader_shelf_collection_cards_test.dart`）** — `fushi/test/media/collection_tag_filter_group_test.dart`（纯函数四档 + 整条「成员过滤 → 折叠 → 组过滤」管线 + 两页源码守卫）。
- **备注**：保留下来的合集组只含命中标签的成员（未命中的成员已在成员级过滤阶段剔除），所以显示的是「这个合集里带这个标签的书」。
