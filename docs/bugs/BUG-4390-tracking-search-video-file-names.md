## BUG-4390 · Tracking link search pre-fill keeps episode / group noise of video file names
- **报告**：2026-11-11（T1 hands-on test, finding F2）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/tracking/local_title_clean.dart` `localTitleSearchCandidates` only knew book noise; `S01E01`, `S1`, `Episode 46`, ` - 12`, bare `1080p` / `x265` / `WEB-DL` and a `-GROUP` after the tags survived, so `trackingInitialQuery` (`fushi/lib/src/media/tracking/page/tracking_local_targets.dart`) searched e.g. `Beyond Time's Gaze Episode` and found nothing.
- **[x] ① 已修复** — the one shared clean-up now also cuts a video name at its episode part or first bare release tag, drops a trailing release group, video extensions, a parenthesised year, and reads a scene name's dots as spaces (finding F2 commit).
- **[x] ② 已加自动化测试** — `fushi/test/media/tracking/local_title_clean_test.dart` (the tester's real titles + plain titles that must not change).
- **备注**：no search API takes a year, so the year is dropped from the query rather than passed as a hint.
