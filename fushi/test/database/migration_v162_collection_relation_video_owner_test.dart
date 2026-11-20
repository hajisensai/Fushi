import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v162：`collection_relations` 的起点与已绑定目标可以是单视频（挂在单个视频上的
/// 作品，散装电影）。`collection_id` 放宽为可空、加 `book_uid` / `target_book_uid`
/// 与两条 CHECK、补第二条唯一键——只能重建表。升级后存量行（id 与各列）原样、新两列
/// NULL，原有外键语义（删合集 cascade、目标合集被删 setNull）不变；新列的外键：删
/// 视频连带清它起点的边、目标视频被删退回纯刮削态。已是新 shape 的表幂等跳过。
void main() {
  const String v161Table =
      'CREATE TABLE "collection_relations" ('
      '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      '"collection_id" INTEGER NOT NULL REFERENCES media_collections (id) '
      'ON DELETE CASCADE, '
      '"relation_type" TEXT NOT NULL, '
      '"sort_index" INTEGER NOT NULL DEFAULT 0, '
      '"target_collection_id" INTEGER NULL REFERENCES media_collections (id) '
      'ON DELETE SET NULL, '
      '"source" TEXT NOT NULL, "subject_id" TEXT NOT NULL, '
      '"title" TEXT NOT NULL, "cover_url" TEXT NULL, "cover_path" TEXT NULL, '
      'UNIQUE ("collection_id", "source", "subject_id"))';

  /// 建一个 v162 库，造两个合集 + 两个视频，返回 (路径, 合集 a, 合集 b)。
  Future<(String, int, int)> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    final int a = await original.createMediaCollection(
      'A',
      collectionType: 'playlist',
    );
    final int b = await original.createMediaCollection(
      'B',
      collectionType: 'playlist',
    );
    for (final String uid in <String>['m1', 'm2']) {
      await original.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(uid),
          videoPath: Value<String>('D:/$uid.mkv'),
        ),
      );
    }
    await original.close();
    return (path, a, b);
  }

  test('v161 → v162：重建表，存量行原样，单视频起点 / 目标可写且外键语义对', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'collectionrelationsv162',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final (String path, int a, int b) = await createDbAt(directory);

    // 退回 v161 形状并写两条存量行（一条已绑定、一条纯刮削）。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE collection_relations');
    raw.execute(v161Table);
    raw.execute(
      'INSERT INTO collection_relations (id, collection_id, relation_type, '
      'sort_index, target_collection_id, source, subject_id, title, cover_url, '
      "cover_path) VALUES (41, $a, 'sequel', 0, $b, 'anidb', '200', '2 期', "
      "'https://x/c.jpg', 'D:/covers/c.jpg')",
    );
    raw.execute(
      'INSERT INTO collection_relations (id, collection_id, relation_type, '
      'sort_index, target_collection_id, source, subject_id, title) VALUES '
      "(42, $a, 'side_story', 1, NULL, 'anidb', '300', '外传')",
    );
    raw.execute('PRAGMA user_version = 161');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 166);
    final List<CollectionRelationRow> before = await migrated
        .getCollectionRelations(a);
    expect(before.map((CollectionRelationRow r) => r.id), <int>[41, 42]);
    final CollectionRelationRow bound = before.first;
    expect(bound.collectionId, a);
    expect(bound.relationType, 'sequel');
    expect(bound.targetCollectionId, b);
    expect(bound.title, '2 期');
    expect(bound.coverUrl, 'https://x/c.jpg');
    expect(bound.coverPath, 'D:/covers/c.jpg');
    expect(bound.bookUid, isNull);
    expect(bound.targetBookUid, isNull);
    expect(before.last.targetCollectionId, isNull);

    // 单视频起点（m1 → 合集 a）与单视频目标（a → m2）。
    await migrated.replaceSourceVideoBookRelations(
      'm1',
      'anidb',
      <CollectionRelationsCompanion>[
        CollectionRelationsCompanion.insert(
          bookUid: const Value<String?>('m1'),
          relationType: 'other',
          targetCollectionId: Value<int?>(a),
          source: 'anidb',
          subjectId: '100',
          title: 'Show',
        ),
      ],
    );
    expect(
      await migrated.bindCollectionRelationsBySubjectToVideo(
        'anidb',
        '300',
        'm2',
      ),
      1,
    );

    // CHECK：起点二选一、目标至多一个；第二条唯一键约束单视频起点。
    await expectLater(
      migrated.customStatement(
        'INSERT INTO collection_relations (relation_type, source, subject_id, '
        "title) VALUES ('other', 'anidb', '1', 'no owner')",
      ),
      throwsA(anything),
    );
    await expectLater(
      migrated.customStatement(
        'INSERT INTO collection_relations (collection_id, book_uid, '
        'relation_type, source, subject_id, title) VALUES '
        "($a, 'm1', 'other', 'anidb', '2', 'two owners')",
      ),
      throwsA(anything),
    );
    await expectLater(
      migrated.customStatement(
        'INSERT INTO collection_relations (collection_id, relation_type, '
        'target_collection_id, target_book_uid, source, subject_id, title) '
        "VALUES ($a, 'other', $b, 'm2', 'anidb', '3', 'two targets')",
      ),
      throwsA(anything),
    );
    await expectLater(
      migrated.customStatement(
        'INSERT INTO collection_relations (book_uid, relation_type, source, '
        "subject_id, title) VALUES ('m1', 'other', 'anidb', '100', 'dup')",
      ),
      throwsA(anything),
    );

    // 外键：目标视频被删 → 退回纯刮削态；删起点视频 → 它的边 cascade。
    await migrated.deleteVideoBook('m2');
    final CollectionRelationRow side = (await migrated.getCollectionRelations(
      a,
    )).singleWhere((CollectionRelationRow r) => r.id == 42);
    expect(side.targetBookUid, isNull);
    await migrated.deleteVideoBook('m1');
    expect(await migrated.getVideoBookRelations('m1'), isEmpty);
    // 原有语义：目标合集被删 setNull，起点合集被删 cascade。
    await migrated.deleteMediaCollection(b);
    expect(
      (await migrated.getCollectionRelations(a)).first.targetCollectionId,
      isNull,
    );
    await migrated.deleteMediaCollection(a);
    expect(await migrated.getAllCollectionRelations(), isEmpty);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 166);
    final String sql =
        probe
                .select(
                  "SELECT sql FROM sqlite_master WHERE type = 'table' "
                  "AND name = 'collection_relations'",
                )
                .single['sql']
            as String;
    expect(sql, contains('book_uid'));
    expect(sql, contains('target_book_uid'));
  });

  test('v162 步幂等：表已是新 shape 时不重建，单视频起点的行原样', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'collectionrelationsv162idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final (String path, int a, int _) = await createDbAt(directory);
    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.replaceSourceVideoBookRelations(
      'm1',
      'tmdb',
      <CollectionRelationsCompanion>[
        CollectionRelationsCompanion.insert(
          bookUid: const Value<String?>('m1'),
          relationType: 'sequel',
          targetCollectionId: Value<int?>(a),
          source: 'tmdb',
          subjectId: '12',
          title: 'Part 2',
        ),
      ],
    );
    final int id = (await seeded.getVideoBookRelations('m1')).single.id;
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 161');
    raw.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(reopened.close);
    final CollectionRelationRow row = (await reopened.getVideoBookRelations(
      'm1',
    )).single;
    expect(row.id, id);
    expect(row.collectionId, isNull);
    expect(row.targetCollectionId, a);
    expect(row.source, 'tmdb');
  });
}
