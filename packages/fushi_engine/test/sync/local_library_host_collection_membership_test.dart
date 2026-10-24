import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:test/test.dart';

/// 互联 host 清单（listBooks / listVideos）的主合集归属：host 改用收窄到本机条目的
/// 一趟 SQL（`getLocalPrimaryCollectionMembership`）后，每条目带出的 `collection`
/// 必须与旧口径逐字段一致——旧口径 = 全表 `getPrimaryCollectionIdByEntry`（MIN
/// collection_id 折叠）+ 主归属合集的 `getCollectionItems` 取组内 sortIndex。
///
/// 这里把旧口径用公开 DB API 原样重算一遍当参照，再逐条比对，并钉几个具体值。
Future<Map<String, RemoteCollectionMembership>> _legacyMembership(
  FushiDatabase db,
) async {
  final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
  final Map<int, MediaCollectionRow> byId = <int, MediaCollectionRow>{
    for (final MediaCollectionRow c in await db.getAllMediaCollections())
      c.id: c,
  };
  final Map<String, RemoteCollectionMembership> out =
      <String, RemoteCollectionMembership>{};
  for (final int cid in primary.values.toSet()) {
    final MediaCollectionRow? col = byId[cid];
    if (col == null) continue;
    for (final MediaCollectionItemRow item in await db.getCollectionItems(
      cid,
    )) {
      final String key = '${item.mediaType}|${item.entryKey}';
      if (primary[key] != cid) continue;
      out[key] = RemoteCollectionMembership(
        collectionName: col.name,
        collectionType: col.collectionType,
        sortIndex: item.sortIndex,
      );
    }
  }
  return out;
}

Map<String, Object?>? _json(RemoteCollectionMembership? m) => m?.toJson();

void main() {
  late FushiDatabase db;
  late Directory root;
  late LocalLibraryHostService svc;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('host_membership');
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    svc = LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: root,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );

    Future<void> book(String uid, String key) => db.insertEpubBook(
      EpubBooksCompanion.insert(
        uid: Value<String>(uid),
        bookKey: key,
        title: key,
        epubPath: '${root.path}/$uid.epub',
        extractDir: '',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    // 书名不带卷号，BookSeriesGrouper 不会动它们的归属。
    await book('uid-a', 'Alpha'); // 两个合集里都有 → 取 id 小的
    await book('uid-b', 'Bravo'); // 只有 epub|bookKey 透传行
    await book('uid-c', 'Charlie'); // srt-backed 有声书，以 srt|uid 入合集
    await book('uid-d', 'Delta'); // 散卡
    await db.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: 'srt-c',
        title: 'Charlie',
        srtPath: '${root.path}/c.srt',
        importedAt: 1,
        bookKey: const Value<String>('Charlie'),
      ),
    );
    for (final String uid in <String>['v1', 'v2', 'v3']) {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: uid,
          videoPath: '${root.path}/$uid.mkv',
        ),
      );
    }

    final int c1 = await db.createMediaCollection(
      'First',
      collectionType: 'playlist',
    );
    final int c2 = await db.createMediaCollection('Second');
    final int c3 = await db.createMediaCollection(
      'Third',
      collectionType: 'playlist',
    );
    final int junk = await db.createMediaCollection('Online junk');
    Future<void> add(int cid, String type, String key, int sortIndex) => db
        .into(db.mediaCollectionItems)
        .insert(
          MediaCollectionItemsCompanion.insert(
            collectionId: cid,
            mediaType: type,
            entryKey: key,
            sortIndex: Value<int>(sortIndex),
          ),
        );
    await add(c2, 'epub', 'uid-a', 7);
    await add(c1, 'epub', 'uid-a', 3);
    await add(c3, 'epub', 'Bravo', 5);
    await add(c2, 'srt', 'srt-c', 2);
    await add(c3, 'video', 'v1', 9);
    await add(c2, 'video', 'v1', 4);
    await add(c3, 'video', 'v2', 1);
    for (int i = 0; i < 50; i++) {
      await add(junk, 'video', 'online-$i', i);
      await add(c1, 'video', 'online-$i', 100 + i);
    }
  });

  tearDown(() async {
    await db.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('listBooks 的 collection 与旧全表口径逐条一致', () async {
    final Map<String, RemoteCollectionMembership> legacy =
        await _legacyMembership(db);
    final Map<String, String> uidByKey = <String, String>{
      for (final EpubBookRow r in await db.getAllEpubBooks()) r.bookKey: r.uid,
    };
    final Map<String, String> srtUidByKey = <String, String>{
      for (final SrtBookRow s in await db.getAllSrtBooks()) s.bookKey: s.uid,
    };
    final List<RemoteBookInfo> books = await svc.listBooks();
    expect(books, hasLength(4));
    for (final RemoteBookInfo b in books) {
      final String key = b.bookKey!;
      final RemoteCollectionMembership? expected =
          legacy['epub|${uidByKey[key]}'] ??
          legacy['epub|$key'] ??
          (srtUidByKey[key] == null ? null : legacy['srt|${srtUidByKey[key]}']);
      expect(_json(b.collection), _json(expected), reason: key);
    }
    final Map<String, Map<String, Object?>?> byKey =
        <String, Map<String, Object?>?>{
          for (final RemoteBookInfo b in books) b.bookKey!: _json(b.collection),
        };
    expect(byKey['Alpha'], <String, Object?>{
      'name': 'First',
      'collectionType': 'playlist',
      'sortIndex': 3,
    });
    expect(byKey['Bravo'], <String, Object?>{
      'name': 'Third',
      'collectionType': 'playlist',
      'sortIndex': 5,
    });
    expect(byKey['Charlie'], <String, Object?>{
      'name': 'Second',
      'collectionType': 'collection',
      'sortIndex': 2,
    });
    expect(byKey['Delta'], isNull);
  });

  test('listVideos 的 collection 与旧全表口径逐条一致', () async {
    final Map<String, RemoteCollectionMembership> legacy =
        await _legacyMembership(db);
    final List<RemoteVideoInfo> videos = await svc.listVideos();
    expect(videos, hasLength(3));
    for (final RemoteVideoInfo v in videos) {
      expect(_json(v.collection), _json(legacy['video|${v.id}']), reason: v.id);
    }
    final Map<String, Map<String, Object?>?> byId =
        <String, Map<String, Object?>?>{
          for (final RemoteVideoInfo v in videos) v.id: _json(v.collection),
        };
    expect(byId['v1'], <String, Object?>{
      'name': 'Second',
      'collectionType': 'collection',
      'sortIndex': 4,
    });
    expect(byId['v2']?['name'], 'Third');
    expect(byId['v3'], isNull);
  });
}
