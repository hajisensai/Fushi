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
      expect(db.schemaVersion, 73);
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

    test(
        'real v64->v66 creates collection_relations, adds episode_number, '
        'preserves rows, bumps user_version', () async {
      final FushiDatabase db = await _openV64Db();

      final List<QueryRow> tables = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='collection_relations'")
          .get();
      expect(tables, hasLength(1), reason: 'from<66 分支必须建出新表');

      // 既有行原样保留；episode_number 回填 NULL = 旧作品级资料。
      final MediaCollectionRow? collection = await db.getMediaCollectionById(1);
      expect(collection, isNotNull);
      expect(collection!.name, 'Bocchi the Rock!');
      final VideoScrapeMetaRow? meta = await db.getVideoScrapeMeta('uid-old');
      expect(meta, isNotNull);
      expect(meta!.title, '孤独摇滚！');
      expect(meta.episodeNumber, isNull,
          reason: 'ADD COLUMN 后旧行必须回填 NULL（作品级旧资料语义）');

      // 新表真的可用（不只是建了个壳）。
      await db.replaceCollectionRelations(
          1, <CollectionRelationsCompanion>[relation(1)]);
      expect(await db.getCollectionRelations(1), hasLength(1));

      final QueryRow version =
          await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
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

/// 打开一个 `user_version = 64` 的库：有 media_collections /
/// collection_scrape_meta / video_scrape_meta（v64 shape，无 episode_number）
/// 及其数据，但**没有** collection_relations，强制 FushiDatabase 打开时跑真实
/// 的 `if (from < 66)` 分支。
///
/// from=64 时会先跑 develop 的 v65（Mihon 五表，纯 createTable 无外部依赖），
/// 再跑本表的 v66 分支；seed 只需备齐 v66 分支触碰到的表，不必重建整个 v64
/// schema。
Future<FushiDatabase> _openV64Db() async {
  final FushiDatabase db = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (CommonDatabase rawDb) {
        rawDb.execute('''
CREATE TABLE media_collections (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  collection_type TEXT NOT NULL DEFAULT 'collection',
  cover_source TEXT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  order_updated_at INTEGER NOT NULL DEFAULT 0,
  anilist_id INTEGER NULL,
  audio_track_id TEXT NULL,
  subtitle_delay_ms INTEGER NULL,
  cover_path TEXT NULL
);
''');
        rawDb.execute('''
CREATE TABLE collection_scrape_meta (
  collection_id INTEGER NOT NULL PRIMARY KEY REFERENCES media_collections (id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  title TEXT NOT NULL,
  original_title TEXT NULL,
  summary TEXT NULL,
  air_date TEXT NULL,
  rating REAL NULL,
  rating_count INTEGER NULL,
  episode_count INTEGER NULL,
  tags_json TEXT NULL,
  infobox_json TEXT NULL,
  backdrop_path TEXT NULL,
  detail_url TEXT NULL,
  scraped_at INTEGER NOT NULL
);
''');
        rawDb.execute('''
CREATE TABLE video_scrape_meta (
  book_uid TEXT NOT NULL PRIMARY KEY,
  source TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  title TEXT NOT NULL,
  original_title TEXT NULL,
  summary TEXT NULL,
  air_date TEXT NULL,
  rating REAL NULL,
  rating_count INTEGER NULL,
  episode_count INTEGER NULL,
  tags_json TEXT NULL,
  infobox_json TEXT NULL,
  detail_url TEXT NULL,
  scraped_at INTEGER NOT NULL
);
''');
        rawDb.execute(
          'INSERT INTO media_collections (id, name, collection_type, '
          'sort_order, created_at, order_updated_at) '
          "VALUES (1, 'Bocchi the Rock!', 'playlist', 0, 0, 0)",
        );
        rawDb.execute(
          'INSERT INTO video_scrape_meta (book_uid, source, subject_id, '
          "title, scraped_at) VALUES ('uid-old', 'bangumi', '100', "
          "'孤独摇滚！', 0)",
        );
        rawDb.execute('PRAGMA user_version = 64');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}
