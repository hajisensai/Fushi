## BUG-991 · 书架「书库概览」总数漏算远端书(只数本地卡,不数书架上可见的互联远端占位卡)
- **报告**：2026-07-14（用户：书籍显示数量有问题，是本地书籍的数量；确认「总数漏算了远端书」，要求「和视频一样」把可见远端书算进总数）
- **真实性**：✅ 真 bug。根因：`reader_hibiki_history_page.dart` 书库概览 `libraryTotal` 传入 = `epubBooks.length + srtBooks.length`（仅本地），但联合视图（spec §2.1）已把互联远端占位书（`remoteBooks` + `remoteSrtBooks`，已 dedupe 去重、已按 showRemote 门控）混排进主网格作一等卡。于是用户看到一屏含远端书,而「总数」只报本地数（截图总数 2），数字与可见卡数对不上。
- **[x] ① 已修复** — `libraryTotal` 改为 `epubBooks.length + srtBooks.length + remoteBooks.length + remoteSrtBooks.length`（书架可见卡数）；概览显示门槛同步加入 `remoteBooks/remoteSrtBooks` 非空（纯远端、无本地书时概览也显示）。`remoteBooks`/`remoteSrtBooks` 已 dedupe（去掉与本地重复者）故无双算。「在读/已完成」仍按 EPUB-backed 进度（远端未下载卡无本地进度，不计）——total=可见总数、reading/finished=有进度者，与视频页「总数/未完成」口径看齐。
- **[x] ② 已加自动化测试** — `test/pages/reader_remote_interconnect_test.dart`：1 本本地 SRT + 1 本远端占位 → 概览「总数」格（新加 key `shelf_overview_total`）断言为 2（此前只报本地 1）。
- **备注**：取 815 避让 origin/develop 已用的 808-810；与 BUG-813/814 同属互联下载/浏览体验一批。视频页 total 目前仍只数本地 `all`（`computeVideoLibraryOverview.total = entries.length`），若用户要视频也含远端另开单。
