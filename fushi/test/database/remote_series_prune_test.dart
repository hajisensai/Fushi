// 媒体服务器剧名合集的存量清理与认领（BUG-5601 PR2）：判据逐条、删除效果、幂等、
// 认领、清理后临时分组显示不变、被动物化与哨兵标记。
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:fushi/src/media/video/video_continue_watching.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/remote_series_overlay.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

const String _type = 'playlist';

/// 飞牛形状的条目 id（`e` + 26 位 ULID）。
String _id(String series, int n) =>
    'e${'${series.toUpperCase()}$n'.padRight(26, '0').substring(0, 26)}';

RemoteVideoInfo _ep(String series, int n) => RemoteVideoInfo(
  id: _id(series, n),
  title: '$series $n',
  collection: RemoteCollectionMembership(
    collectionName: series,
    collectionType: _type,
    sortIndex: n,
  ),
);

List<RemoteVideoInfo> _series(String name, [int count = 3]) =>
    <RemoteVideoInfo>[for (int n = 1; n <= count; n++) _ep(name, n)];

/// 照 B 之前视频库页的被动收养把 [names] 收成真合集（存量幽灵合集的来历）。
Future<Map<String, int>> _adoptGhosts(
  FushiDatabase db,
  List<String> names,
) async {
  await RemoteCollectionAdoptionService(
    db,
  ).adoptVideos(<RemoteVideoInfo>[for (final String n in names) ..._series(n)]);
  return <String, int>{
    for (final String n in names)
      n: (await db.getMediaCollectionByNaturalKey(n, _type))!.id,
  };
}

Future<void> _sql(
  FushiDatabase db,
  String sql, [
  List<Object?> args = const <Object?>[],
]) => db.customStatement(sql, args);

Future<CollectionMemberTombstoneRow?> _sentinel(
  FushiDatabase db,
  String name,
) =>
    (db.select(db.collectionMemberTombstones)..where(
          (t) =>
              t.collectionName.equals(name) &
              t.collectionType.equals(_type) &
              t.mediaType.equals(FushiDatabase.collectionTombstoneSentinel) &
              t.entryKey.equals(FushiDatabase.collectionTombstoneSentinel),
        ))
        .getSingleOrNull();

