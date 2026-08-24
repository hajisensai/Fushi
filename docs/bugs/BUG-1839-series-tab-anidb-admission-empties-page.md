## BUG-1839 · 系列页按 AniDB primary 身份门控，整页变空（用户库 anidb=0/tmdb=875）
- **报告**：2026-08-24（用户截图：视频 → 系列 整页空白，空态却写「没有书籍匹配所选标签」，而标签一个都没选）
- **真实性**：✅ 真 bug（回归 + 空态文案说谎）。根因 `fushi/lib/src/pages/implementations/home_video_page.dart`
  的三道 AniDB 准入门，由 `711a9a2e62`（2026-08-23 21:26 `feat(video): clear all scrape records safely`）引入：
  ① `ordered` 过滤加 `_isAniDbScrapedSeriesMember(b)`；② `_effectiveCollectionIdForBook` 在 series 分区只返回
  `_aniDbScrapedCollectionByBookUid`（用户合集归属被判成 null）；③ `_buildLocalVideoSlivers` 只保留
  `_aniDbScrapedCollectionIds` 里的合集组，并把远端占位整体挡在系列外。
  判据是 `video_metadata_provider_identities.provider='anidb' AND is_primary=1`。
  **用户生产库实测**（只读副本 `D:\APP\HIBIKI_date\support\fushi.db`，user_version=88）：`video_books` 858 条；
  provider 身份 tmdb 875 primary / bangumi 13 / anilist 3、**anidb 0 条**；按该判据算出的系列页候选 **0**。
  AniDB HTTP 身份要求注册 client（`anidbClientName` + 版本，`AniDbVideoMetadataProvider.isHttpApiAvailable`），
  用户 preferences 里无任何 anidb 配置 → 结构上永远写不出 anidb primary，系列页因此恒空。
  空态又无条件走 `_buildFilteredEmpty()` → 显示 `tag_no_books_for_filter`「没有书籍匹配所选标签」，
  把「没有条目符合准入」说成「你的标签筛选没命中」，掩盖了真实原因。
- **[x] ① 已修复** — 用户拍板「没刮削也应该进，合集就应该在系列里面」：系列与「全部视频」的区别是**折叠方式**
  （合集折成一张封面卡 vs 逐条平铺），不是刮削资格。三道门全部撤除，`_effectiveCollectionIdForBook` 的分区
  分叉一并消除（标签过滤 / 标题搜索 / 最终分组从此天然同口径），远端占位卡照常按 host 下发的主合集归属折叠；
  四个 `_aniDbScraped*` 页面字段与其加载查询成为死代码后删除（DAO 保留）。花絮/短篇排除这条既有行为不动。
- **[x] ② 已加自动化测试** — 行为层 `fushi/test/pages/home_video_series_admission_test.dart`（4 条：零刮削普通
  合集入墙、零刮削散卡入墙、TMDB primary（用户库真实形态）入墙、花絮仍被排除）；源码层把
  `video_library_series_structure_guard_test.dart` 里钉死旧行为的那条 test 改写成新契约，并加禁止型断言拦住
  6 个回归 token（`_isAniDbScrapedSeriesMember` / `aniDbScrapedVideo*()` 等）与「归属解析不得按分区分叉」。
  变异实测两轮：① 让合集在系列页被挡（`if (!kMutationProbe1839 || group.collection == null)`）→ 4 条里恰好
  2 条「合集必须进系列」红、散卡与花絮 2 条仍绿；② 往 lib 注入被禁 token → 源码守卫红（禁止型判据读得到）。
  两轮还原后 `home_video_page.dart` SHA-256 均与变异前逐字节一致（`92960992…dace1`）。
- **备注**：空态文案本身仍是 `tag_no_books_for_filter`（「没有书籍匹配所选标签」）。准入门去掉后它只在真的有
  筛选（标签 / 搜索 / 年份 / 看完状态）时才可能出现，说谎面大幅收窄；但严格说搜索或年份滤空时文案仍不准，
  改它要动 17 份 i18n，留作独立小改。
