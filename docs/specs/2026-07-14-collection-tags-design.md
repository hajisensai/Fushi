# 给合集打标签（Collection Tags）设计

- 日期：2026-07-14
- 状态：设计已批准，待写实现计划
- 相关：`docs/specs/2026-07-11-unified-collections-plan.md`（统一合集，曾把"合集级标签"列为非目标 §1；本设计补上）

## 1. 目标与非目标

**目标**
- 用户可给"统一合集"（Jellyfin 式 `MediaCollections`，含 `collection` 无序合集与 `playlist` 有序播放列表）添加/移除标签。
- 合集标签**复用现有共享标签池** `BookTags`——与书/视频/SRT 用同一套标签（如「日语」「N1」）。
- 视频 tab 与书架两处的合集详情页都能编辑标签。
- 库网格里合集卡片随现有 `HibikiTagFilterBar` 的选中标签**一并过滤**。
- 合集标签**跨端同步**，随合集一起走并集同步。

**非目标**
- 不为合集造独立标签池、独立标签管理 UI（复用 `TagManagementPage`）。
- 不做"合集标签删除跨端传播"（与现有书/视频标签一致，见 §5 决策）。
- 不改动现有书/视频/SRT 标签的任何行为。

## 2. 数据层

### 2.1 新表 `CollectionTagMappings`（schema v42 → v43）

`packages/hibiki_core/lib/src/database/tables.dart`，与既有三张 tag 关联表同构：

| 列 | 类型 | 约束 |
|---|---|---|
| `collectionId` | INT | `.references(MediaCollections, #id, onDelete: cascade)` |
| `tagId` | INT | `.references(BookTags, #id, onDelete: cascade)` |

- 唯一键 `{collectionId, tagId}`（`@DataClassName('CollectionTagMappingRow')`）。
- 加进 `@DriftDatabase(tables: [...])` 注解，跑 build_runner 重生成 `database.g.dart`。

### 2.2 迁移

`packages/hibiki_core/lib/src/database/database.dart`：
- `schemaVersion` 42 → 43（`database.dart:395`）。
- `onUpgrade` ladder 末尾追加，照最新加表模板 `if (from < 42)`（`database.dart:920`，纯 createTable）：
  ```dart
  if (from < 43) {
    if (!await _tableExists('collection_tag_mappings')) {
      await m.createTable(collectionTagMappings);
    }
  }
  ```
- `onCreate` 无需改（`createAll()` 建全表）。
- 降级保护由既有 `beforeOpen` 兜底，无需改。

### 2.3 DAO（`database.dart`，照抄现有 tag 方法签名）

参照 `getTagsForBook`(3774) / `addTagToBook`(3881) / `removeTagFromBook`(3888) / `getBookKeysForAllTags`(3899)：

```dart
Future<List<BookTagRow>> getTagsForCollection(int collectionId);
Future<void> addTagToCollection(int collectionId, int tagId);
Future<void> removeTagFromCollection(int collectionId, int tagId);
/// 过滤用：含【全部】选中标签的合集 id（AND 语义，仿 getBookKeysForAllTags 的
/// HAVING COUNT(DISTINCT tag_id) = N）。空集返回空。
Future<Set<int>> getCollectionIdsForAllTags(Set<int> tagIds);
```

注意：`addTagToBook`/`removeTagFromBook` 现在会 upsert/清 `BookTagMembershipTombstones`（tags-sync LWW 脚手架，但同步合并**尚未消费**这些墓碑）。合集标签**不**镜像墓碑逻辑——`addTagToCollection` 只 `INSERT OR IGNORE`、`removeTagFromCollection` 只 `DELETE`（YAGNI：同步不读墓碑，造 `CollectionTagMembershipTombstones` 无消费者）。

## 3. 编辑 UI

### 3.1 `TagPickerPage` 加第 4 路分派

