import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

/// TODO-2484 守卫：合集「相关作品」边表（schema v66）。
///
/// 覆盖：迁移（fresh v66 / 真 v64→v66）、CRUD（整体替换 + 排序 + 升级绑定 +
/// 按 subject 反查）、FK 行为（删合集 cascade 清边 / 删目标合集 setNull 退回
/// 纯刮削态）、同合集同源同条目唯一键。
void main() {
  /// 必须显式开 `foreign_keys`：`NativeDatabase.memory()` 默认关闭外键，而生产
  /// 路径在 `applyPragmas` 里开。不开的话 cascade / setNull 用例会「通过得毫无
  /// 意义」——它们测的正是 FK 行为本身。
  Future<FushiDatabase> openDb() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase rawDb) =>
            rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(db.close);
    return db;
  }

  CollectionRelationsCompanion relation(
    int collectionId, {
    String relationType = 'sequel',
    int sortIndex = 0,
    int? targetCollectionId,
    String source = 'bangumi',
    String subjectId = '200',
    String title = '続・作品',
    String? coverUrl,
  }) =>
      CollectionRelationsCompanion.insert(
        collectionId: collectionId,
        relationType: relationType,
        sortIndex: Value<int>(sortIndex),
        targetCollectionId: Value<int?>(targetCollectionId),
        source: source,
        subjectId: subjectId,
        title: title,
        coverUrl: Value<String?>(coverUrl),
      );

  group('schema v66 migration', () {
    test(
        'fresh DB (v66) has collection_relations table and '
        'video_scrape_meta.episode_number column', () async {
      final FushiDatabase db = await openDb();
      expect(db.schemaVersion, 141);
      final List<QueryRow> tables = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='collection_relations'")
          .get();
      expect(tables, hasLength(1),
          reason: 'fresh createAll must include v66 collection_relations');
      final List<QueryRow> columns =
          await db.customSelect('PRAGMA table_info(video_scrape_meta)').get();
      expect(
        columns.map((QueryRow r) => r.read<String>('name')),
        contains('episode_number'),
        reason: 'fresh createAll must include v66 episode_number column',
      );
    });
  });

  group('CRUD', () {
    test(
        'replaceCollectionRelations swaps whole edge set and orders by '
        'sortIndex', () async {
      final FushiDatabase db = await openDb();
      final int id = await db.createMediaCollection('本篇');
      await db.replaceCollectionRelations(id, <CollectionRelationsCompanion>[
        relation(id, subjectId: '2', title: 'B', sortIndex: 1),
        relation(id,
            subjectId: '1', title: 'A', sortIndex: 0, relationType: 'prequel'),
      ]);
      final List<CollectionRelationRow> first =
          await db.getCollectionRelations(id);
      expect(first.map((CollectionRelationRow r) => r.title).toList(),
          <String>['A', 'B'],
          reason: '读取按 sortIndex 升序');

      // 第二轮替换：上一轮的边必须整体消失（源撤销的关联不能残留）。
      await db.replaceCollectionRelations(id, <CollectionRelationsCompanion>[
        relation(id, subjectId: '3', title: 'C'),
      ]);
      final List<CollectionRelationRow> second =
          await db.getCollectionRelations(id);
      expect(second, hasLength(1));
      expect(second.single.title, 'C');
      expect(second.single.relationType, 'sequel');
    });

    test(
        'bindCollectionRelationTarget upgrades scrape-only edge to local '
        'binding and back', () async {
      final FushiDatabase db = await openDb();
      final int id = await db.createMediaCollection('本篇');
      final int target = await db.createMediaCollection('续篇');
      await db.replaceCollectionRelations(
          id, <CollectionRelationsCompanion>[relation(id)]);
      final CollectionRelationRow edge =
          (await db.getCollectionRelations(id)).single;
      expect(edge.targetCollectionId, isNull, reason: '初始为纯刮削态');

      await db.bindCollectionRelationTarget(edge.id, target);
      expect((await db.getCollectionRelations(id)).single.targetCollectionId,
          target);

      await db.bindCollectionRelationTarget(edge.id, null);
      expect((await db.getCollectionRelations(id)).single.targetCollectionId,
          isNull,
          reason: '传 null 解绑退回纯刮削态');
    });

    test(
        'collectionIdsByScrapeSubject finds collections scraped from the '
        'same subject', () async {
      final FushiDatabase db = await openDb();
      final int a = await db.createMediaCollection('A');
      final int b = await db.createMediaCollection('B');
      await db.upsertCollectionScrapeMeta(CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(a),
        source: 'bangumi',
        subjectId: '900',
        title: 'A 作品',
        scrapedAt: DateTime(2026),
      ));
      expect(await db.collectionIdsByScrapeSubject('bangumi', '900'), <int>[a]);
      expect(await db.collectionIdsByScrapeSubject('tmdb', '900'), isEmpty,
          reason: '不同源不算同条目');
      expect(await db.collectionIdsByScrapeSubject('bangumi', '901'), isEmpty);
      expect(b, isNot(a));
    });

    test(
        'unique key (collectionId, source, subjectId) rejects duplicate '
        'edges', () async {
      final FushiDatabase db = await openDb();
      final int id = await db.createMediaCollection('本篇');
      await db.replaceCollectionRelations(
          id, <CollectionRelationsCompanion>[relation(id)]);
      await expectLater(
        db.replaceCollectionRelations(id, <CollectionRelationsCompanion>[
          relation(id, title: '第一条'),
          relation(id, title: '重复 subject'),
        ]),
        throwsA(anything),
        reason: '同合集同源同 subjectId 第二条必须被唯一键拒绝',
      );
    });
  });

  group('foreign keys', () {
    test('deleting the collection cascades its relation edges', () async {
      final FushiDatabase db = await openDb();
      final int id = await db.createMediaCollection('本篇');
      await db.replaceCollectionRelations(
          id, <CollectionRelationsCompanion>[relation(id)]);
      expect(await db.getCollectionRelations(id), hasLength(1));

      await db.deleteMediaCollectionRaw(id);
      final QueryRow count = await db
          .customSelect('SELECT COUNT(*) AS c FROM collection_relations')
          .getSingle();
      expect(count.read<int>('c'), 0, reason: '删合集必须 cascade 清掉它的全部关系边');
    });

    test(
        'deleting the bound target collection nulls targetCollectionId '
        '(back to scrape-only)', () async {
      final FushiDatabase db = await openDb();
      final int id = await db.createMediaCollection('本篇');
      final int target = await db.createMediaCollection('续篇');
      await db.replaceCollectionRelations(id, <CollectionRelationsCompanion>[
        relation(id, targetCollectionId: target),
      ]);
      expect((await db.getCollectionRelations(id)).single.targetCollectionId,
          target);

      await db.deleteMediaCollectionRaw(target);
      final CollectionRelationRow edge =
          (await db.getCollectionRelations(id)).single;
      expect(edge.targetCollectionId, isNull,
          reason: '删目标合集必须 setNull 退回纯刮削态，而不是连边一起删');
      expect(edge.title, '続・作品', reason: '刮削事实（标题等）保留');
    });
  });
}
