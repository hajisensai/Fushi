## BUG-3302 · 合集详情「继续阅读」停在进页快照，不随阅读更新
- **报告**：2026-10-12（反馈 4h4uGUck4k，Windows：合集内继续阅读显示的不是最近在读的书，翻页或播放有声书都不改变状态）
- **真实性**：✅ 真 bug。`MediaCollectionGridDetailPage` 在 build 里经 `memberInfoOf`（`reader_fushi_history_page.dart` `_collectionMemberInfo`，用 `ref.read(bookLastReadAtProvider)`）取最后阅读时刻 / 进度 / 读完；详情页是压在阅读器之下的独立路由，书架页的 provider 在 `onSourceExit` 失效重算时它没有任何重建触发，「继续阅读」目标与 hero 进度永远是进页时的快照。选取逻辑 `pickContinueMember`（`collection_member_view.dart:166`）本身正确。
- **[x] ① 已修复** — 详情页新增 `memberInfoRefresh`（`Listenable`）订阅并 setState；书架页 `ref.listen` 最后阅读 / 书列表 / 读完集三个 provider，在本页按新值重建后（post-frame）递增 `ValueNotifier` 通知，并同步 `_completedBookKeys`。提交 4f354fe7a4。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_collection_grid_detail_page_test.dart`「继续阅读随 memberInfoRefresh 重算…」。
- **备注**：Windows 真机未复测；「阅读器里翻页是否落库刷新 updatedAt」沿用 BUG-777 的既有行为，未改动。
