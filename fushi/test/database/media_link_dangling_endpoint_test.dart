import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_merge.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// BUG-5457：合集 / 游戏端点的键是本机 id（合集 AUTOINCREMENT 不复用、游戏重新
/// 入库拿新 id），删了就永不再出现。删除路径以前不清 `media_links`，「同一作品」里
/// 留下标题是一串 id 的「未入库」死卡。这里钉死每条删除路径都清 / 改挂连接，
/// 以及 v181 迁移清掉存量死行。
void main() {
  const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: 'novel');
  const MediaLinkEndpoint otherBook = (kind: MediaLinkKind.book, key: 'other');

  MediaLinkEndpoint collectionEndpoint(int id) =>
      (kind: MediaLinkKind.videoCollection, key: '$id');

  Future<List<MediaLinkRow>> linksOf(FushiDatabase db, MediaLinkEndpoint e) =>
      db.mediaLinksForEndpoint(e.kind, e.key, includeRemoved: true);

  group('删除路径清 / 改挂作品图谱连接', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('deleteMediaCollection：连着它的连接（含否决墓碑）全删，别的不动', () async {
      final int dead = await db.createMediaCollection('Old');
      final int live = await db.createMediaCollection('Live');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: collectionEndpoint(dead),
        at: 1,
      );
      await db.proposeMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: otherBook,
        to: collectionEndpoint(dead),
        source: MediaLinkSource.mal,
        at: 2,
      );
      final MediaLinkRow suggestion = (await linksOf(db, otherBook)).single;
      await db.removeMediaLink(mediaLinkIdOf(suggestion), at: 3);
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: collectionEndpoint(live),
        at: 4,
      );

      expect(await db.deleteMediaCollection(dead), 1);

      expect(await linksOf(db, collectionEndpoint(dead)), isEmpty);
      expect(await linksOf(db, otherBook), isEmpty, reason: '墓碑也随端点删');
      expect(await linksOf(db, collectionEndpoint(live)), hasLength(1));
    });

    test('deleteMediaCollection(linksMovedTo)：改挂到目标；原本就连目标的去重', () async {
      final int source = await db.createMediaCollection('Source');
      final int target = await db.createMediaCollection('Target');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: collectionEndpoint(source),
        at: 5,
      );
      // 同一身份在目标上已有一条更早的建议：改挂后按 LWW 留用户确认的那条。
      await db.proposeMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: collectionEndpoint(target),
        source: MediaLinkSource.mal,
        at: 1,
      );
      // 两个合集互连：改挂后两端相同，直接丢。
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: collectionEndpoint(source),
        to: collectionEndpoint(target),
        at: 6,
      );

      await db.deleteMediaCollection(source, linksMovedTo: target);

      expect(await linksOf(db, collectionEndpoint(source)), isEmpty);
      final List<MediaLinkRow> moved = await linksOf(
        db,
        collectionEndpoint(target),
      );
      expect(moved, hasLength(1));
      expect(moved.single.fromKey, book.key);
      expect(moved.single.relation, MediaLinkRelation.adaptation.dbValue);
      expect(mediaLinkConfirmerOf(moved.single), MediaLinkConfirmer.user);
      expect(moved.single.updatedAt, 5);
    });

    test('linksMovedTo 指向不存在的合集：按删除处理，不改挂成新死行', () async {
      final int source = await db.createMediaCollection('Source');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: collectionEndpoint(source),
        at: 1,
      );
      await db.deleteMediaCollection(source, linksMovedTo: 9999);
      expect(await db.allMediaLinks(), isEmpty);
    });

    test('mergeMediaCollectionsInto：被并掉的合集的连接跟到目标', () async {
      final int source = await db.createMediaCollection('Horimiya (old)');
      final int target = await db.createMediaCollection('Horimiya');
      await db.addToCollection(source, MediaKind.video, 'v1');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: collectionEndpoint(source),
        at: 1,
      );

      expect(
        await mergeMediaCollectionsInto(
          db,
          targetId: target,
          sourceIds: <int>[source],
        ),
        1,
      );

      expect(await linksOf(db, collectionEndpoint(source)), isEmpty);
      expect(await linksOf(db, collectionEndpoint(target)), hasLength(1));
    });

    test('删视频把合集移空自删：连接同删', () async {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('v1'),
          title: const Value<String>('v1'),
          videoPath: const Value<String>('/abs/v1.mp4'),
        ),
      );
      final int col = await db.createMediaCollection('Solo');
      await db.addToCollection(col, MediaKind.video, 'v1');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: collectionEndpoint(col),
        at: 1,
      );

      await db.deleteVideoBooks(<String>['v1']);

      expect(await db.getMediaCollectionById(col), isNull);
      expect(await db.allMediaLinks(), isEmpty);
    });

    test('deleteMediaCollectionRaw（同步应用端）：连接同删', () async {
      final int col = await db.createMediaCollection('Synced');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: collectionEndpoint(col),
        at: 1,
      );
      await db.deleteMediaCollectionRaw(col);
      expect(await db.allMediaLinks(), isEmpty);
    });

    test('deleteGalgame：连着游戏的连接同删', () async {
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'G1',
          exePath: '/g/1.exe',
          workdir: '/g',
          addedAt: 0,
        ),
      );
      const MediaLinkEndpoint game = (kind: MediaLinkKind.game, key: 'g1');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: game,
        at: 1,
      );
      await db.deleteGalgame('g1');
      expect(await db.allMediaLinks(), isEmpty);
    });
  });

  test('v180 → v181：清掉指向不存在合集 / 游戏的存量连接，书端点与活合集保留；幂等', () async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'media_link_v181',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    final int live = await db.createMediaCollection('Live');
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: collectionEndpoint(live),
      at: 1,
    );
    // 书端点本机没有（键跨端稳定、书回来自然对上）：保留。
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: book,
      to: otherBook,
      at: 2,
    );
    await db.close();

    // 旧版删合集 / 游戏留下的死行：直接写库模拟。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final (String kind, String key) in <(String, String)>[
      (MediaLinkKind.videoCollection.dbValue, '13'),
      (MediaLinkKind.game.dbValue, 'gone'),
    ]) {
      raw.execute(
        'INSERT INTO media_links (from_kind, from_key, relation, to_kind, '
        'to_key, source, is_user_confirmed, confirmed_by, created_at, '
        "updated_at) VALUES ('book', 'novel', 'adaptation', ?, ?, 'ai', 0, "
        "'ai', 3, 3)",
        <Object>[kind, key],
      );
    }
    raw.execute('PRAGMA user_version = 180');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, kFushiDbSchemaVersion);
    final Set<String> left = <String>{
      for (final MediaLinkRow r in await migrated.allMediaLinks())
        '${r.toKind}:${r.toKey}',
    };
    expect(left, <String>{
      '${MediaLinkKind.videoCollection.dbValue}:$live',
      '${MediaLinkKind.book.dbValue}:${otherBook.key}',
    });
    expect(await migrated.purgeDanglingMediaLinks(), 0, reason: '幂等');
    await migrated.close();
  });
}
