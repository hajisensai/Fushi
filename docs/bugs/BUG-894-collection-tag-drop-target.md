## BUG-894 · 标签拖到合集行头无接收（合集打标签仅详情页按钮入口）

- **报告**：2026-07-19（用户：标签拖到合集上没反应，但应该可以给合集打标签）
- **真实性**：✅ 真 bug（交互缺口）。PR#128（已合 develop）落地了「合集打标签」的数据层（`CollectionTagMappings` 表 + `addTagToCollection`/`getTagsForCollection`/`removeTagFromCollection`，`packages/hibiki_core/lib/src/database/database.dart:4054-4083`）与详情页 AppBar 打标签按钮（`tag_picker_page.dart:62` 的 `collectionId` 分派），但**没有实现「把标签拖到合集上」这个手势**：
  - 标签是 `LongPressDraggable<BookTagRow>`（`tag_filter_bar.dart:136`）。
  - 书/视频/SRT 卡外包 `BookDragTarget`（`book_drag_target.dart:33`，`DragTarget<BookTagRow>` → `onTagDropped` → `addTagToBook`/`addTagToVideoBook`/`addTagToSrtBook`），所以拖到书卡有效。
  - 合集行 `CollectionShelfRow`（`hibiki/lib/src/media/collections/collection_shelf_row.dart`）**根因**：既不是 `DragTarget`，两个调用点（`home_video_page.dart` 的 `_buildVideoCollectionRow`、`reader_hibiki_history_page.dart` 的 `_buildShelfCollectionRow`）也没把它包进 `BookDragTarget`。标签落在合集行头上无处接收 → 静默无反应。合集内的成员卡各自仍是书级 `DragTarget`（拖到某集=给那本书打标签），缺的是**合集级** drop target。

- **[x] ① 已修复** — 在 `CollectionShelfRow` 加可选 `onTagDropped`（`hibiki/lib/src/media/collections/collection_shelf_row.dart`）：非 null 时把**行头**包一层 `DragTarget<BookTagRow>`（`_wrapTagDropTarget`，与 `BookDragTarget` 视觉同源、适配行头形状，拖入时高亮边框 + 末端 `new_label` 图标；`IgnorePointer` overlay 不吞点击/焦点）。行头区与成员卡区在 `Column` 里不重叠，语义清晰。两个调用点接线合集级打标签：
  - 视频页 `_addTagToVideoCollection`（`home_video_page.dart`）：查 `getTagsForCollection` 去重 → `addTagToCollection` → 失效 `filteredCollectionIdsProvider` → toast。
  - 书架页 `_addTagToCollection`（`reader_hibiki_history_page.dart`）：同上（不复用 `_addTagToMedia`，其「已存在」提示固定为 `tag_already_on_book`，合集文案不对）。
  - 新增 i18n `tag_added_to_collection` / `tag_already_on_collection`（`tool/i18n_sync.dart --add`，17 语言，`dart run slang` 重生成）。
  - 提交：f0ad59aa4

- **[x] ② 已加自动化测试** — `hibiki/test/widgets/collection_shelf_row_tag_drop_test.dart`：pump `CollectionShelfRow` + `Draggable<BookTagRow>`，把标签拖到行头断言 `onTagDropped` 收到该 `BookTagRow`；并断言 `onTagDropped: null` 时行头不是 `DragTarget`（回归守卫：防止调用点漏传接线又退回静默）。提交：f0ad59aa4

- **备注**：合集打标签的持久化/同步（`CollectionSyncEngine` 并集透传、备份合并 `_mergeCollectionTags`）与详情页展示均由 PR#128 提供，本修复仅补「拖放」这条交互入口，与已有「详情页 AppBar 按钮」入口等价。真机验收：视频/书架合集行头拖标签→toast→穿 DB（详情页标签行可见）、标签栏过滤合集卡显隐、重复拖同标签提示「已在此合集上」、回归普通书/视频/成员卡拖标签仍有效。
