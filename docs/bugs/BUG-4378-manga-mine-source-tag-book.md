## BUG-4378 · 漫画制卡的来源分类标签写成 book 而非 manga
- **报告**：2026-11-07（应用内反馈 uOanUXUIDt，iPad / iOS）
- **真实性**：✅ 真 bug（拍板项 manga-mine-source-tag）。分类标签由 `AnkiMiningSource` 决定，枚举只有 book/video/game/music（`packages/fushi_anki/lib/src/anki_models.dart:936`），漫画阅读器制卡显式传 `AnkiMiningSource.book`（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart:5453`），收藏夹批量制卡把漫画句也落到默认 `book`（`fushi/lib/src/media/favorites/favorite_batch_mining_plan.dart:218`）。
- **[x] ① 已修复** — 枚举加 `manga`，`BaseAnkiRepository.mangaTag = 'manga'` 进分类标签映射（AnkiConnect / AnkiDroid / SRS 共用 `buildNoteTags`，层级标签同样变成 `manga::<作品名>`）；漫画阅读器制卡与收藏夹漫画句改传 `AnkiMiningSource.manga`；设置里「来源分类标签」说明文案 17 语补上 manga。只决定新卡，旧卡的 `book` 标签不迁移不重写；统计桶不变（仍归书籍）。
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/mining_tag_and_parallel_test.dart`（AnkiConnect / AnkiDroid 两端 manga→`fushi manga`）、`packages/fushi_anki/test/note_tags_nested_title_test.dart`（`manga::<作品名>`）、`fushi/test/media/favorites/favorite_batch_mining_plan_test.dart`（漫画收藏句→manga 标签、书籍统计桶）、`fushi/test/media/manga_routing_guard_test.dart`（漫画页声明 manga 来源）。
- **备注**：互联转发制卡按 `AnkiMiningSource.name` 传字符串，旧版本接收端不认识 `manga` 时 `miningSourceFromName` 返回 null → 只少分类标签，不报错。
