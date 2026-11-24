## BUG-5378 · anilist-cover-search-novels-only
- **报告**：2026-11-23（BUG-5372 排查时发现：「在线匹配封面」切到 AniList，漫画永远搜不到）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/metadata/books/anilist_novels.dart` `aniListNovelSearchQuery` 写死 `type: MANGA, format: NOVEL`，书架上的漫画（含韩漫、国漫）在 AniList 源一条候选都没有；按 id 直取不限形态，搜索却限了，两条路径口径不一。
- **[x] ① 已修复**
  - 搜索去掉 `format: NOVEL`，按匹配度回轻小说、漫画、短篇；文件与类改名为 `anilist_books.dart` / `AniListBookClient`。
  - 每条候选带形态 `BookCatalogFormat`（`format` + `countryOfOrigin`：漫画 / 韩漫（KR）/ 国漫（CN、TW、HK）/ 轻小说 / 短篇）。弹窗在候选资料行写明形态，同名的轻小说与改编漫画分得清；控制通道候选多回 `format`。
- **[x] ② 已加自动化测试**
  - `packages/fushi_engine/test/media/metadata/books/book_catalog_parsers_test.dart`：查询不带 `format:`、要回 `format countryOfOrigin`；形态映射；解析带出形态。
  - `fushi/test/media/metadata/book_cover_scrape_dialog_test.dart`「AniList：漫画与轻小说都搜出来，候选写明形态」。
- **备注**：NDL 只收日本国内出版物，中文版漫画查不到是数据源本身的范围，不是代码问题；中文版用 Bangumi / MangaBaka。
