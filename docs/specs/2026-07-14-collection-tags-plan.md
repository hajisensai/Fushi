# 给合集打标签（Collection Tags）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户能给统一合集（`MediaCollections`：collection/playlist）打标签，复用共享 `BookTags` 池，支持按标签过滤合集卡片，并随合集跨端同步（按名并集、只增不删）。

**Architecture:** 新增第 4 张标签关联表 `CollectionTagMappings`（与 `BookTagMappings`/`SrtBookTagMappings`/`VideoBookTagMappings` 同构，schema v42→v43，纯加表无损迁移）。编辑 UI 复用 `TagPickerPage`（加第 4 路分派）。过滤复用 `selectedTagIdsProvider` 派生新 provider。同步把标签名挂进 `CollectionManifestEntry.tagNames`，随合集清单走 `CollectionSyncEngine` 的并集合并；备份合并加一条按名 remap 的 `INSERT`。

**Tech Stack:** Flutter 3.44 / Dart 3.12，Drift（SQLite），Riverpod，Slang i18n。项目 Flutter 工具链见 `hibiki/CLAUDE.md`；本 worktree 分支 `worktree-collection-tags`。

**设计源：** `docs/specs/2026-07-14-collection-tags-design.md`

**通用命令（在 `hibiki/` 目录下）：**
- 生成 Drift 代码：`dart run build_runner build --delete-conflicting-outputs`
- 格式化：`dart format .`
- 分析：`flutter analyze`
- 测试：`flutter test test/<path>`（首次跑 native-assets 见 `docs/agent/`）

---

## Phase 1：数据层（表 + 迁移 + DAO）

### Task 1: 定义 `CollectionTagMappings` 表并接入 DriftDatabase

**Files:**
- Modify: `packages/hibiki_core/lib/src/database/tables.dart`（在 `VideoBookTagMappings` 之后追加，约 :439 后）
- Modify: `packages/hibiki_core/lib/src/database/database.dart`（`@DriftDatabase(tables: [...])` 末尾，约 :375；`schemaVersion` :395；`onUpgrade` ladder 末尾，`if (from < 42)` 块之后，约 :928）
- Regenerate: `packages/hibiki_core/lib/src/database/database.g.dart`（build_runner，勿手改）

- [ ] **Step 1: 在 tables.dart 追加表定义**

在 `VideoBookTagMappings` 表块之后插入：

```dart
// ── collection_tag_mappings ───────────────────────────────────────
// 合集 ↔ 标签 多对多映射。标签定义复用共享的 [BookTags]，与 EPUB
// （[BookTagMappings]）、SRT（[SrtBookTagMappings]）、视频（[VideoBookTagMappings]）
// 共用同一标签池。合集删除 / 标签删除经外键 cascade 自动清理本表。
@DataClassName('CollectionTagMappingRow')
class CollectionTagMappings extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get collectionId => integer()
      .references(MediaCollections, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(BookTags, #id, onDelete: KeyAction.cascade)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {collectionId, tagId},
      ];
}
```

- [ ] **Step 2: 把新表加进 `@DriftDatabase` 注解**

在 `database.dart` 的 `@DriftDatabase(tables: [...])` 列表末尾（`BookCustomCss,` 之后）加一行：

```dart
  BookCustomCss,
  CollectionTagMappings,
])
```

- [ ] **Step 3: bump schemaVersion 42 → 43**

```dart
  @override
  int get schemaVersion => 43;
```

- [ ] **Step 4: 在 onUpgrade ladder 末尾追加 v43 迁移**

紧跟 `if (from < 42) { ... }` 块之后：

```dart
          if (from < 43) {
            // v43（合集打标签）：新表 collection_tag_mappings（collectionId+tagId →
            // 复用 BookTags 标签池的 M:N 关联）。无损迁移：只 createTable，旧库升级后
            // 空表 = sync 零命中 = 行为与旧版一致（Never break userspace）。守卫幂等
            // （fresh DB 已由 onCreate 的 createAll 建好）。
            if (!await _tableExists('collection_tag_mappings')) {
              await m.createTable(collectionTagMappings);
            }
          }
```

- [ ] **Step 5: 重新生成 Drift 代码**

Run（在 `packages/hibiki_core/`）: `dart run build_runner build --delete-conflicting-outputs`
Expected: 成功，`database.g.dart` 出现 `CollectionTagMappings` / `CollectionTagMappingRow` / `CollectionTagMappingsCompanion`，无编译报错。

- [ ] **Step 6: 分析**

Run（在 `hibiki/`）: `flutter analyze`
Expected: No issues（新表未被使用只会是引用告警，DAO 在 Task 2 加）。

- [ ] **Step 7: Commit**

```bash
git add packages/hibiki_core/lib/src/database/tables.dart packages/hibiki_core/lib/src/database/database.dart packages/hibiki_core/lib/src/database/database.g.dart
git commit -m "feat(db): add collection_tag_mappings table (schema v43)"
```

---

### Task 2: 合集标签 DAO（TDD）

**Files:**
- Modify: `packages/hibiki_core/lib/src/database/database.dart`（在 `getTagsForVideoBook` / `removeTagFromVideoBook` 附近，约 :4041 后追加合集标签 DAO）
- Test: `hibiki/test/database/collection_tags_test.dart`（新建，仿 `hibiki/test/database/tags_test.dart`）

- [ ] **Step 1: 写失败测试**

