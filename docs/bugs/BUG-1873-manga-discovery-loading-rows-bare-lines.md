## BUG-1873 · 漫画发现页来源热门行加载态是一排无标签的裸横线
- **报告**：2026-08-25（用户：截图——漫画「发现」页顶部一个转圈，下面二十多条等距的深色横线铺满整页；「漫画的发现加载太抽象了」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/discovery/manga_discovery_page.dart:574`（修前）`MangaDiscoverySourceRow.build` 在 `_items == null` 时只渲染 `LinearProgressIndicator(minHeight: 2)`：每个已启用 Mihon 源一条（`mihonDiscoverySourceFeeds` 按 `enabledMangaOnlineSources` 逐源建行），启用二十几个源就是二十几条没有任何标签的 2px 横线，看不出那是什么、也看不出在等谁；加载完成后行头才出现，布局跳动。全局搜索页同场景早已是「源名行头 + 16px 行内转圈」（`manga_global_search_page.dart:238` `_statusTrailing`）。
- **[x] ① 已修复** — `c953b9494d`：加载中就渲染带源名的行头（`manga_discovery_source_popular(source:)`）+ 行内 16px `CircularProgressIndicator`，与全局搜索页同形；`items == null` 不渲染卡片条，`items.isEmpty`/失败仍整行收起。加载完成标题原位不动，卡片条在其下长出。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/discovery/manga_discovery_page_test.dart`：「来源热门行加载中显示带源名的行头，而不是一条裸横线」用 `Completer` 钉住 pending 态，断言行头文案 + 行内转圈存在、`LinearProgressIndicator` 不存在；完成后卡片出现、转圈消失。变异实测：`items == null` 时收起整行 → 红。
- **备注**：二十几个源同时 `getPopular` 的请求量本条不动（是行首次挂载即加载的既有设计）；只修可读性。
