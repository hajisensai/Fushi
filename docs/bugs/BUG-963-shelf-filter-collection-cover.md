## BUG-963 · 筛选时合集内有声书成员丢封面

- **报告**：2026-07-21（用户）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart` `_buildBodyWithSrtBooks` 内三张「从 EPUB 借用」的展示映射（封面 `epubCoverUrisByBookKey` / 有 EPUB 背书 `epubBackedBookKeys` / 借用进度 `epubProgressByBookKey`）遍历的是**筛选后的 `books` 参数**（原约 795-796 行的 `for (final MediaItem item in books)`）。
  - 数据流：书架有两套独立标签过滤——EPUB 走 `filteredBookIdsProvider`、SRT 走 `filteredSrtBookIdsProvider`。合集内的有声书(SRT)成员在渲染时向其关联 EPUB **借封面**（`_buildSrtCard(epubCoverUri: epubCoverUrisByBookKey[srt.bookKey])` → `_buildSrtCover` 回退链，`reader_history/books.part.dart`）。
  - 当用户只给有声书打了标签、关联 EPUB 未命中同一标签时，EPUB 被 `filteredBookIdsProvider` 筛掉 → 传入 `_buildBodyWithSrtBooks` 的 `books` 不含该 EPUB → 借用映射查不到该 `bookKey` → SRT 成员卡回退占位图标 = 丢封面。未筛选时 `books` = 全量 EPUB，映射齐全，故正常。
  - BUG-937/BUG-940 让「被筛合集能带命中的 SRT 成员显示出来」后，此借用映射被筛选裁剪的潜在缺陷才暴露（之前合集在筛选下压根不出现）。同根因也影响 BUG-728 的进度借用在筛选下丢失。
- **[x] ① 已修复** — 借用映射改以**未筛选全量** `ref.read(hibikiBooksProvider(appModel.targetLanguage)).valueOrNull`（新变量 `allEpubBooksForBorrow`，空态回退 `books`）为源，与「参与网格展示的筛选后列表」解耦；三张映射的装配循环改遍历 `allEpubBooksForBorrow`。展示列表（`epubBooks = books.where(...)`）仍用筛选后的 `books`，行为不变。`reader_hibiki_history_page.dart` `_buildBodyWithSrtBooks`。提交见下。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/shelf_collection_cover_borrow_full_corpus_guard_test.dart`（源码扫描守卫，沿仓库既有 `*_guard_test` 范式 + 姊妹 BUG-728 `shelf_srt_card_progress_guard_test.dart`）：切 `_buildBodyWithSrtBooks` 方法体，锁死①借用源 = `ref.read(hibikiBooksProvider(...))` 全量、②装配循环遍历 `allEpubBooksForBorrow`、③回归哨兵不得再 `for (final MediaItem item in books)`、④封面映射写入 `_epubCoverUrisByBookKey` 字段。6 项测试（含 BUG-728 守卫回归复核）全过。
- **备注**：`flutter analyze` 单文件 No issues；进度借用（BUG-728）在筛选下的同类丢失也随本修复一并根治。