void main() {
  test('v182 → v183：墓碑表加 auto_pruned，存量哨兵是 false；重跑幂等', () async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'auto_pruned_v183',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.upsertCollectionMemberTombstone(
      collectionName: 'Old',
      collectionType: _type,
      mediaType: FushiDatabase.collectionTombstoneSentinel,
      entryKey: FushiDatabase.collectionTombstoneSentinel,
      deletedAt: 1,
    );
    await db.close();
    // 退回 v182 的表形：去掉新列，user_version 回拨。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(
      'ALTER TABLE collection_member_tombstones DROP COLUMN auto_pruned',
    );
    raw.execute('PRAGMA user_version = 182');
    raw.close();

    db = FushiDatabase.atFile(path, isMainProcess: false);
    final CollectionMemberTombstoneRow row =
        (await db.getAllCollectionMemberTombstones()).single;
    expect(row.collectionName, 'Old');
    expect(row.autoPruned, isFalse);
    await db.close();
    final sqlite.Database check = sqlite.sqlite3.open(path);
    expect(check.select('PRAGMA user_version').single.values.single, 183);
    check.close();
  });

  late FushiDatabase db;
  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    debugVideoMembershipInline = true;
    VirtualCollectionRegistry.instance.debugReset();
  });
  tearDown(() async {
    debugVideoMembershipInline = false;
    VirtualCollectionRegistry.instance.debugReset();
    await db.close();
  });

  test('成员键形状判据：媒体服务器 id 是，本机命名族不是；SQL 与 Dart 同口径', () async {
    const Map<String, bool> cases = <String, bool>{
      'e01HZY3K9V7Q0M2N4P6R8S0T2V4': true, // 飞牛
      '0123456789abcdef0123456789abcdef': true, // Jellyfin
      '48213': true, // Plex / Emby
      'video/local.mkv': false,
      'video/stream/yt:abc': false,
      'anime-source:mihon:1:2': false,
      'work-extra:7': false,
      '': false,
    };
    cases.forEach((String key, bool expected) {
      expect(isDerivedRemoteSeriesEntryKey(key), expected, reason: key);
    });
    // SQL 侧：把每个键作为单成员合集，看清理选不选它。
    int i = 0;
    for (final String key in cases.keys.where((String k) => k.isNotEmpty)) {
      final int id = await db.createMediaCollection(
        'K${i++}',
        collectionType: _type,
      );
      await db.addToCollection(id, MediaKind.video, key, userIntent: false);
    }
    await db.pruneUnusedRemoteSeriesCollections();
    final Set<String> left = <String>{
      for (final MediaCollectionRow c in await db.getAllMediaCollections())
        for (final MediaCollectionItemRow m in await db.getCollectionItems(
          c.id,
        ))
          m.entryKey,
    };
    for (final String key in cases.keys.where((String k) => k.isNotEmpty)) {
      expect(left.contains(key), !cases[key]!, reason: key);
    }
  });

  group('判据（§4.1）：每个「动过」的信号单独出现都保留', () {
    // 名字 → 让它「动过」的那一步。
    final Map<String, Future<void> Function(FushiDatabase db, int id)>
    signals = <String, Future<void> Function(FushiDatabase db, int id)>{
      'cover_source': (db, id) => _sql(
        db,
        'UPDATE media_collections SET cover_source = ? WHERE id = ?',
        <Object?>['video|x', id],
      ),
      'cover_path': (db, id) => _sql(
        db,
        'UPDATE media_collections SET cover_path = ? WHERE id = ?',
        <Object?>['/c.jpg', id],
      ),
      'anilist_id': (db, id) => _sql(
        db,
        'UPDATE media_collections SET anilist_id = 1 WHERE id = ?',
        <Object?>[id],
      ),
      'subtitle_language': (db, id) => _sql(
        db,
        "UPDATE media_collections SET subtitle_language = 'ja' WHERE id = ?",
        <Object?>[id],
      ),
      'subtitle_release_group': (db, id) => _sql(
        db,
        "UPDATE media_collections SET subtitle_release_group = 'g' "
        'WHERE id = ?',
        <Object?>[id],
      ),
      'audio_track_id': (db, id) => _sql(
        db,
        "UPDATE media_collections SET audio_track_id = '2' WHERE id = ?",
        <Object?>[id],
      ),
      'subtitle_delay_ms': (db, id) => _sql(
        db,
        'UPDATE media_collections SET subtitle_delay_ms = 0 WHERE id = ?',
        <Object?>[id],
      ),
      'secondary_subtitle_delay_ms': (db, id) => _sql(
        db,
        'UPDATE media_collections SET secondary_subtitle_delay_ms = 0 '
        'WHERE id = ?',
        <Object?>[id],
      ),
      'source_folder_path': (db, id) => _sql(
        db,
        "UPDATE media_collections SET source_folder_path = '/v' "
        'WHERE id = ?',
        <Object?>[id],
      ),
      'organize_key': (db, id) => _sql(
        db,
        "UPDATE media_collections SET organize_key = 'k' WHERE id = ?",
        <Object?>[id],
      ),
      'organize_aliases': (db, id) => _sql(
        db,
        "UPDATE media_collections SET organize_aliases = 'a' WHERE id = ?",
        <Object?>[id],
      ),
      'origin=ai': (db, id) => _sql(
        db,
        "UPDATE media_collections SET origin = 'ai' WHERE id = ?",
        <Object?>[id],
      ),
      'type=collection': (db, id) => _sql(
        db,
        "UPDATE media_collections SET collection_type = 'collection' "
        'WHERE id = ?',
        <Object?>[id],
      ),
      '手排过': (db, id) => db.setCollectionOrderUpdatedAt(id, 9),
      '成员被钉住': (db, id) => _sql(
        db,
        'UPDATE media_collection_items SET pinned_by_user = 1 '
        'WHERE collection_id = ? AND entry_key = ?',
        <Object?>[id, _id('S', 1)],
      ),
      '混有书成员': (db, id) => db.addToCollectionRaw(
        id,
        MediaKind.epub.dbValue,
        'book-1',
        userIntent: false,
      ),
      '混有本地文件成员': (db, id) => db.addToCollectionRaw(
        id,
        MediaKind.video.dbValue,
        'video/local.mkv',
        userIntent: false,
      ),
      '在线视频源成员': (db, id) => db.addToCollectionRaw(
        id,
        MediaKind.video.dbValue,
        'anime-source:m:1',
        userIntent: false,
      ),
      '成员在本机有视频行': (db, id) => _sql(
        db,
        'INSERT INTO video_books (book_uid, title, video_path) '
        "VALUES (?, 't', 'media-server://x')",
        <Object?>[_id('S', 2)],
      ),
      '合集标签': (db, id) async {
        await _sql(
          db,
          "INSERT INTO book_tags (id, name, created_at) VALUES (77, 'tg', 0)",
        );
        await _sql(
          db,
          'INSERT INTO tag_assignments (media_kind, entry_key, tag_id) '
          "VALUES ('collection', ?, 77)",
          <Object?>['$id'],
        );
      },
      '合集标签墓碑': (db, id) => _sql(
        db,
        'INSERT INTO book_tag_membership_tombstones (item_key, media_type, '
        "tag_name, deleted_at) VALUES (?, 'collection', 'tg', 1)",
        <Object?>['$id'],
      ),
      '刮削资料': (db, id) => _sql(
        db,
        'INSERT INTO collection_scrape_meta (collection_id, source, '
        "subject_id, title, scraped_at) VALUES (?, 'tmdb', '1', 't', 1)",
        <Object?>[id],
      ),
      '图片': (db, id) => _sql(
        db,
        'INSERT INTO media_images (collection_id, kind, path) '
        "VALUES (?, 'poster', '/p.jpg')",
        <Object?>[id],
      ),
      '作品资料': (db, id) => _sql(
        db,
        'INSERT INTO video_metadata_works (collection_id, media_type, '
        "title, updated_at) VALUES (?, 'tv', 't', 1)",
        <Object?>[id],
      ),
      '作品关系（起点）': (db, id) => _sql(
        db,
        'INSERT INTO collection_relations (collection_id, relation_type, '
        "source, subject_id, title) VALUES (?, 'sequel', 'tmdb', '2', 't')",
        <Object?>[id],
      ),
      '作品关系（目标）': (db, id) async {
        final int other = await db.createMediaCollection('Owner');
        await _sql(
          db,
          'INSERT INTO collection_relations (collection_id, relation_type, '
          'source, subject_id, title, target_collection_id) '
          "VALUES (?, 'sequel', 'tmdb', '3', 't', ?)",
          <Object?>[other, id],
        );
      },
      '用户确认的作品图谱连接': (db, id) => _sql(
        db,
        'INSERT INTO media_links (from_kind, from_key, relation, to_kind, '
        'to_key, source, is_user_confirmed, created_at, updated_at, '
        "confirmed_by) VALUES ('video_collection', ?, 'sequel', "
        "'epub', 'b', 'ai', 0, 1, 1, 'user')",
        <Object?>['$id'],
      ),
      '手动连接（终点）': (db, id) => _sql(
        db,
        'INSERT INTO media_links (from_kind, from_key, relation, to_kind, '
        'to_key, source, created_at, updated_at) VALUES '
        "('epub', 'b', 'adaptation', 'video_collection', ?, 'manual', 1, 1)",
        <Object?>['$id'],
      ),
      '下载任务': (db, id) => _sql(
        db,
        'INSERT INTO video_download_jobs (job_id, resource_provider, '
        'selected_resource_id, media_kind, title, backend_kind, '
        'fingerprint, created_at, updated_at, collection_id) VALUES '
        "('j', 'p', 'r', 'tv', 't', 'b', 'f', 1, 1, ?)",
        <Object?>[id],
      ),
      '下载订阅': (db, id) => _sql(
        db,
        'INSERT INTO video_download_subscriptions (subscription_id, '
        'resource_provider, media_kind, title, search_query, '
        'backend_kind, fingerprint, created_at, updated_at, '
        "collection_id) VALUES ('s', 'p', 'tv', 't', 'q', 'b', 'f', 1, "
        '1, ?)',
        <Object?>[id],
      ),
      '私密标记（已取消也算）': (db, id) => _sql(
        db,
        'INSERT INTO media_privacy_flags (media_kind, entry_key, '
        "private_at, cleared_at) VALUES ('collection', ?, 1, 2)",
        <Object?>['$id'],
      ),
      'NSFW 标记': (db, id) => _sql(
        db,
        'INSERT INTO media_nsfw_flags (media_kind, entry_key, nsfw_at) '
        "VALUES ('collection', ?, 1)",
        <Object?>['$id'],
      ),
      '上锁标记': (db, id) => _sql(
        db,
        'INSERT INTO media_locked_flags (media_kind, entry_key, locked_at) '
        "VALUES ('collection', ?, 1)",
        <Object?>['$id'],
      ),
      '用户移出过一集': (db, id) =>
          db.removeFromCollection(id, MediaKind.video, _id('S', 3)),
      'AI 整理记录': (db, id) async {
        await _sql(
          db,
          'INSERT INTO library_organize_runs (id, domain, trigger, '
          "started_at, status) VALUES (5, 'video', 'manual', 1, 'done')",
        );
        await _sql(
          db,
          'INSERT INTO library_organize_changes (run_id, kind, '
          'collection_name, collection_type, source, confidence, '
          "payload_json) VALUES (5, 'create', 'S', ?, 'ai', 'high', '{}')",
          <Object?>[_type],
        );
      },
    };

    for (final MapEntry<String, Future<void> Function(FushiDatabase, int)> s
        in signals.entries) {
      test(s.key, () async {
        final Map<String, int> ids = await _adoptGhosts(db, <String>[
          'S',
          'Ghost',
        ]);
        await s.value(db, ids['S']!);
        expect(await db.pruneUnusedRemoteSeriesCollections(), 1);
        expect(await db.getMediaCollectionById(ids['S']!), isNotNull);
        expect(await db.getMediaCollectionById(ids['Ghost']!), isNull);
      });
    }

    test('AI 推断的作品图谱连接不算动过，随合集一起删', () async {
      final Map<String, int> ids = await _adoptGhosts(db, <String>['S']);
      await _sql(
        db,
        'INSERT INTO media_links (from_kind, from_key, relation, to_kind, '
        'to_key, source, is_user_confirmed, created_at, updated_at, '
        "confirmed_by) VALUES ('video_collection', ?, 'sequel', "
        "'epub', 'b', 'ai', 0, 1, 1, 'ai')",
        <Object?>['${ids['S']}'],
      );
      expect(await db.pruneUnusedRemoteSeriesCollections(), 1);
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM media_links')
                .getSingle())
            .read<int>('n'),
        0,
      );
    });

    test('自然键重名的不删（哨兵会连带删掉对端另一行）', () async {
      final Map<String, int> ids = await _adoptGhosts(db, <String>['S']);
      await _sql(
        db,
        'INSERT INTO media_collections (name, collection_type, created_at) '
        "VALUES ('S', 'playlist', 1)",
      );
      expect(await db.pruneUnusedRemoteSeriesCollections(), 0);
      expect(await db.getMediaCollectionById(ids['S']!), isNotNull);
    });

    test('空合集不删', () async {
      await db.createMediaCollection('Empty', collectionType: _type);
      expect(await db.pruneUnusedRemoteSeriesCollections(), 0);
    });
  });

  test('删除效果：成员 / 合集行没了，哨兵 auto_pruned 且不带分组键；连跑两次幂等', () async {
    final Map<String, int> ids = await _adoptGhosts(db, <String>['A', 'B']);
    final int kept = await db.createMediaCollection('Mine');
    await db.addToCollection(kept, MediaKind.video, 'video/mine.mkv');

    expect(await db.pruneUnusedRemoteSeriesCollections(nowMs: 4242), 2);
    for (final String n in <String>['A', 'B']) {
      expect(await db.getMediaCollectionById(ids[n]!), isNull);
      expect(await db.getCollectionItems(ids[n]!), isEmpty);
      final CollectionMemberTombstoneRow s = (await _sentinel(db, n))!;
      expect(s.autoPruned, isTrue);
      expect(s.deletedAt, 4242);
      expect(s.organizeKey, isNull);
      expect(s.organizeMerged, isFalse);
      expect(s.publishedAt, isNull);
    }
    expect(await db.getMediaCollectionById(kept), isNotNull);
    expect(await db.pruneUnusedRemoteSeriesCollections(), 0);

    // 与逐个 deleteMediaCollection(userIntent: false) 的落库结果一致（只差标记）。
    final FushiDatabase ref = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(ref.close);
    final Map<String, int> refIds = await _adoptGhosts(ref, <String>['A', 'B']);
    for (final int id in refIds.values) {
      await ref.deleteMediaCollection(id, userIntent: false, deletedAt: 4242);
    }
    List<String> shape(List<CollectionMemberTombstoneRow> rows) => <String>[
      for (final CollectionMemberTombstoneRow r in rows)
        '${r.collectionName}|${r.collectionType}|${r.mediaType}|${r.entryKey}|'
            '${r.deletedAt}|${r.organizeKey}|${r.organizeMerged}|${r.publishedAt}',
    ]..sort();
    expect(
      shape(await db.getAllCollectionMemberTombstones()),
      shape(await ref.getAllCollectionMemberTombstones()),
    );
  });

  test('清理后的哨兵进本地清单：死条目带 autoPruned', () async {
    await _adoptGhosts(db, <String>['A']);
    await db.pruneUnusedRemoteSeriesCollections(nowMs: 10);
    final CollectionManifest m = await loadLocalCollectionManifest(db);
    final CollectionManifestEntry e = m.collections.singleWhere(
      (CollectionManifestEntry c) => c.name == 'A',
    );
    expect(e.deletedAt, 10);
    expect(e.autoPruned, isTrue);
    expect(e.toJson()['autoPruned'], isTrue);
  });

  test('认领：有本机视频行的成员钉住，之后清理保留它；幂等', () async {
    final Map<String, int> ids = await _adoptGhosts(db, <String>['A', 'B']);
    await _sql(
      db,
      "INSERT INTO video_books (book_uid, title, video_path) VALUES (?, 't', '/d.mkv')",
      <Object?>[_id('A', 2)],
    );
    expect(await db.claimRemoteSeriesCollections(), 1);
    expect(await db.claimRemoteSeriesCollections(), 0);
    final List<MediaCollectionItemRow> items = await db.getCollectionItems(
      ids['A']!,
    );
    expect(
      <String, bool>{
        for (final MediaCollectionItemRow i in items)
          i.entryKey: i.pinnedByUser,
      },
      <String, bool>{_id('A', 1): false, _id('A', 2): true, _id('A', 3): false},
    );
    // 本机行删掉以后（换了设备 / 删了下载），钉住的成员照样挡住清理。
    await _sql(db, 'DELETE FROM video_books');
    expect(await db.healRemoteSeriesCollections(), 1);
    expect(await db.getMediaCollectionById(ids['A']!), isNotNull);
    expect(await db.getMediaCollectionById(ids['B']!), isNull);
    // 认领出的 pinned 进清单（别的设备据此保留、同步否决自动清理）。
    final CollectionManifest m = await loadLocalCollectionManifest(db);
    expect(
      m.collections
          .singleWhere((CollectionManifestEntry c) => c.name == 'A')
          .members
          .where((CollectionManifestMember x) => x.pinned)
          .map((CollectionManifestMember x) => x.entryKey),
      <String>[_id('A', 2)],
    );
  });

  test('认领不碰本机文件命名族与非剧名合集', () async {
    final int mine = await db.createMediaCollection(
      'Mine',
      collectionType: _type,
    );
    await db.addToCollection(
      mine,
      MediaKind.video,
      'video/x.mkv',
      userIntent: false,
    );
    await _sql(
      db,
      "INSERT INTO video_books (book_uid, title, video_path) VALUES ('video/x.mkv', 't', '/x.mkv')",
    );
    expect(await db.claimRemoteSeriesCollections(), 0);
  });

  test('清理后临时分组照常：归属与组内序和清理前一致（显示不变）', () async {
    final List<RemoteVideoInfo> catalog = <RemoteVideoInfo>[
      ..._series('A'),
      ..._series('B', 2),
    ];
    await RemoteCollectionAdoptionService(db).adoptVideos(catalog);
    final RemoteSeriesColumns cols = RemoteSeriesColumns.fromVideos(catalog);
    Future<Map<String, (String, int?)>> view() async {
      final VideoLibraryMembership m = await loadVideoLibraryMembership(
        db,
        books: const <VideoBookRow>[],
        series: cols,
      );
      final Map<int, String> names = <int, String>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.id: c.name,
        for (final MapEntry<int, MediaCollectionRow> e
            in m.virtualCollections.entries)
          e.key: e.value.name,
      };
      return <String, (String, int?)>{
        for (final MapEntry<String, int> e in m.primary.entries)
          e.key: (names[e.value]!, m.memberSortIndex[e.key]),
      };
    }

    final Map<String, (String, int?)> before = await view();
    expect(before, hasLength(5));
    expect(await db.pruneUnusedRemoteSeriesCollections(), 2);
    expect(await db.getAllMediaCollections(), isEmpty);
    expect(await view(), before);

    // 用户删除的哨兵照旧挡住分组。
    await db.upsertCollectionMemberTombstone(
      collectionName: 'B',
      collectionType: _type,
      mediaType: FushiDatabase.collectionTombstoneSentinel,
      entryKey: FushiDatabase.collectionTombstoneSentinel,
      deletedAt: 99,
    );
    expect((await _sentinel(db, 'B'))!.autoPruned, isFalse);
    final Map<String, (String, int?)> after = await view();
    expect(after.keys.where((String k) => k.contains(_id('B', 1))), isEmpty);
    expect(
      after.keys.where((String k) => k.contains(_id('A', 1))),
      hasLength(1),
    );
  });

  test('被动物化（下载落地）：清掉自动清理哨兵照样建；用户删的哨兵照旧让路', () async {
    await _adoptGhosts(db, <String>['A', 'B']);
    await db.pruneUnusedRemoteSeriesCollections();
    await db.upsertCollectionMemberTombstone(
      collectionName: 'B',
      collectionType: _type,
      mediaType: FushiDatabase.collectionTombstoneSentinel,
      entryKey: FushiDatabase.collectionTombstoneSentinel,
      deletedAt: 99,
    );
    List<RemoteSeriesEntry> members(String s) => <RemoteSeriesEntry>[
      for (final RemoteVideoInfo v in _series(s))
        RemoteSeriesEntry(
          entryKey: v.id,
          name: s,
          collectionType: _type,
          sortIndex: v.collection!.sortIndex,
        ),
    ];
    final MediaCollectionRow? a = await materializeRemoteSeries(
      db,
      name: 'A',
      collectionType: _type,
      members: members('A'),
      userIntent: false,
    );
    expect(a, isNotNull);
    expect(await _sentinel(db, 'A'), isNull);
    expect(await db.getCollectionItems(a!.id), hasLength(3));
    final MediaCollectionRow? b = await materializeRemoteSeries(
      db,
      name: 'B',
      collectionType: _type,
      members: members('B'),
      userIntent: false,
    );
    expect(b, isNull);
    expect(await _sentinel(db, 'B'), isNotNull);
  });
}
