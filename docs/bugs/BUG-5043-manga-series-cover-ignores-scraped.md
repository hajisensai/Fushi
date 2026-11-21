## BUG-5043 · 漫画作品页封面不认刮削封面（书架卡已是刮削封面）
- **报告**：2026-11-19（用户：应用内反馈 vJJGPZtC3p，Android；「书架里的漫画刮削了封面，点进漫画详情后封面还是在线源原本的封面」）
- **真实性**：✅ 真 bug。书架卡封面走 `MediaSource.getDisplayThumbnailFromMediaItem`（`fushi/lib/src/media/media_source.dart:402`）：用户 override > 刮削层 `ReaderMediaSource.scrapedThumbnailFile` → `BookArtStore.coverFileFor(bookKey)`（`fushi/lib/src/media/sources/reader_media_source.dart:59-68`）> 书自带封面；而作品页 `MangaSeriesPage._localCoverPath`（`fushi/lib/src/media/manga/library/manga_series_page.dart:2631`，旧实现）只读 `row.coverPath`，`_buildCover` / `_coverImageProvider`（海报、hero 模糊背景、主题取色）全从它取，两处封面来源不一致。
- **[x] ① 已修复** — 新增书族唯一出口 `ReaderFushiSource.displayCoverFileForBook`（`fushi/lib/src/media/sources/reader_fushi_source.dart:1001`，与书架同一优先级：override > 刮削卷封面 > `resolveCoverFilePath`），作品页 `_localCoverPath` 改走它（无 AppModel 的源浏览树只剩自带封面一档）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_series_page_scraped_cover_test.dart`（无刮削 → 自带封面；有刮削 → 海报 / posterImage / backdropFallback 都是刮削封面；override 优先于刮削）。
- **备注**：作品页开着时现场刮削后封面是否即时刷新不在本条范围（本条是「刮削后再点进来」）。
