## BUG-3246 · 首页继续等直接打开在线漫画不按重新打开位置偏好选章
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2031）。书架卡片本身先进作品页，但首页「继续」、历史、合集、统计等经 `openMedia` 直接开漫画时，`MangaFushiSource.buildLaunchPage` → `MangaFushiPage` 的 `_loadOnlineBookFromShelf`（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart` 原 :2022）用 `OnlineMangaLibraryService.initialChapterIndex` = `currentChapterIndex`（只记最后一次选的章），没走作品页「继续阅读」的 `resumeChapterIndex` + 偏好 `manga_resume_target` 判据：读完第 N 话退出后，作品页继续去第 N+1 话，直接开书却回到第 N 话第 1 页（两种偏好下都分叉）。根因是阅读器分不清「作品页点名了这一章」与「直接开书」，两者共用 `currentChapterIndex` 交接。
- **[x] ① 已修复** — `8ff3ab5793`：新增 `mangaReaderOpenChapterIndex`（`manga_resume_point.dart`，点名就用点名的章，否则走 `continueMangaChapterIndex` + 偏好）；`MangaFushiPage.initialChapterIndex` 承接点名；作品页开章经 `openMedia(launchPageBuilder:)` + `MangaFushiSource.buildChapterLaunchPage` 显式点名（会话副作用仍走 openMedia），直接开书不点名。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_resume_point_test.dart`「阅读器开书落到哪一章」组（判据与作品页继续阅读一致、点名优先、越界回落）+ `fushi/test/media/manga/manga_reader_open_chapter_wiring_test.dart`（直接开书不点名、点名版把下标交给阅读器、作品页走点名路径）。
- **备注**：