`hibiki/lib/src/pages/implementations/tag_picker_page.dart`：
- 现有构造是 `bookKey` / `srtBookId` / `videoBookUid` 三选一 assert 分派（`:13-23`）。加第 4 个可选参数 `collectionId`，assert 扩为四选一。
- `_addTag`/`_removeTag`（`:54-68`）按 `collectionId != null` 分派到 `addTagToCollection`/`removeTagFromCollection`；读当前标签用 `getTagsForCollection`。
- FAB 快建标签（`TagEditDialog`）逻辑不变。

### 3.2 两个合集详情页各加入口

- `MediaCollectionDetailPage`（playlist，`media_collection_detail_page.dart:266` AppBar `actions`）：在 rename、delete `IconButton` 之间加一个"打标签" `IconButton`（`Icons.sell_outlined`）→ `TagPickerPage(collectionId: widget.collection.id)`。
- `MediaCollectionGridDetailPage`（collection 网格，`media_collection_grid_detail_page.dart:328` AppBar `actions`）：同上。
- 注意：两页 rename/delete 挂在 **AppBar `IconButton`**（不是 PopupMenu），故新入口也用 `IconButton`。
- 两页头部渲染 `HibikiTagChip` 行展示当前标签（与书/视频详情一致；chip 用 `tone: surface`）。编辑返回后刷新（沿现有 `onChanged` / setState 路径）。

## 4. 过滤联动

现有过滤是一组 `FutureProvider` 派生自共享 `selectedTagIdsProvider`（`tag_filter_sheet.dart:11`）：`filteredBookIdsProvider`(:13)、`filteredSrtBookIdsProvider`(:57)、`filteredVideoBookUidsProvider`(:84)。消费者在 `home_video_page.dart:1652` 与 `reader_hibiki_history_page.dart:356/960`，各自 `.where((x) => filterSet.contains(x.id))` 过滤卡片列表。合集照同一范式:

- `tag_filter_sheet.dart` 新增 `filteredCollectionIdsProvider`（仿 :13，`tagIds.isEmpty ? null : db.getCollectionIdsForAllTags(tagIds)`）。
- 合集卡片组装处（视频 `home_video_page.dart` `_buildLocalVideoSlivers` ~:1941；书架 `reader_hibiki_history_page.dart` 网格组装）：`filter == null` 全显，否则 `collectionFilter.contains(collection.id)` 判定合集卡显隐。空选（filter==null）不隐藏任何卡（与现有 `filter == null ? all : ...` 一致）。

## 5. 跨端同步

### 5.1 决策：按名并集、只增不删

合集标签采用**"按标签名并集、不删除传播"**——与现有全部标签同步行为一致：
- 标签跨端只能按**名**传递（`BookTags.id` 各设备不一致，`sync_manager.dart:17-23`）。
- 现有书/视频/SRT 标签的**同步合并**都是**只增不删并集**（`backup_merge_engine.dart:790` `_mergeTagsAndMappings` 用 `JOIN book_tags ON name` + `INSERT OR IGNORE` 去重；`sync_orchestrator.dart:1966` sidecar「绝不清本地既有标签」）。DB 层虽有 `BookTagMembershipTombstones` 墓碑脚手架，但同步合并**尚未消费**（代码注释 `TODO tags-sync`），故实际同步行为就是只增不删。合集标签与此对齐。
- **已知限制**：某端把标签从合集移除，不会跨端传播（对端仍保留，或下次同步复活）。与书/视频标签今天的行为完全一致。若日后要"删除也同步"，需加平行 tag 墓碑（本期不做）。

### 5.2 云盘/互联通道：挂在合集清单 entry

标签随**合集**走并集同步（不新造 sidecar）：

