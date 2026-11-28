// BUG-5461 / BUG-5462：合集身份快照（删前记下、按原 id 还原）与删合集清掉以它为端点的
// 作品图谱连接。真 Drift 内存库，开外键（cascade 与生产一致）。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(db.close);
  return db;
}

MediaLinkEndpoint _collection(int id) =>
    (kind: MediaLinkKind.videoCollection, key: '$id');

MediaLinkEndpoint _book(String key) => (kind: MediaLinkKind.book, key: key);

Future<List<MediaLinkRow>> _linksOf(FushiDatabase db, int collectionId) =>
    db.mediaLinksForEndpoint(
      MediaLinkKind.videoCollection,
      '$collectionId',
      includeRemoved: true,
    );

/// 一个挂满了「按 id 认人」数据的视频合集：成员、AniList id、标签、刮削资料、
/// 系列关系（自己发出的 + 别的合集指向它的）、两条作品图谱连接（两个方向）。
Future<({int id, int other, int tagId})> _seed(FushiDatabase db) async {
  final int id = await db.createMediaCollection(
    'Horimiya',
    collectionType: 'playlist',
    origin: CollectionOrigin.ai,
    organizeKey: 'anilist:1',
  );
  await db.addToCollectionRaw(id, 'video', 'ep1', userIntent: false);
  await db.addToCollectionRaw(id, 'video', 'ep2', userIntent: false);
  await db.setMediaCollectionAnilistId(id, 124080);
  final int tagId = await db.getOrCreateTagByName('fav');
  await db.addTagToCollection(id, tagId);
  await db.upsertCollectionScrapeMeta(
    CollectionScrapeMetaCompanion.insert(
      collectionId: Value<int>(id),
      source: 'anilist',
      subjectId: '124080',
      title: 'Horimiya',
      scrapedAt: DateTime.utc(2026),
    ),
  );
  final int other = await db.createMediaCollection(
    'Horimiya S2',
    collectionType: 'playlist',
  );
  await db.addToCollectionRaw(other, 'video', 'x1', userIntent: false);
  await db.replaceCollectionRelations(id, <CollectionRelationsCompanion>[
    CollectionRelationsCompanion.insert(
      collectionId: Value<int?>(id),
      relationType: 'sequel',
      source: 'anilist',
      subjectId: '163132',
      title: 'Horimiya: piece',
    ),
  ]);
  await db.replaceCollectionRelations(other, <CollectionRelationsCompanion>[
    CollectionRelationsCompanion.insert(
      collectionId: Value<int?>(other),
      relationType: 'prequel',
      source: 'anilist',
      subjectId: '124080',
      title: 'Horimiya',
      targetCollectionId: Value<int?>(id),
    ),
  ]);
  await db.upsertManualMediaLink(
    relation: MediaLinkRelation.sameWork,
    from: _book('vol1'),
    to: _collection(id),
  );
  await db.applyAiMediaLink(
    relation: MediaLinkRelation.adaptation,
    from: _book('vol2'),
    to: _collection(id),
    source: 'ai',
    reason: 'same title',
  );
  return (id: id, other: other, tagId: tagId);
}

