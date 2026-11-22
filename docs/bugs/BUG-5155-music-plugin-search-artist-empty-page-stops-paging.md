## BUG-5155 · music-plugin-search-artist-empty-page-stops-paging
- **报告**：2026-11-22（审查 PR #4034 / HBK-AUDIT-026 时发现的同类存量，develop 上已有）
- **真实性**：✅ 真 bug（源码确认，未跑真机）。插件搜索 / 艺人页签 / 统一搜索的宿主分页把「本页非空」当续页条件：`fushi/lib/src/pages/implementations/music/music_plugin_pages.dart:516`（插件搜索页 `_hasMore = page.hasMore && page.items.isNotEmpty`）、`music_plugin_detail_pages.dart:949`（艺人专辑 / MV 页签 `feed.hasMore = ...`）、`music_unified_search.dart:1060`（统一搜索里的插件 feed）。宿主解析 `MusicPluginTrack.listFrom` 等（`packages/fushi_music/lib/src/plugin/plugin_models.dart:522`）会丢掉解析不了的条目，插件自己也可能过滤成空页；这时插件 `hasMore: true` 被宿主截断，后续页再也取不到。与 BUG-5144（浏览列表 / 分类目录）同一根因，BUG-5144 已用 `MusicPluginPager`（`packages/fushi_music/lib/src/plugin/plugin_pager.dart`）修了浏览两页，这三处没跟上。
- **[ ] ① 未修复** — 方向：三处改用 `MusicPluginPager`（续页只认插件 hasMore、无进展时暂停自动续载给「加载更多」、同页重复判停、跨页去重），各自接「加载更多」入口（统一搜索是多 feed 并列，入口放各 feed 的分组底部）。
- **[ ] ② 未加自动化测试** — 方向：仿 `fushi/test/pages/music_plugin_browse_test.dart` 的 HBK-AUDIT-026 用例，插件第 0 页只回坏条目、`hasMore: true`，断言给「加载更多」并能取到第 1 页。
- **备注**：Kavita（`kavita_books_view.dart:177` / `kavita_browse_page.dart:356`）同写法，但 Kavita 服务端分页不做宿主侧丢条目，空页确为到头，不在本条范围。
