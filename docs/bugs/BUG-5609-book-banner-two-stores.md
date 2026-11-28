## BUG-5609 · 获取的 MangaBaka 横幅只在合集页显示，书详情页与首页卡片看不到
- **报告**：2026-11-27（用户：合集上点「获取各卷封面与横幅」后，横幅只出现在合集页，书详情页与首页卡片（单本 / 系列合并卡）都没有）
- **真实性**：✅ 真 bug。书 / 漫画的横幅有两份真相：
  - 书籍刮削（Bangumi / DLsite / AniList…）把背景图写进 `item_images` backdrop（`fushi/lib/src/media/metadata/book_metadata_scrape_facade.dart:597`，经 `ItemScrapeStore`）；书详情页（`book_detail_page.dart:161` → `ItemScrapeDetail.load`）、首页（`home_dashboard_page.dart` `_querySeriesMeta` 读 `getItemImages`，系列合并卡借代表卷）、书架系列块（`reader_fushi_history_page.dart` `_borrowedCollectionSeries`）都只读这一份。
  - 「获取各卷封面与横幅」把横幅另存进 `BookArtStore` 的 `<thumbnails>/scraped_banners/`（旧 `book_art_scrape_service.dart:812` `store.writeBanner`），只有合集页经 `CollectionArtScrape.bannerFor`（旧 `collection_art_scrape.dart:62` → `BookArtStore.backdropForCollection`）、`media_collection_grid_detail_page.dart:336/413` `_artBannerFor` 读。
  - 根因是数据结构：同一个概念（书的横版背景图）存两处、各有各的读者，获取写的那份别的页面根本不读。
- **[x] ① 已修复**（1759ac071c）— 横幅只存一份：获取把系列横幅经 `ItemScrapeStore.setSharedImageFromFile` 贴成每一卷的 `item_images` backdrop（同 URL 的文件各卷共用一份，回收随最后一行），`BookArtRecord.bannerKey/bannerUrl` 只记「获取贴了哪张」（背景图 `source_url` == bannerUrl 才算获取写的）。合集页删掉第二条读路径，与书架 / 首页一样借最前那卷的背景图；书架映射重载后经 `memberInfoRefresh` 通知打开着的合集页重算。
  - 覆盖策略：书没有背景图、或现在那张就是之前获取贴的，才贴新横幅；书籍刮削 / 手选来的背景图不覆盖，记录也不认领（`BookArtStore.applyBanner`）。清除 / 单本否决 / 撤销只撤获取贴的那张（`clearBannerFrom`），别的来源不碰。
  - 旧数据：`BookArtStore.migrateLegacyBanners` 一次性把 `scraped_banners/` 按同一覆盖策略搬进 `item_images` 后删掉旧目录（AppModel 初始化收尾触发；获取 / 清除 / 否决 / 撤销也先等它）。不改 schema。
  - 数据根迁移：共用文件在 `video_covers/items/` 下，`DataRootMigrator._rebaseItemImages` 逐行改写，不需改动；备份只带 `item_images` 行（文件本来就不进备份）。
- **[x] ② 已加自动化测试** — `fushi/test/media/metadata/book_art_store_test.dart`（贴成背景图且共用文件、书详情页读得到、不覆盖别处来的背景图、清除只撤本层的、否决、清除后撤销贴回、旧目录搬家）；`fushi/test/media/metadata/book_art_scrape_service_test.dart`（获取写每卷背景图、覆盖策略、换系列撤掉旧横幅、撤销快照）；`fushi/test/ops/op_undo_book_art_test.dart`（ops 刮削 / 清除 / 改钉系列的撤销）；`fushi/test/media/collections/collection_art_scrape_clear_test.dart`（界面「清除」只撤获取贴的）；`fushi/test/pages/collection_detail_poster_hero_test.dart`（合集页经借来那卷显示并随刷新通知更新）；`packages/fushi_engine/test/media/item_scrape/item_scrape_store_test.dart`（共用文件回收、多卷并发贴同一张图）。
- **[x] 审查修复**（独立审查 7 条，逐条根因修 + 测试）：
  1. 回归：合集有 `collection_scrape_meta` 行（Bangumi 刮过）但没有背景图时，合集页 / 首页系列合并卡 / 书架系列块都因「own 不为 null 就不借」看不到获取贴在每卷上的横幅。三处改走同一个合并函数 `fushiCollectionSeriesInfo`（`fushi_series_cover_block.dart`）：own 没背景图时借那卷的背景图，资料 / 简介仍用 own 的。测试：`fushi_series_cover_block_test.dart`（合并规则 + 三个入口都走它的守卫）、`collection_detail_poster_hero_test.dart`（资料行无背景图仍显示借来的横幅）。
  2. 共用文件竞态：「文件已在就复用」与登记行之间，并发撤掉最后一行 / 回收扫描会删掉文件，行指向缺失文件。`ItemScrapeStore` 加进程级键锁：格锁（条目 + 图种）包住一格的全部写入，文件锁让「确保文件 + 插行」与「确认零引用 + 删」互斥；顺序固定格锁 → 文件锁、文件锁不嵌套。`reclaimUnreferencedFiles` 逐个在文件锁里复查再删。测试：`item_scrape_store_test.dart`（并发清最后一行 / 回收 / 复用同一张图，修前红）。
  3. 归属只看 URL：MangaBaka 的书籍刮削候选不带背景图（`mapMangaBakaSeries` 不给 `backdropUrl`），书目源的 `bannerUrl → backdropUrl`（`book_metadata_scraper.dart:192`）只来自 AniList `bannerImage`，现状下撞不上；但手选（并行的横幅选择 PR）或任何同 URL 的单本写入都会被误认成「获取贴的」，清除会撤掉用户的图。改为按共用文件名认领（`isItemSharedImageRow`：路径 = 按 `source_url` 算出的 `<type>_shared_<摘要>_<kind>`，只有批量贴图写得出），撤销指纹加 `backdropFile`。测试：`book_art_store_test.dart`（同 URL 的单本背景图：state other、清除不撤、指纹变）、`item_scrape_store_test.dart`。
  4. 搬家的「没有背景图」判断与写入不原子。`setSharedImageFromFile` / `clearImage` 加 `when` 条件写，在格锁里读当前行再决定；`applyBanner` / `clearBannerFrom` / 搬家 / 撤销的所有「看一眼再写 / 撤」都改用它。测试：搬家与并发书籍刮削各种先后都以书籍刮削那张收场；store 层条件写测试。
  5. 删旧目录失败后重跑会复活已清掉的横幅。`BookArtRecord.bannerOnBackdrop`（新布局恒为 true，旧记录读出为 false）：搬家只搬 false 的，每条先改成 true 落盘再贴图，重跑幂等。测试：旧目录残留 + 用户清掉背景图后重跑不复活。
  6. 撤销时横幅没贴回去（位置被占 / 无备份）仍照快照写回横幅四项。`_restoreBanner` 返回横幅是否在书上，只有在时记录才带横幅。测试：位置被别处占着时记录不写回横幅。
  7. 撤销备份按卷各复制一份横幅。改成内容寻址 `banner_<sha256>`，同系列各卷快照共用；每次被用到刷新修改时间，过期清理按修改时间判；`discardSnapshot` 不再删它（别的卷还要用）。测试：两卷共用一份、逐卷恢复都成功、31 天后清理。
- **备注**：之后「用户手选背景图上锁」（ItemScrapeStore 层）合入时，锁的判断放进格锁里（`_replaceSlot`），`setSharedImageFromFile` 自然过同一把锁；手选写单条目文件名，不会被认成获取贴的共用图。
