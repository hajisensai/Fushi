## BUG-5370 · curator-splits-auto-grouped-series
- **报告**：2026-11-23（用户：漫画书架提醒条「2 manga are not identified yet」，实际是同一部漫画的 2 卷（mokuro.moe 下载），应按系列算一部）
- **真实性**：✅ 真 bug。库管家书刮削单元 `DatabaseLibraryCurateFacts.bookScrapeUnits`（`packages/fushi_engine/lib/media/library_curate/library_curator.dart` 的系列合集查询，改前 `WHERE c.collection_type = 'collection'`）只把 `collection` 型合集认作系列；而书架自动归组 `BookSeriesGrouper` 建的系列是 `playlist` 型、`origin = rule`（`packages/fushi_engine/lib/media/collections/book_series_grouper.dart:322`），AI 整理建的也是 `playlist` 型、`origin = ai`（`library_organize_plan.dart` `collectionType = 'playlist'`）。于是书架上叠成一张系列卡的各卷在库管家眼里全是单书：每卷按自己的卷名（`Series 02`）单独去查，比按系列名查更难命中；查不中时每卷各占一条待确认，提醒条按卷计数（BUG-5283 的提醒条把这个问题暴露出来）。
- **[x] ① 已修复** — 系列合集 = `collection` 型（用户建）或 `playlist` 型且由整理器管（`origin IN (rule, ai)`，即 `CollectionOrigin.isOrganizerManaged`）。用户手建的 `playlist` 可以混放不相干的书，仍不当系列。下游（系列按合集名查、各卷取封面 / 作者、待确认条目键 `collection:<id>`）本来就与合集类型无关，无需改动。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/library_curate/library_curate_facts_test.dart`「整理器建的 playlist 系列（rule / ai）归一个单元；用户手建的 playlist 不归」（真 schema 内存库；改前此条红、改后绿）。
- **备注**：已经因为按卷查而落进待确认的条目，修复后下一趟库管家会按系列单元重查；待确认清单按当前单元复核，同一系列的卷合成一条。
