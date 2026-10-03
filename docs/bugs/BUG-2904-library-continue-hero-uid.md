## BUG-2904 · 书架「继续阅读」不随最近阅读更新
- **报告**：2026-10-03（用户：读了新书，书架顶部「继续阅读」仍停在《いもーとらいふ〈上〉》）
- **真实性**：✅ 真 bug。`bookLastReadAtProvider` 自 v82 起键是 `EpubBooks.uid`（`fushi/lib/src/media/sources/reader_fushi_source.dart` `bookLastReadAtProvider`），书架页 hero `_buildShelfOverviewSection`（`fushi/lib/src/pages/implementations/reader_fushi_history_page.dart`）却拿 `_parseBookKey(...)` 得到的 **bookKey** 直接查表——恒查空 → 所有候选 lastReadAt=0 → `mostRecentlyReadCandidate` 并列保留首个 → 退化成 `fushiBooksProvider` 列表序（importedAt 倒序）里的第一本在读书，即「最近导入」而非「最近阅读」，BUG-777 原症状回潮。同页「最近阅读」排序与首页 dashboard 都做了 bookKey→uid 换算，只有书架 hero 漏了（hero 从首页搬回书架时未带上换算）。
- **[x] ① 已修复** — 新增 `lastReadAtForBookKey(lastReadAtByUid, epubUidByKey, bookKey)`（`reader_fushi_source.dart`），书架 hero 与「最近阅读」排序共用这一跳换算。
- **[x] ② 已加自动化测试** — `fushi/test/pages/shelf_recent_read_order_test.dart`（`lastReadAtForBookKey` 组：换算、hero 选刚读新书、回退原键）；`fushi/test/pages/unified_collections_architecture_guard_test.dart` 源码守卫：hero 与排序都必须走该 helper、书架页禁止 `_lastReadAtByBookKey[` 裸下标。
- **备注**：未在真机复测（纯数据查表键错误，单测已覆盖选择逻辑）。截图中「Continue Reading」在日语界面显示英文，是 `strings_ja.i18n.json` 的 `book_continue_reading` 未翻译，与本 bug 无关。