1. `collection_manifest.dart`：`CollectionManifestEntry`（`:122`）加 additive 字段 `List<String> tagNames`（默认空）。`toJson`（`:199`）/`fromJson`（`:157`）加向后兼容读写（缺字段降级空列表，仿 `deletedPublishedAt`）。纳入 `canonicalJson`（`:117`）排序（名字典序）保证"内容相等⇒字节相等"。
2. `collection_sync_engine.dart`：
   - `loadLocalCollectionManifest`（`:446`）构 entry 时 `getTagsForCollection` 填 `tagNames`（取名、排序）。
   - `_mergeOne`（`:144`）双活分支加一处 `tagNames` **并集**裁决（`a ∪ b`）。
   - `applyCollectionLocalChanges`（`:560` 活分支）落盘：`getOrCreateTagByName(name)` → `addTagToCollection`（只增）。
   - `_localMatches`（`:307`）把 `tagNames` 纳入一致性比较，避免每轮空转写库。
3. 编排入口 `syncCollections`（`sync_orchestrator.dart:500`）/ `_syncCollectionsLive`（`:625`）无需改——它们调同一 `merge`/`apply`。

### 5.3 备份合并通道

`backup_merge_engine.dart`：新增 `_mergeCollectionTags()`，仿 `_mergeTagsAndMappings`（`:790`）——src `collection_tag_mappings` 的 `collection_id` 经合集自然键 remap（复用 `_mergeMediaCollections` 的 id 映射，`:381`）、`tag_id` 按标签名 remap，`INSERT OR IGNORE` 去重。在 `merge()` 里 `_mergeMediaCollections` 之后调用（合集 id 映射已建立）。尊重本地合集墓碑（被墓碑拦掉的合集其标签自然也不落）。

## 6. 数据流小结

```
编辑：TagPickerPage(collectionId) → addTagToCollection/removeTagFromCollection → CollectionTagMappings
展示：合集详情页 → getTagsForCollection → HibikiTagChip 行
过滤：selectedTagIdsProvider + getCollectionIdsForAllTags → 合集卡命中判据 → 隐藏/显示
同步(云)：本地 tags → CollectionManifestEntry.tagNames → merge 并集 → getOrCreateTagByName + addTagToCollection
同步(备份)：_mergeCollectionTags 按名并集 + id remap
```

## 7. 测试策略

- **DB 单测**（`hibiki/test/database/`，与 `tags_test.dart` 同目录）：新表 CRUD、级联删除（删合集/删标签自动清 mapping）、`getCollectionIdsForAllTags` AND 语义、v42→v43 迁移不丢数据。
- **同步引擎单测**（`hibiki/test/sync/collection_sync_engine_test.dart` 同目录）：manifest tagNames round-trip、两端并集合并、缺字段向后兼容、`_localMatches` 不空转。
- **备份合并单测**：`_mergeCollectionTags` 按名并集 + 合集自然键 remap + 墓碑拦截。
- **迁移守卫**（`packages/hibiki_core/test/`，仿 `migration_paired_peers_v31_test.dart`）：手写旧 schema 升级到 v43，断言 `user_version == db.schemaVersion` 且旧行零丢失。
- **过滤纯函数测**：合集卡命中选中标签的判据（无交集隐藏、空选不隐藏）。
- **真机验收**（发布前，非本期编码内）：视频合集 + 书架合集打标签、过滤、两台设备同步一致。

## 8. 影响范围与风险

- **零破坏**：纯加表 + 加 additive 同步字段，旧设备读新清单忽略 `tagNames`，新设备读旧清单降级空。schema 只升不降。
- **build_runner**：改 tables.dart 后必须重生成 `database.g.dart`（该文件含 NUL 字节，是 git-binary，勿手改）。
- **DAO 文件 database.dart 也是 git-binary**：编辑走正常 Dart 方法追加，注意别破坏二进制段。
- **过滤性能**：`getCollectionIdsForAllTags` 一次性拉全量映射，合集数量级小（几十到几百），可接受；随 `allTagsProvider` 失效重取。
- **CLAUDE.md 过时**：`packages/hibiki_core/CLAUDE.md` 仍写"28 表/schema 28"，实际 schema 42→本期改 43；顺手不改它（超范围），但实现时表数 +1。
