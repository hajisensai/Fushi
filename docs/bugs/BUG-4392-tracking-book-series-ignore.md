## BUG-4392 · "Don't track the series" is never offered for a book series made by rule
- **报告**：2026-11-11（T1 hands-on test, finding F4）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/tracking/media_tracking_repository.dart` `loadSeriesIndex` / `bookSeriesCollections` only took `collection`-type collections, but the shelf's series cards are `playlist`s with origin `rule` (`BookSeriesGrouper`); and they (and `loadIgnoreIndex`) keyed book members by `entryKey`, which is the book's uid since v82, while tracking keys books by bookKey. So no series was found and an ignored book series could not cover its volumes.
- **[x] ① 已修复** — members resolved uid → bookKey (`_bookKeyOfMember`); a book's series = the collection holding it ranked by `bookSeriesRank` (organiser-made series card, then series-like collection, then any other), oldest first; same rule for the Tracking page and the Track sheet; the ignore index covers volumes added later (finding F4 commit).
- **[x] ② 已加自动化测试** — `fushi/test/media/tracking/book_series_ignore_test.dart`.
- **备注**：