新建 `hibiki/test/database/collection_tags_test.dart`：

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('collection tag mappings', () {
    test('add/get/remove round-trips and dedups', () async {
      final db = await _openDb();
      final int cid =
          await db.createMediaCollection('C1', collectionType: 'collection');
      final int t1 = await db.createTag('日语', 0xFF0000FF);
      final int t2 = await db.createTag('N1', 0xFF00FF00);

      await db.addTagToCollection(cid, t1);
      await db.addTagToCollection(cid, t2);
      await db.addTagToCollection(cid, t1); // 幂等（INSERT OR IGNORE）

      final tags = await db.getTagsForCollection(cid);
      expect(tags.map((t) => t.id).toSet(), {t1, t2});

      await db.removeTagFromCollection(cid, t1);
      final after = await db.getTagsForCollection(cid);
      expect(after.map((t) => t.id).toSet(), {t2});
    });

    test('getCollectionIdsForAllTags is AND-semantics', () async {
      final db = await _openDb();
      final int c1 =
          await db.createMediaCollection('C1', collectionType: 'collection');
      final int c2 =
          await db.createMediaCollection('C2', collectionType: 'playlist');
      final int t1 = await db.createTag('a', 0xFF000001);
      final int t2 = await db.createTag('b', 0xFF000002);
      await db.addTagToCollection(c1, t1);
      await db.addTagToCollection(c1, t2);
      await db.addTagToCollection(c2, t1);

      expect(await db.getCollectionIdsForAllTags({t1}), {c1, c2});
      expect(await db.getCollectionIdsForAllTags({t1, t2}), {c1});
      expect(await db.getCollectionIdsForAllTags({}), <int>{});
    });

    test('deleting collection cascades its tag mappings', () async {
      final db = await _openDb();
      final int cid =
          await db.createMediaCollection('C1', collectionType: 'collection');
      final int t1 = await db.createTag('x', 0xFF000003);
      await db.addTagToCollection(cid, t1);
      await db.deleteMediaCollectionRaw(cid);
      expect(await db.getCollectionIdsForAllTags({t1}), <int>{});
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/database/collection_tags_test.dart`
Expected: FAIL（`getTagsForCollection` / `addTagToCollection` 等方法未定义）。

- [ ] **Step 3: 实现 DAO**

在 `database.dart` 的视频标签 DAO（`removeTagFromVideoBook`，约 :4041）之后追加：

```dart
  // ── 合集标签（复用 BookTags 池；只增不删并集，无墓碑——见 collection-tags 设计 §5）──

  /// 合集当前挂的标签（按 createdAt 升序，与 getTagsForBook 一致）。
  Future<List<BookTagRow>> getTagsForCollection(int collectionId) {
    final query = select(bookTags).join([
      innerJoin(
        collectionTagMappings,
        collectionTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(collectionTagMappings.collectionId.equals(collectionId))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  /// 给合集加标签（INSERT OR IGNORE 幂等；不写墓碑——合集标签同步不消费墓碑）。
  Future<void> addTagToCollection(int collectionId, int tagId) async {
    await into(collectionTagMappings).insert(
      CollectionTagMappingsCompanion.insert(
        collectionId: collectionId,
        tagId: tagId,
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// 从合集移除标签（纯 DELETE，本地生效；同步不传播移除——同书/视频标签现状）。
  Future<void> removeTagFromCollection(int collectionId, int tagId) async {
    await (delete(collectionTagMappings)
          ..where((t) =>
              t.collectionId.equals(collectionId) & t.tagId.equals(tagId)))
        .go();
  }

  /// 含【全部】选中标签的合集 id（AND 语义，仿 getBookKeysForAllTags）。空集返回空。
  Future<Set<int>> getCollectionIdsForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return <int>{};
    final int tagCount = tagIds.length;
    final String placeholders = List.generate(tagCount, (_) => '?').join(',');
    final List<Variable> variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT collection_id FROM collection_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY collection_id '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<int>('collection_id')).toSet();
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/database/collection_tags_test.dart`
Expected: PASS（3 tests）。

- [ ] **Step 5: 格式化 + 分析**

Run: `dart format .` then `flutter analyze`
Expected: 格式化只动本文件；analyze 无新问题。

- [ ] **Step 6: Commit**

```bash
git add packages/hibiki_core/lib/src/database/database.dart hibiki/test/database/collection_tags_test.dart
git commit -m "feat(db): collection tag DAO (get/add/remove/filter)"
```

---

### Task 3: v42→v43 迁移守卫测试（TDD）

**Files:**
- Test: `packages/hibiki_core/test/migration_collection_tags_v43_test.dart`（新建，仿 `migration_paired_peers_v31_test.dart`）

- [ ] **Step 1: 写测试**

参照 `packages/hibiki_core/test/migration_paired_peers_v31_test.dart` 的写法（手写旧 schema + `PRAGMA user_version`，再用真 `HibikiDatabase` 打开触发 onUpgrade）。最小可行版：手写一个只含 `media_collections` + `book_tags` 的 v42 库（或直接复用 paired_peers 测试里的 seed helper 思路），断言升级到 v43 后 `collection_tag_mappings` 表存在且旧行零丢失：

```dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 手写一个 v42 前的最小库（含一张已有合集），user_version 置 42，再用真
/// HibikiDatabase 打开触发 v42→v43 onUpgrade。断言新表建成、旧合集行不丢。
HibikiDatabase _openMigratedFromV42() {
  final raw = NativeDatabase.memory(setup: (db) {
    db.execute('''
      CREATE TABLE media_collections (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        collection_type TEXT NOT NULL DEFAULT 'collection',
        cover_source TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        order_updated_at INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute(
        "INSERT INTO media_collections (name, collection_type, created_at) "
        "VALUES ('Existing', 'collection', 42);");
    db.execute('PRAGMA user_version = 42;');
  });
  return HibikiDatabase.forTesting(raw);
}

void main() {
  test('v42 -> v43 creates collection_tag_mappings, no row loss', () async {
    final HibikiDatabase db = _openMigratedFromV42();
    addTearDown(db.close);

    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'migration must land on current schema version');
    expect(db.schemaVersion, greaterThanOrEqualTo(43));

    // 新表可用（空）。
    final cols = await db.getAllMediaCollections();
    expect(cols.map((c) => c.name), contains('Existing'));
    expect(await db.getCollectionIdsForAllTags(<int>{1}), <int>{});
  });
}
```

> 注意：若 `HibikiDatabase.forTesting` 的 onCreate 对全新内存库会直接 `createAll` 到最新版而不走 onUpgrade，请参照 paired_peers 测试里实际使用的 seed 手法（它已解决同一问题）——以那个文件的真实结构为准，别照抄本骨架的每一行。

- [ ] **Step 2: 跑测试**

Run: `flutter test ../packages/hibiki_core/test/migration_collection_tags_v43_test.dart`（或在 `packages/hibiki_core/` 下 `flutter test test/migration_collection_tags_v43_test.dart`）
Expected: PASS（迁移已在 Task 1 写好；本测试是守卫）。若 FAIL 是 seed 手法与真实迁移不匹配，按上面注意事项对齐 paired_peers 测试。

- [ ] **Step 3: Commit**

```bash
git add packages/hibiki_core/test/migration_collection_tags_v43_test.dart
git commit -m "test(db): guard v42->v43 collection_tag_mappings migration"
```

---

## Phase 2：编辑 UI

### Task 4: `TagPickerPage` 加 `collectionId` 第 4 路分派

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/tag_picker_page.dart`

- [ ] **Step 1: 加构造参数 + assert 扩四选一**

把构造函数与字段改为（保留原三路，加 `collectionId`）：

```dart
  /// 四种目标四选一，共用同一标签池，按非空字段分派：
  /// EPUB 书传 [bookKey]；SRT 书传 [srtBookId] 且 [isSrtBook]=true；视频书传
  /// [videoBookUid]；合集传 [collectionId]（media_collections 主键）。
  const TagPickerPage({
    this.bookKey,
    this.srtBookId,
    this.videoBookUid,
    this.collectionId,
    this.isSrtBook = false,
    super.key,
  }) : assert(
          collectionId != null ||
              videoBookUid != null ||
              (isSrtBook ? srtBookId != null : bookKey != null),
          'one of: collectionId / videoBookUid / srtBookId / bookKey',
        );
  final String? bookKey;
  final int? srtBookId;
  final String? videoBookUid;
  final int? collectionId;
  final bool isSrtBook;
```

- [ ] **Step 2: 分派方法加合集分支（优先判定）**

`_isVideo` getter 下面加：

```dart
  bool get _isCollection => widget.collectionId != null;
```

`_currentTags` / `_addTag` / `_removeTag` 各在**最前**加合集分支：

```dart
  Future<List<BookTagRow>> _currentTags() {
    if (_isCollection) return _db.getTagsForCollection(widget.collectionId!);
    if (_isVideo) return _db.getTagsForVideoBook(widget.videoBookUid!);
    if (widget.isSrtBook) return _db.getTagsForSrtBook(widget.srtBookId!);
    return _db.getTagsForBook(widget.bookKey!);
  }

  Future<void> _addTag(int tagId) {
    if (_isCollection) {
      return _db.addTagToCollection(widget.collectionId!, tagId);
    }
    if (_isVideo) return _db.addTagToVideoBook(widget.videoBookUid!, tagId);
    if (widget.isSrtBook) return _db.addTagToSrtBook(widget.srtBookId!, tagId);
    return _db.addTagToBook(widget.bookKey!, tagId);
  }

  Future<void> _removeTag(int tagId) {
    if (_isCollection) {
      return _db.removeTagFromCollection(widget.collectionId!, tagId);
    }
    if (_isVideo) {
      return _db.removeTagFromVideoBook(widget.videoBookUid!, tagId);
    }
    if (widget.isSrtBook) {
      return _db.removeTagFromSrtBook(widget.srtBookId!, tagId);
    }
    return _db.removeTagFromBook(widget.bookKey!, tagId);
  }
```

- [ ] **Step 3: 分析**

Run: `flutter analyze lib/src/pages/implementations/tag_picker_page.dart`
Expected: No issues。

- [ ] **Step 4: 格式化 + Commit**

```bash
dart format lib/src/pages/implementations/tag_picker_page.dart
git add hibiki/lib/src/pages/implementations/tag_picker_page.dart
git commit -m "feat(tags): TagPickerPage supports collectionId"
```

---

### Task 5: 两个合集详情页加"打标签"入口 + 标签 chip 展示

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/media_collection_detail_page.dart`（AppBar actions :266；加导入 + 一个刷新计数 + chip 行）
- Modify: `hibiki/lib/src/pages/implementations/media_collection_grid_detail_page.dart`（AppBar actions :328；同上）

> 说明：两页 rename/delete 都挂在 AppBar `IconButton`（非菜单）。新入口用 `IconButton(Icons.sell_outlined)` 插在 rename 与 delete 之间。tooltip 复用现有 i18n key `t.tag_label`（"标签"），不新增 i18n key（避免 17 文件 slang 同步）。标签 chip 用 `HibikiTagChip`（`tone: HibikiTagChipTone.surface`）。

- [ ] **Step 1: 加导入**

两个文件顶部确保有：

```dart
import 'package:hibiki/src/pages/implementations/tag_picker_page.dart';
```

（`HibikiTagChip` / `HibikiTagChipTone` 来自 `hibiki_material_components.dart`，通常经 `package:hibiki/utils.dart` barrel 已导入；若 analyze 报未定义再显式加 `import 'package:hibiki/utils.dart';`。）

- [ ] **Step 2: 在 State 里加一个打标签方法 + 刷新计数**

在两页的 `_rename` 方法旁加（`playlist` 页字段名 `widget.collection.id`；grid 页同名）：

```dart
  int _tagsRefresh = 0;

  Future<void> _editTags() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TagPickerPage(collectionId: widget.collection.id),
      ),
    );
    if (!mounted) return;
    setState(() => _tagsRefresh++); // 触发 chip 行 FutureBuilder 重取
  }
```

- [ ] **Step 3: AppBar actions 插入打标签按钮**

两页 `actions: <Widget>[ ... ]` 里，在 rename 与 delete `IconButton` 之间插：

```dart
          IconButton(
            tooltip: t.tag_label,
            icon: const Icon(Icons.sell_outlined),
            onPressed: _editTags,
          ),
```

- [ ] **Step 4: 详情页头部渲染标签 chip 行**

在两页正文顶部（列表/网格之上）插一个随 `_tagsRefresh` 重建的 chip 行。用 `FutureBuilder`：

```dart
  Widget _buildTagChips() {
    return FutureBuilder<List<BookTagRow>>(
      // key 随 _tagsRefresh 变化以强制重取（编辑标签返回后刷新）。
      key: ValueKey<int>(_tagsRefresh),
      future: widget.database.getTagsForCollection(widget.collection.id),
      builder: (context, snap) {
        final List<BookTagRow> tags = snap.data ?? const <BookTagRow>[];
        if (tags.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final BookTagRow tag in tags)
                HibikiTagChip(
                  label: tag.name,
                  color: Color(tag.colorValue),
                  tone: HibikiTagChipTone.surface,
                ),
            ],
          ),
        );
      },
    );
  }
```

把 `_buildTagChips()` 插到各页 body 的合适位置（列表/网格上方，包在现有 `Column`/`CustomScrollView` 结构里——按该页现有布局微调；playlist 页在剧集列表上方，grid 页在网格 sliver 之前用 `SliverToBoxAdapter` 包裹）。

> `HibikiTagChip` 的确切构造参数（`label`/`color`/`tone`）以 `hibiki_material_components.dart:736` 为准；若签名不同按实际调整（该组件已在 `tag_filter_bar.dart:295` 与 `home_video_page.dart` 使用，可参照那两处调用）。

- [ ] **Step 5: 分析 + 编译验证**

Run: `flutter analyze lib/src/pages/implementations/media_collection_detail_page.dart lib/src/pages/implementations/media_collection_grid_detail_page.dart`
Expected: No issues。

- [ ] **Step 6: 格式化 + Commit**

```bash
dart format .
git add hibiki/lib/src/pages/implementations/media_collection_detail_page.dart hibiki/lib/src/pages/implementations/media_collection_grid_detail_page.dart
git commit -m "feat(collections): edit-tags entry + tag chips on detail pages"
```

---

## Phase 3：按标签过滤合集卡片

### Task 6: `filteredCollectionIdsProvider` + 两处消费者过滤合集卡

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/tag_filter_sheet.dart`（在 `filteredVideoBookUidsProvider` :84 后加新 provider）
- Modify: `hibiki/lib/src/pages/implementations/home_video_page.dart`（合集卡组装 `_buildLocalVideoSlivers` ~:1941）
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`（书架合集网格组装处）

- [ ] **Step 1: 加 provider**

在 `tag_filter_sheet.dart` 的 `filteredVideoBookUidsProvider` 之后追加（仿 :13 的 `filteredBookIdsProvider` 形状）：

```dart
/// 含【全部】选中标签的合集 id（无选中标签时 null = 不过滤）。合集卡按此显隐。
final filteredCollectionIdsProvider = FutureProvider<Set<int>?>((ref) async {
  final Set<int> tagIds = ref.watch(selectedTagIdsProvider);
  if (tagIds.isEmpty) return null;
  final db = ref.watch(appProvider).database;
  return db.getCollectionIdsForAllTags(tagIds);
});
```

- [ ] **Step 2: 视频页合集卡应用过滤**

在 `home_video_page.dart` 合集卡组装处（`_buildLocalVideoSlivers`，合集来自本地 `books` 分组后得到的合集 id 列表），读取过滤集并对合集卡显隐判定：

```dart
        final Set<int>? collectionFilter =
            ref.watch(filteredCollectionIdsProvider).valueOrNull;
        bool collectionVisible(int collectionId) =>
            collectionFilter == null || collectionFilter.contains(collectionId);
```

在遍历合集、构造合集卡 sliver/widget 处用 `if (collectionVisible(c.id))` 包裹（`c.id` 为该合集的 `MediaCollectionRow.id`）。空选（`collectionFilter == null`）不隐藏任何合集卡——与既有 `filter == null ? all : ...` 语义一致。

> 具体挂点以该页真实结构为准：合集卡片是从 `getAllMediaCollections()` / 折叠分组得到的合集列表渲染的。找到那段 `for (final collection in ...)` 或 `.map(...)`，在生成卡片前加 `if (!collectionVisible(collection.id)) continue;`（或 `.where((c) => collectionVisible(c.id))`）。

- [ ] **Step 3: 书架页合集网格应用过滤**

在 `reader_hibiki_history_page.dart` 书架合集卡组装处，同样读取 `filteredCollectionIdsProvider` 并 `where((c) => collectionFilter == null || collectionFilter.contains(c.id))` 过滤合集卡列表。挂点与现有 EPUB/SRT/video 过滤（:356 / :960）同一 build 方法内。

- [ ] **Step 4: 分析 + 编译**

Run: `flutter analyze lib/src/pages/implementations/tag_filter_sheet.dart lib/src/pages/implementations/home_video_page.dart lib/src/pages/implementations/reader_hibiki_history_page.dart`
Expected: No issues。

- [ ] **Step 5: 格式化 + Commit**

```bash
dart format .
git add hibiki/lib/src/pages/implementations/tag_filter_sheet.dart hibiki/lib/src/pages/implementations/home_video_page.dart hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart
git commit -m "feat(tags): filter collection cards by selected tags"
```

---

## Phase 4：云盘/互联同步（合集清单携带 tagNames）

> 关键：`tagNames` 必须在 **所有** 引擎触点透传，否则某个环节会静默丢标签。触点清单：
> `CollectionManifestEntry`(字段+codec)、`_NormalizedEntry`(字段+`toEntry`)、`_normalize`、
> `_mergeOne`(双活并集)、`_stampEntry`(重建时透传)、`_FoldGroup.observe`+`resolve`(折叠并集)、
> `loadLocalCollectionManifest`(读)、`applyCollectionLocalChanges`(写)、`_localMatches`(比较)。

### Task 7: `CollectionManifestEntry` 加 `tagNames` 字段 + codec（TDD）

**Files:**
- Modify: `hibiki/lib/src/sync/collection_manifest.dart`
- Test: `hibiki/test/sync/collection_manifest_test.dart`（若已存在则追加 test；否则新建）

- [ ] **Step 1: 写失败测试（round-trip + 向后兼容）**

追加/新建 `hibiki/test/sync/collection_manifest_test.dart`：

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/collection_manifest.dart';

void main() {
  test('tagNames round-trips through toJson/fromJson', () {
    const entry = CollectionManifestEntry(
      name: 'C',
      collectionType: 'collection',
      members: <CollectionManifestMember>[
        CollectionManifestMember(
            mediaType: 'video', entryKey: 'u1', sortIndex: 0),
      ],
      tagNames: <String>['zebra', 'alpha'],
    );
    final decoded = CollectionManifestEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())));
    expect(decoded.tagNames, <String>['alpha', 'zebra']); // 排序确定性
  });

  test('missing tagNames decodes to empty (backward compat)', () {
    final decoded = CollectionManifestEntry.fromJson(<String, dynamic>{
      'name': 'C',
      'collectionType': 'collection',
      'members': <dynamic>[],
      'memberTombstones': <dynamic>[],
    });
    expect(decoded.tagNames, isEmpty);
  });

  test('empty tagNames omits key (byte-identical to pre-feature)', () {
    const entry = CollectionManifestEntry(
        name: 'C', collectionType: 'collection');
    expect(entry.toJson().containsKey('tagNames'), isFalse);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/sync/collection_manifest_test.dart`
Expected: FAIL（`tagNames` 参数不存在）。

- [ ] **Step 3: 加字段 + 构造 + codec**

`CollectionManifestEntry` 构造函数加参数（`memberTombstones` 之后）：

```dart
    this.memberTombstones = const <CollectionMemberTombstone>[],
    this.tagNames = const <String>[],
  });
```

字段区加（`memberTombstones` 字段后）：

```dart
  /// 合集标签（按名跨端传递；BookTags.id 各端不一致故用名）。只增不删并集，
  /// 无墓碑（合集标签同步不消费墓碑，见 collection-tags 设计 §5）。
  final List<String> tagNames;
```

`fromJson`（`memberTombstones` 解析之后、`return` 里）加解析——先在 `return CollectionManifestEntry(...)` 之前无需额外校验（additive 字段，缺/非法降级空）：

```dart
      memberTombstones: <CollectionMemberTombstone>[
        for (final Object? t in rawTombstones)
          CollectionMemberTombstone.fromJson(t),
      ],
      tagNames: json['tagNames'] is List
          ? <String>[
              for (final Object? t in (json['tagNames'] as List))
                if (t is String && t.isNotEmpty) t,
            ]
          : const <String>[],
    );
```

`toJson`（在方法内、`return <String, dynamic>{ ... }` 之前构造排序副本，末尾条件加键）：

```dart
    final List<String> sortedTags = <String>[
      for (final String tn in tagNames) if (tn.isNotEmpty) tn,
    ]..sort();
    return <String, dynamic>{
      'name': name,
      'collectionType': collectionType,
      'orderUpdatedAt': orderUpdatedAt,
      if (deletedAt != null) 'deletedAt': deletedAt,
      if (deletedPublishedAt != null) 'deletedPublishedAt': deletedPublishedAt,
      'members': <Map<String, dynamic>>[
        for (final CollectionManifestMember m in sortedMembers) m.toJson(),
      ],
      'memberTombstones': <Map<String, dynamic>>[
        for (final CollectionMemberTombstone t in sortedTombstones) t.toJson(),
      ],
      if (sortedTags.isNotEmpty) 'tagNames': sortedTags,
    };
```

> `if (sortedTags.isNotEmpty)` 保证无标签合集的 JSON 与加特性前**逐字节相同**（不引入空 `tagNames` 键），维持 `canonicalJson` 幂等。`tagNames` 天然进 `canonicalJson`（它调 `_contentJson` → 每 entry `toJson`）。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/sync/collection_manifest_test.dart`
Expected: PASS。

- [ ] **Step 5: 格式化 + Commit**

```bash
dart format lib/src/sync/collection_manifest.dart test/sync/collection_manifest_test.dart
git add hibiki/lib/src/sync/collection_manifest.dart hibiki/test/sync/collection_manifest_test.dart
git commit -m "feat(sync): CollectionManifestEntry carries tagNames"
```

---

### Task 8: `CollectionSyncEngine` 全触点透传 + 双活并集（TDD）

**Files:**
- Modify: `hibiki/lib/src/sync/collection_sync_engine.dart`
- Test: `hibiki/test/sync/collection_sync_engine_test.dart`（追加 test）

- [ ] **Step 1: 写失败测试（两端标签并集）**

在 `hibiki/test/sync/collection_sync_engine_test.dart` 追加（用文件里已有的 `_Cloud`/`_Device` 或 `CollectionSyncEngine.merge` 直接调用范式——以该文件真实 helper 为准）：

```dart
  test('tagNames union across two devices (add-only)', () {
    const local = CollectionManifest(collections: <CollectionManifestEntry>[
      CollectionManifestEntry(
        name: 'C',
        collectionType: 'collection',
        members: <CollectionManifestMember>[
          CollectionManifestMember(
              mediaType: 'video', entryKey: 'u1', sortIndex: 0),
        ],
        tagNames: <String>['a'],
      ),
    ]);
    const remote = CollectionManifest(collections: <CollectionManifestEntry>[
      CollectionManifestEntry(
        name: 'C',
        collectionType: 'collection',
        members: <CollectionManifestMember>[
          CollectionManifestMember(
              mediaType: 'video', entryKey: 'u1', sortIndex: 0),
        ],
        tagNames: <String>['b'],
      ),
    ]);
    final out = CollectionSyncEngine.merge(
      local: local,
      remote: remote,
      lastSyncedAtMs: 0,
      nowMs: 1000,
    );
    final merged = out.merged.collections.single;
    expect(merged.tagNames, <String>['a', 'b']);
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/sync/collection_sync_engine_test.dart -n 'tagNames union'`
Expected: FAIL（合并结果 `tagNames` 为空——引擎尚未透传）。

- [ ] **Step 3: `_NormalizedEntry` 加 tagNames + toEntry 透传**

字段区加（`tombstones` 后）：

```dart
  /// 合集标签名集合（只增不删并集载荷）。
  final Set<String> tagNames;
```

构造函数加 `required this.tagNames,`。`toEntry()` 的 `CollectionManifestEntry(...)` 末尾加：

```dart
        memberTombstones: <CollectionMemberTombstone>[ ... ],
        tagNames: tagNames.toList()..sort(),
      );
```

- [ ] **Step 4: `_normalize` 填 tagNames**

死条目分支的 `_NormalizedEntry(...)` 加 `tagNames: const <String>{},`；活条目分支加 `tagNames: e.tagNames.toSet(),`。

- [ ] **Step 5: `_mergeOne` 双活并集**

在双活分支 `return _prune(CollectionManifestEntry(...))` 处加：

```dart
    return _prune(CollectionManifestEntry(
      name: l.name,
      collectionType: l.collectionType,
      orderUpdatedAt: mergedOrderUpdatedAt,
      members: _reindexed(orderedAlive),
      memberTombstones: <CollectionMemberTombstone>[ ... ],
      tagNames: <String>{...l.tagNames, ...r.tagNames}.toList()..sort(),
    ));
```

（单侧分支 `l.toEntry()`/`r.toEntry()` 已透传；死条目 `_deadEntry` 不带标签——合集已删，标签无意义，正确。）

- [ ] **Step 6: `_stampEntry` 重建时透传 tagNames**

`_stampEntry` 里 `return CollectionManifestEntry(...)` 加 `tagNames: e.tagNames,`（该方法重建整个 entry，漏了会在盖发布戳时丢标签）：

```dart
    return CollectionManifestEntry(
      name: e.name,
      collectionType: e.collectionType,
      orderUpdatedAt: e.orderUpdatedAt,
      deletedAt: e.deletedAt,
      deletedPublishedAt: ...,
      members: e.members,
      memberTombstones: <CollectionMemberTombstone>[ ... ],
      tagNames: e.tagNames,
    );
```

- [ ] **Step 7: `_FoldGroup` 折叠 tagNames 并集**

`_FoldGroup` 加字段 `final Set<String> _tagNames = <String>{};`。`observe` 的活分支（`e.deletedAt == null` 路径，`if (fileTime > _aliveFileTimeMax)` 附近）加：

```dart
    _tagNames.addAll(e.tagNames);
```

`resolve()` 的活条目 `return CollectionSyncEngine._prune(CollectionManifestEntry(...))` 加：

```dart
      memberTombstones: <CollectionMemberTombstone>[ ... ],
      tagNames: _tagNames.toList()..sort(),
    ));
```

- [ ] **Step 8: `_localMatches` 比较 tagNames**

`_localMatches` 在成员/墓碑一致判定之后、`return true` 之前加标签集合比较（本地一无所知或合并要求更多标签 ⇒ 不一致 ⇒ 触发落盘）：

```dart
    // 标签集合一致？（合并只增不删，本地 ⊊ 合并 ⇒ 需落盘物化新标签）
    final Set<String> localTags = l.tagNames;
    if (localTags.length != m.tagNames.length) return false;
    for (final String tn in m.tagNames) {
      if (!localTags.contains(tn)) return false;
    }
```

- [ ] **Step 9: 跑测试确认通过**

Run: `flutter test test/sync/collection_sync_engine_test.dart`
Expected: PASS（新增 union 测试 + 原有全部 test 不回归）。

- [ ] **Step 10: 格式化 + 分析 + Commit**

```bash
dart format lib/src/sync/collection_sync_engine.dart test/sync/collection_sync_engine_test.dart
flutter analyze lib/src/sync/collection_sync_engine.dart
git add hibiki/lib/src/sync/collection_sync_engine.dart hibiki/test/sync/collection_sync_engine_test.dart
git commit -m "feat(sync): CollectionSyncEngine merges tagNames (union) across all touchpoints"
```

---

### Task 9: DB ↔ 清单物化（load 读标签 / apply 写标签）（TDD）

**Files:**
- Modify: `hibiki/lib/src/sync/collection_sync_engine.dart`（`loadLocalCollectionManifest` + `applyCollectionLocalChanges`）
- Test: `hibiki/test/sync/collection_sync_engine_test.dart`（追加 DB round-trip test，需真 `HibikiDatabase`）

- [ ] **Step 1: 写失败测试（本地 DB 标签进清单、清单标签落 DB）**

追加（用真 in-memory DB）：

```dart
  test('load reads collection tags; apply materializes them', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int cid =
        await db.createMediaCollection('C', collectionType: 'collection');
    await db.addToCollection(cid, 'video', 'u1');
    final int t = await db.createTag('日语', 0xFF0000FF);
    await db.addTagToCollection(cid, t);

    final manifest = await loadLocalCollectionManifest(db);
    expect(manifest.collections.single.tagNames, <String>['日语']);

    // 反向：清单里带一个本地没有的标签，apply 应物化到 DB。
    final db2 = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    final int cid2 =
        await db2.createMediaCollection('C', collectionType: 'collection');
    await db2.addToCollection(cid2, 'video', 'u1');
    await applyCollectionLocalChanges(
      db2,
      const CollectionLocalChanges(<CollectionManifestEntry>[
        CollectionManifestEntry(
          name: 'C',
          collectionType: 'collection',
          members: <CollectionManifestMember>[
            CollectionManifestMember(
                mediaType: 'video', entryKey: 'u1', sortIndex: 0),
          ],
          tagNames: <String>['N1'],
        ),
      ]),
    );
    final tags = await db2.getTagsForCollection(cid2);
    expect(tags.map((t) => t.name), contains('N1'));
  });
```

（import `package:drift/native.dart` + `package:hibiki_core/hibiki_core.dart` 若测试文件顶部还没有。）

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/sync/collection_sync_engine_test.dart -n 'materializes'`
Expected: FAIL（load 不读标签 / apply 不写标签）。

- [ ] **Step 3: `loadLocalCollectionManifest` 读标签**

活合集 entry 构造处（约 :487，`for (final MediaCollectionRow row in byId)` 循环里，`getCollectionItems` 之后）加读取标签：

```dart
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(row.id);
    final List<BookTagRow> rowTags = await db.getTagsForCollection(row.id);
    entries.add(CollectionManifestEntry(
      name: row.name,
      collectionType: row.collectionType,
      orderUpdatedAt: row.orderUpdatedAt,
      members: <CollectionManifestMember>[ ... ],
      memberTombstones: <CollectionMemberTombstone>[ ... ],
      tagNames: <String>[for (final BookTagRow t in rowTags) t.name],
    ));
```

（tombOnly 死壳/活壳无对应合集行 → 无标签，保持不带 `tagNames`。）

- [ ] **Step 4: `applyCollectionLocalChanges` 写标签（只增）**

在活分支「成员非空 → upsert 成员 + setCollectionOrderUpdatedAt」之后（`else` 块内，`await db.setCollectionOrderUpdatedAt(id, e.orderUpdatedAt);` 之后）加标签物化：

```dart
        await db.setCollectionOrderUpdatedAt(id, e.orderUpdatedAt);
        // 合集标签只增不删（同步语义）：按名 getOrCreate + addTagToCollection。
        for (final String tagName in e.tagNames) {
          if (tagName.isEmpty) continue;
          final int tagId = await db.getOrCreateTagByName(tagName);
          await db.addTagToCollection(id, tagId);
        }
```

（死条目 / 活壳自删分支不落标签——合集不存在。）

- [ ] **Step 5: 跑测试确认通过**

Run: `flutter test test/sync/collection_sync_engine_test.dart`
Expected: PASS（全绿）。

- [ ] **Step 6: 分析（确认 `BookTagRow` 已由 hibiki_core 导入）+ 格式化 + Commit**

```bash
flutter analyze lib/src/sync/collection_sync_engine.dart
dart format lib/src/sync/collection_sync_engine.dart test/sync/collection_sync_engine_test.dart
git add hibiki/lib/src/sync/collection_sync_engine.dart hibiki/test/sync/collection_sync_engine_test.dart
git commit -m "feat(sync): materialize collection tags between DB and manifest"
```

> 编排层（`sync_orchestrator.dart` `syncCollections` / `_syncCollectionsLive`）**无需改**——它们调同一 `loadLocalCollectionManifest` / `merge` / `applyCollectionLocalChanges`，标签自动随流。

---

## Phase 5：备份合并

### Task 10: `_mergeCollectionTags` 按名并集 + 合集自然键 remap（TDD）

**Files:**
- Modify: `hibiki/lib/src/sync/backup_merge_engine.dart`（加方法 + 在 `merge()` 里 `_mergeMediaCollections()`（:140）之后、`_mergeTagsAndMappings()`（:153）附近调用）
- Test: `hibiki/test/sync/backup_merge_engine_test.dart`（若存在则追加；否则参照现有 backup 合并测试结构新建）

- [ ] **Step 1: 写失败测试**

在现有 backup 合并测试（找 `backup_merge_engine` 相关测试文件的两库 attach 范式）里追加一个：src 库有「合集 C + 标签 T + 映射」，target 库有同名合集 C，合并后 target 的 C 应挂上标签 T。以现有测试的 `_srcAlias` attach / seed helper 为准写 seed。断言：

```dart
    // merge 后
    final tags = await targetDb.getTagsForCollection(targetCollectionId);
    expect(tags.map((t) => t.name), contains('日语'));
```

> 若仓库没有现成 backup_merge 两库测试骨架可复用，本 task 的自动化测试可降级为「在 Task 9 的同步引擎测试已覆盖并集语义」+ 手动 backup 导入真机验证；但优先按现有 backup 测试范式补齐。定夺前先 grep `test/sync/` 下 backup 相关测试文件确认范式。

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/sync/backup_merge_engine_test.dart -n 'collection tag'`
Expected: FAIL。

- [ ] **Step 3: 实现 `_mergeCollectionTags`**

在 `backup_merge_engine.dart` 加（仿 `_mergeTagsAndMappings` :790，用 JOIN 同时 remap 合集自然键 + 标签名）：

```dart
  /// 合集标签映射 UNION by (合集自然键 + 标签名)。src 的 collection_id 经
  /// media_collections (name, collection_type) 自然键映射到 target id，tag_id 经
  /// book_tags.name 映射。JOIN 不命中（被删除墓碑跳过、target 无同名合集）的行天然
  /// 不插入——tombstone 尊重是 JOIN 的副产品。owner 合集与 book_tags 须已合并。
  Future<void> _mergeCollectionTags() async {
    if (!await _srcTableExists('collection_tag_mappings')) return; // 旧备份无此表
    await _db.customStatement(
      'INSERT INTO collection_tag_mappings (collection_id, tag_id) '
      'SELECT tc.id, tt.id '
      'FROM $_srcAlias.collection_tag_mappings AS sm '
      'JOIN $_srcAlias.media_collections AS sc ON sc.id = sm.collection_id '
      'JOIN media_collections AS tc '
      'ON tc.name = sc.name AND tc.collection_type = sc.collection_type '
      'JOIN $_srcAlias.book_tags AS st ON st.id = sm.tag_id '
      'JOIN book_tags AS tt ON tt.name = st.name '
      'WHERE NOT EXISTS (SELECT 1 FROM collection_tag_mappings AS m '
      'WHERE m.collection_id = tc.id AND m.tag_id = tt.id)',
    );
  }
```

> `_srcTableExists` 是该文件已有的私有守卫（与 `_tableExists` 对称，查 `$_srcAlias.sqlite_master`）。若确切名不同，用文件里现有的 src 表存在性检查方法。

- [ ] **Step 4: 在 `merge()` 里调用**

在 `_mergeTagsAndMappings()` 调用（:153）之后加一行（此时 `_mergeMediaCollections` 已建好目标合集、`_mergeTagsAndMappings` 已把 book_tags 池并齐，两个 JOIN 前置条件都满足）：

```dart
    await _mergeTagsAndMappings();
    await _mergeCollectionTags();
```

- [ ] **Step 5: 跑测试确认通过**

Run: `flutter test test/sync/backup_merge_engine_test.dart`
Expected: PASS。

- [ ] **Step 6: 格式化 + 分析 + Commit**

```bash
dart format lib/src/sync/backup_merge_engine.dart test/sync/backup_merge_engine_test.dart
flutter analyze lib/src/sync/backup_merge_engine.dart
git add hibiki/lib/src/sync/backup_merge_engine.dart hibiki/test/sync/backup_merge_engine_test.dart
git commit -m "feat(sync): backup merge unions collection tags by natural key"
```

---

## Phase 6：全量验证

### Task 11: 全量分析 + 测试 + bump 版本

**Files:**
- Modify: `hibiki/pubspec.yaml`（`+build` 单调 +1，按 `docs/agent/build.md`）

- [ ] **Step 1: 全量格式化 + 分析（CI 把 warning 当致命）**

Run（在 `hibiki/`）: `dart format .` then `flutter analyze`
Expected: No issues found（含 test 目录）。

- [ ] **Step 2: 跑相关测试子集**

Run:
```
flutter test test/database/collection_tags_test.dart test/sync/collection_manifest_test.dart test/sync/collection_sync_engine_test.dart test/sync/backup_merge_engine_test.dart
flutter test ../packages/hibiki_core/test/migration_collection_tags_v43_test.dart
```
Expected: 全 PASS。

- [ ] **Step 3: bump +build**

`hibiki/pubspec.yaml` 的 `version:` 行 `+build` 号 +1（语义版本按里程碑，通常本特性只 +build；按 `docs/agent/build.md` 规则判断是否升 patch/minor）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/pubspec.yaml
git commit -m "chore: bump build for collection tags"
```

- [ ] **Step 5: 推分支 + 开草稿 PR**

```bash
git push -u origin worktree-collection-tags
gh pr create --draft --title "feat: 给合集打标签（Collection Tags）" --body "见 docs/specs/2026-07-14-collection-tags-{design,plan}.md。DB v43 加表 + TagPickerPage 第4路 + 合集卡过滤 + 随合集清单/备份并集同步。待真机验收：视频/书架合集打标签、过滤、两端同步一致。"
```

---

## 真机验收清单（发布前，非本计划编码内）

按 `hibiki/CLAUDE.md` 焦点驱动集成测试：
1. 视频 tab 打开一个合集 → 打标签按钮 → 勾选标签 → 返回，chip 行显示；重进详情页标签仍在（穿 DB）。
2. 书架合集详情页同样打标签。
3. 标签栏选中该标签 → 合集卡按标签显隐（视频 tab + 书架都验）。
4. 两台设备：A 给合集打标签 → 同步 → B 出现同名标签（云盘 + 备份导入各验一次）。
5. 回归：给普通书/视频打标签、过滤仍正常（未破坏现有标签路径）。

## 自检（写计划后对照 spec）

- **Spec 覆盖**：§2 数据层→Task 1-3；§3 编辑 UI→Task 4-5；§4 过滤→Task 6；§5.2 云同步→Task 7-9；§5.3 备份→Task 10；§7 测试策略→各 task 内 TDD + Task 11。无遗漏。
- **占位符**：无 TODO/TBD；每个改动都给了真实代码块或明确的「以现有文件真实结构为准」的对齐指令（涉及大文件既有结构处）。
- **类型一致**：DAO 名 `getTagsForCollection`/`addTagToCollection`/`removeTagFromCollection`/`getCollectionIdsForAllTags`、字段 `tagNames`、provider `filteredCollectionIdsProvider` 全计划统一。
