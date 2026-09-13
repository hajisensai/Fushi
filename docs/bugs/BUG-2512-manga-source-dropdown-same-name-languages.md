## BUG-2512 · 漫画发现页来源下拉与热门行同名多语言源分不清
- **报告**：2026-09-13（用户：安装 keiyoushi 的 MyReadingManga 后，漫画「发现」页的来源下拉里出现十几条一模一样的「MyReadingManga」，分不清哪条是哪种语言）
- **真实性**：✅ 真 bug。一个 Mihon 扩展按语言拆成多条 `MangaOnlineSourceRow`（只有 `language` 不同），而 `fushi/lib/src/media/manga/discovery/manga_source_catalog_section.dart:92` 的下拉标签与 `manga_discovery_page.dart:654` 的每源「热门」行标题都只用裸 `source.name`，语言信息在这两处被扔掉；同页下方的来源卡片、聚合搜索、匹配结果都已画语言头像/chip，唯独这两处漏了。
- **[x] ① 已修复** — `8fad835b86`：新增 `manga_source_display_name.dart` 的 `mangaSourceDisplayName(name, language)` → `名字 (LANG)`（语言空则退回裸名），下拉标签与 `MangaDiscoverySourceFeed.displayName` 两处统一走它。不做「分组」：`DropdownMenu` 是平铺列表，分组只会加特例。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/discovery/manga_source_display_name_test.dart`：同名三语言源的下拉标签两两不同；语言空/空白退回裸名；feed 展示名与下拉同口径。既有 `manga_discovery_page_test.dart` 的热门行标题断言同步改为带语言码。
- **备注**：Aidoku 包与内置 mokuro 目录的标签不动（Aidoku 包本身是多语言列表、不按语言拆条）。
