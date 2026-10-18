## BUG-3513 · 合集详情页顶栏标签按钮与 hero「编辑标签」功能重复
- **报告**：2026-10-18（用户：截图圈出顶栏标签图标与 hero 内「编辑标签」chip，「两个按钮功能重复」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/media_collection_grid_detail_page.dart` 的 `_buildAppBar` 与 `CollectionDetailHeroCard(onEditTags:)` 都调 `_editCollectionTags`。
- **[x] ① 已修复** — d6e6cf32c9：删掉顶栏那颗，保留 hero 里紧挨标签 chip、带文字的「编辑标签」。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_collection_grid_detail_page_test.dart`「顶栏不再有与 hero『编辑标签』重复的标签按钮」。
- **备注**：