void main() {
  group('删合集清掉以它为端点的作品图谱连接（BUG-5462）', () {
    Future<void> expectPurged(
      Future<void> Function(FushiDatabase db, int id) delete,
    ) async {
      final FushiDatabase db = await _openDb();
      final ({int id, int other, int tagId}) s = await _seed(db);
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: _book('vol9'),
        to: _collection(s.other),
      );
      expect(await _linksOf(db, s.id), hasLength(2));
      await delete(db, s.id);
      expect(await db.getMediaCollectionById(s.id), isNull);
      expect(await _linksOf(db, s.id), isEmpty, reason: '不留「不在库中」的死连接');
      expect(await _linksOf(db, s.other), hasLength(1), reason: '别的合集的连接不动');
      expect(await db.getTagsForCollection(s.id), isEmpty);
    }

    test('用户删除（deleteMediaCollection）', () async {
      await expectPurged((FushiDatabase db, int id) async {
        await db.deleteMediaCollection(id);
      });
    });

    test('移空自删（removeFromCollectionRaw）', () async {
      await expectPurged((FushiDatabase db, int id) async {
        await db.removeFromCollectionRaw(id, 'video', 'ep1', userIntent: false);
        expect(await _linksOf(db, id), hasLength(2), reason: '没移空不动连接');
        await db.removeFromCollectionRaw(id, 'video', 'ep2', userIntent: false);
      });
    });

    test('删条目连带清空（removeEntriesFromAllCollections）', () async {
      await expectPurged((FushiDatabase db, int id) async {
        await db.removeEntriesFromAllCollections(MediaKind.video, <String>[
          'ep1',
          'ep2',
        ]);
      });
    });

    test('同步解散（deleteMediaCollectionRaw）', () async {
      await expectPurged((FushiDatabase db, int id) async {
        await db.deleteMediaCollectionRaw(id);
      });
    });
  });

  group('合集身份快照（BUG-5461）', () {
    test('删前快照 → 删 → 还原：同一个 id，挂在 id 上的一切都回来', () async {
      final FushiDatabase db = await _openDb();
      final ({int id, int other, int tagId}) s = await _seed(db);
      final MediaCollectionRow before = (await db.getMediaCollectionById(
        s.id,
      ))!;
      final List<MediaLinkRow> linksBefore = await _linksOf(db, s.id);

      final Map<String, Object?> snapshot = (await db
          .captureMediaCollectionSnapshot(s.id))!;
      await db.removeFromCollectionRaw(s.id, 'video', 'ep1', userIntent: false);
      await db.removeFromCollectionRaw(s.id, 'video', 'ep2', userIntent: false);
      expect(await db.getMediaCollectionById(s.id), isNull);
      expect(await db.getCollectionScrapeMeta(s.id), isNull, reason: 'cascade');
      expect(
        (await db.getCollectionRelations(s.other)).single.targetCollectionId,
        isNull,
        reason: 'SET NULL',
      );

      expect(await db.restoreMediaCollectionSnapshot(snapshot), s.id);
      final MediaCollectionRow after = (await db.getMediaCollectionById(s.id))!;
      expect(after, before, reason: '合集行全部列原样（含 AniList id / 来源 / 分组键）');
      expect((await db.getCollectionScrapeMeta(s.id))?.subjectId, '124080');
      expect(
        (await db.getCollectionRelations(s.id)).single.subjectId,
        '163132',
      );
      expect(
        (await db.getCollectionRelations(s.other)).single.targetCollectionId,
        s.id,
        reason: '别的合集指向它的关系重新接上',
      );
      expect(
        (await db.getTagsForCollection(s.id)).map((BookTagRow t) => t.id),
        <int>[s.tagId],
      );
      expect(await _linksOf(db, s.id), unorderedEquals(linksBefore));
      expect(
        await db.getCollectionItems(s.id),
        isEmpty,
        reason: '成员由调用方按自己的语义还原',
      );
      expect(
        await db.hasCollectionDeletionTombstone('Horimiya', 'playlist'),
        isFalse,
      );
    });

    test('快照可 JSON 往返', () async {
      final FushiDatabase db = await _openDb();
      final ({int id, int other, int tagId}) s = await _seed(db);
      final Map<String, Object?> snapshot = (await db
          .captureMediaCollectionSnapshot(s.id))!;
      final Map<String, Object?> roundTripped =
          (jsonDecode(jsonEncode(snapshot)) as Map<Object?, Object?>)
              .cast<String, Object?>();
      await db.deleteMediaCollection(s.id);
      expect(await db.restoreMediaCollectionSnapshot(roundTripped), s.id);
      expect(await _linksOf(db, s.id), hasLength(2));
    });

    test('同名合集已被重建：连接与标签挂回它身上，它自己的资料不被覆盖', () async {
      final FushiDatabase db = await _openDb();
      final ({int id, int other, int tagId}) s = await _seed(db);
      final Map<String, Object?> snapshot = (await db
          .captureMediaCollectionSnapshot(s.id))!;
      await db.deleteMediaCollectionRaw(s.id);
      final int rebuilt = await db.createMediaCollection(
        'Horimiya',
        collectionType: 'playlist',
      );
      await db.addToCollectionRaw(rebuilt, 'video', 'ep1', userIntent: false);
      expect(rebuilt, isNot(s.id));

      expect(await db.restoreMediaCollectionSnapshot(snapshot), rebuilt);
      expect(await db.getMediaCollectionById(s.id), isNull);
      final MediaCollectionRow row = (await db.getMediaCollectionById(
        rebuilt,
      ))!;
      expect(row.anilistId, isNull, reason: '不覆盖现有合集自己的列');
      expect(await db.getCollectionScrapeMeta(rebuilt), isNull);
      expect(await _linksOf(db, rebuilt), hasLength(2));
      expect(
        (await db.getTagsForCollection(rebuilt)).map((BookTagRow t) => t.id),
        <int>[s.tagId],
      );
    });

    test('原 id 被占：插成新 id，子行外键改指新 id', () async {
      final FushiDatabase db = await _openDb();
      final ({int id, int other, int tagId}) s = await _seed(db);
      final Map<String, Object?> snapshot = (await db
          .captureMediaCollectionSnapshot(s.id))!;
      await db.deleteMediaCollection(s.id);
      await db.customStatement(
        'INSERT INTO media_collections (id, name, collection_type, created_at) '
        "VALUES (?, 'Squatter', 'collection', 0)",
        <Object?>[s.id],
      );

      final int id = (await db.restoreMediaCollectionSnapshot(snapshot))!;
      expect(id, isNot(s.id));
      expect((await db.getMediaCollectionById(id))!.name, 'Horimiya');
      expect((await db.getCollectionScrapeMeta(id))?.subjectId, '124080');
      expect(
        (await db.getCollectionRelations(s.other)).single.targetCollectionId,
        id,
      );
      expect(await _linksOf(db, id), hasLength(2));
      expect(await _linksOf(db, s.id), isEmpty);
    });

    test('父行已不在的子行跳过，不硬塞违反外键的行', () async {
      final FushiDatabase db = await _openDb();
      final ({int id, int other, int tagId}) s = await _seed(db);
      final Map<String, Object?> snapshot = (await db
          .captureMediaCollectionSnapshot(s.id))!;
      await db.deleteMediaCollection(s.id);
      await db.deleteTag(s.tagId);

      expect(await db.restoreMediaCollectionSnapshot(snapshot), s.id);
      expect(await db.getTagsForCollection(s.id), isEmpty);
      expect(await _linksOf(db, s.id), hasLength(2));
    });

    test('读不懂的快照返回 null，不动库', () async {
      final FushiDatabase db = await _openDb();
      expect(
        await db.restoreMediaCollectionSnapshot(<String, Object?>{'v': 999}),
        isNull,
      );
      expect(await db.captureMediaCollectionSnapshot(12345), isNull);
    });
  });
}
