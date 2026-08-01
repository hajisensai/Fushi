## BUG-1393 · 合集子篇被自动刮成作品级竖版海报，且作品海报被整个丢弃
- **报告**：2026-08-02（用户：「子篇封面禁用作品级竖版海报：**作品海报只归合集封面**，成员条目保持抽帧/集级剧照，宁可无封面不凑数（含下载导入海报改落合集 coverPath）」）
- **真实性**：✅ 真 bug。两半根因：
  - **闸门缺失**：`hibiki/lib/src/media/video/scraper/cover_scraper_service.dart:329` `scrapeLibrary` 逐本只按 `CoverOrigin.batchOverwritePolicy` 判覆盖许可，完全不知道这本属不属于合集（`VideoBookRow` 无 collection 字段），于是 26 集番的每一集都被 `_applyCandidate`（同文件 `:890`）刷上同一张作品级竖版海报。
  - **改投缺失（第一版修复的回退）**：只加闸不改投的话，`updateMediaCollectionCoverPath` 全仓只剩两个调用方（`collection_scrape_apply.dart:43` 手动弹窗、番剧下载导入），**扫描/自动刮削的多集合集海报既不落成员也不落合集** → 合集卡从「显示海报」退化成「显示首集抽帧」（渲染回退链 `home_video_page.dart:3487` 的 `coverPath` 优先 → 借成员）。这与用户口径「作品海报**只归合集封面**」直接相悖：用户要的是海报**改投**，不是海报**消失**。
  - **存量不回退**：`_maybeBackfillCovers`（`home_video_page.dart:521`）只补空封面，`VideoScrapeAutoService._pending`（`auto_scrape_service.dart:129`）只喂「还没有资料行」的书——而被刷上海报的子篇**恰恰都有资料行**，永远不会被重新访问。不做存量清理，用户开 app 看到的还是坏的。
- **[x] ① 已修复** — 三处：
  1. `collection_member_policy.dart`（新）`multiMemberCollectionIdByVideoUid` 纯函数：全库合集成员表 → `子篇 uid → 最小多成员 collectionId`。返回 **Map 而不是 Set/bool**——闸住只做对一半，海报还得有地方去。
  2. `cover_scraper_service.dart` `scrapeLibrary`：子篇一律不落成员封面（任何开关解不开），并复用同一次匹配的决策调 `_promoteCollectionCover` 把海报下到 `collections/<id>.jpg` + 写 `MediaCollections.coverPath`；一合集一次、不覆盖已有合集封面、失败只记日志不翻 outcome。`_scrapeMetadataOnly` 改为返回 `MatchDecision?` 以复用匹配结果，不重发搜索。
  3. `member_cover_cleanup.dart`（新）存量清理：纯判据 `planMemberCoverCleanup` + 落地 `runMemberCoverCleanup`，由 `VideoScrapeAutoService.sweep` 在**刮削之前**每进程跑一次。把成员身上的作品海报**升格**成合集自有封面后清成员那一列。
  4. `anime_download_importer.dart`：AniList 作品海报直落合集 `coverPath`，首集只留抽帧 + `coverSource` 借用链兜底。
  - **误删方向的收口**（存量清理是清空类改动）：只认 `CoverOrigin.autoScraped`（`manual`/`userScraped`/`sidecar` 是用户拍板、`scraped` 是来源不明的存量、`autoFrame`/无记录本就是想保留的）；路径**只来自被清那一行自己的 `coverPath` 字段**（不枚举目录不猜文件名）；规范化后必须 `p.isWithin` 自有封面目录**且直接父目录相等**（目录外 = 用户自己的图，`collections/` 子目录 = 合集封面，都在射程外）；**一个文件都不删**——孤儿由既有 `VideoStorage.gcOrphanCovers` 回收（它非递归，`collections/` 天然免疫）。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/video/scraper/collection_member_policy_test.dart`（6）判据纯函数。
  - `hibiki/test/media/video/scraper/collection_member_cover_gate_test.dart`（5）闸 + **海报真落到合集 coverPath**、一合集只下一次、已有合集封面不覆盖不出网、单片/单成员合集照旧、用户手动匹配放行。
  - `hibiki/test/media/video/scraper/member_cover_cleanup_test.dart`（14）判据层 **误删方向逐条穷举**（用户手选/legacy scraped/抽帧/非子篇/空路径/目录外/路径遍历/`collections/` 子目录）+ 落地层真 DB 真文件（升格、非目标行逐字节不变、不覆盖已有合集封面、幂等、升格后的合集封面扛得住 `gcOrphanCovers`）。
  - `hibiki/test/torrent/anime_download_importer_test.dart`（4）海报落合集列、成员不沾、无 URL 不误写、非图片响应不落盘。
  - **变异实测**：摘掉 `_promoteCollectionCover` 调用 → gate 测试红；把清理判据从 `!= autoScraped` 放宽成 `== autoFrame` → 7 条红（含全部误删方向用例）；拆掉 `p.isWithin` + 父目录围栏 → 2 条误删方向用例红。
- **备注**：接管 PR#677 复核退回的三条必改（看板 TODO-2554，源需求 TODO-2549）。守卫覆盖洞另记 BUG-1394。
