import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/aggregate_sync_service.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

/// BUG-1572：**上行**的聚合快照必须过一遍本机删除墓碑。
///
/// `applySnapshotToLocal` 早就按墓碑跳过写回本地，但两条 push 路径（云
/// `putJsonAsset` / 互联 `pushMerged`）推的是未裁剪的 merged —— merged = local ∪ peer，
/// peer 那份仍带着本机已删的统计/收藏词/收藏句，于是本机把自己删掉的东西又发布给
/// host / 云；对端没有本机的墓碑，照单落库，下轮回灌本机 = 数据复活。
Future<FushiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  return FushiDatabase(dir.path);
}

/// 一份「对端」快照：两本书的统计、一个收藏词、一条收藏句。本机随后对其中
/// `Book A` / `w1` / 收藏句立墓碑，`Book B` 保持存活作对照（证明裁剪是逐条的，
/// 不是把整份快照一刀切扔掉）。
AggregateSnapshot _peerSnapshot(FavoriteSentence sentence) => AggregateSnapshot(
      readingStats: const <ReadingStatRecord>[
        ReadingStatRecord(
          title: 'Book A',
          dateKey: '2026-06-01',
          charactersRead: 120,
          readingTimeMs: 60000,
          lastStatisticModified: 10,
        ),
        ReadingStatRecord(
          title: 'Book B',
          dateKey: '2026-06-01',
          charactersRead: 300,
          readingTimeMs: 90000,
          lastStatisticModified: 11,
        ),
      ],
      videoStats: const <VideoStatRecord>[
        VideoStatRecord(
          title: 'Video A',
          dateKey: '2026-06-01',
          subtitleChars: 50,
          watchTimeMs: 30000,
          lastModified: 12,
        ),
      ],
      lookupMiningCounters: const <LookupMiningRecord>[
        LookupMiningRecord(
          bookKey: 'bk-a',
          title: 'Book A',
          sourceType: 'book',
          dateKey: '2026-06-01',
          lookupCount: 7,
          mineCount: 3,
        ),
      ],
      favoriteWords: const <FavoriteWordRecord>[
        FavoriteWordRecord(
          expression: 'w1',
          reading: 'r1',
          glossary: 'g1',
          sourceType: 'book',
          dateKey: '2026-06-01',
          createdAt: 100,
        ),
        FavoriteWordRecord(
          expression: 'w2',
          reading: 'r2',
          glossary: 'g2',
          sourceType: 'book',
          dateKey: '2026-06-01',
          createdAt: 101,
        ),
      ],
      favoriteSentences: <FavoriteSentence>[sentence],
    );

FavoriteSentence _sentence() => FavoriteSentence(
      id: 'fav-1',
      text: '削除された文',
      bookTitle: 'Book A',
      bookKey: 'bk-a',
      sectionIndex: 0,
      normCharOffset: 10,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

/// 在本机立下「这些条目我已经删了」的三类墓碑。
Future<void> _tombstoneEverything(
    FushiDatabase db, FavoriteSentence sentence) async {
  await db.insertStatisticsTombstone('Book A', FushiDatabase.statSourceBook);
  await db.insertStatisticsTombstone('Video A', FushiDatabase.statSourceVideo);
  await db.writeSyncDeletionTombstone(
    SyncTombstoneKind.favoriteword.dbValue,
    FushiDatabase.favoriteWordItemKey('w1', 'r1', 'book'),
    2000,
  );
  await db.writeSyncDeletionTombstone(
    kFavoriteSentenceTombstoneType,
    FavoriteSentenceRepository.itemKeyOf(sentence),
    2000,
  );
}

void main() {
  test('filterTombstoned 逐条剔除已立碑的统计/收藏，保留其余', () async {
    final FushiDatabase db = await _freshDb('agg_filter_');
    addTearDown(db.close);
    final FavoriteSentence sentence = _sentence();
    await _tombstoneEverything(db, sentence);

    final AggregateSnapshot filtered = await AggregateSyncService(db)
        .filterTombstoned(_peerSnapshot(sentence));

    expect(filtered.readingStats.map((ReadingStatRecord r) => r.title),
        <String>['Book B']);
    expect(filtered.videoStats, isEmpty);
    expect(filtered.lookupMiningCounters, isEmpty);
    expect(filtered.favoriteWords.map((FavoriteWordRecord r) => r.expression),
        <String>['w2']);
    expect(filtered.favoriteSentences, isEmpty);
  });

  test('无任何墓碑时 filterTombstoned 原样返回（零拷贝）', () async {
    final FushiDatabase db = await _freshDb('agg_filter_noop_');
    addTearDown(db.close);
    final AggregateSnapshot snap = _peerSnapshot(_sentence());
    expect(
      identical(await AggregateSyncService(db).filterTombstoned(snap), snap),
      isTrue,
    );
  });

  test('云通道：push 的 payload 不含已立碑的条目', () async {
    final FushiDatabase db = await _freshDb('agg_push_cloud_');
    addTearDown(db.close);
    final FavoriteSentence sentence = _sentence();
    await _tombstoneEverything(db, sentence);

    final FakeAssetStore store = FakeAssetStore();
    final String ns = await store.ensureNamespace(kSyncAggregateNamespace);
    await store.putJsonAsset(
        ns, 'dev-B.fushiaggregate', _peerSnapshot(sentence).toJson());

    final bool pushed =
        await AggregateSyncService(db).sync(store: store, deviceId: 'dev-A');
    expect(pushed, isTrue, reason: 'Book B 仍需发布，裁剪不是整份跳过');

    final AssetEntry? own = await store.findAsset(ns, 'dev-A.fushiaggregate');
    expect(own, isNotNull);
    final AggregateSnapshot outgoing =
        AggregateSnapshot.fromJson(await store.getJsonAsset(own!.id));

    expect(outgoing.readingStats.map((ReadingStatRecord r) => r.title),
        isNot(contains('Book A')));
    expect(outgoing.readingStats.map((ReadingStatRecord r) => r.title),
        contains('Book B'));
    expect(outgoing.videoStats, isEmpty);
    expect(outgoing.lookupMiningCounters, isEmpty);
    expect(outgoing.favoriteWords.map((FavoriteWordRecord r) => r.expression),
        <String>['w2']);
    expect(outgoing.favoriteSentences, isEmpty);
  });

  test('互联通道：pushMerged 收到的 payload 不含已立碑的条目', () async {
    final FushiDatabase db = await _freshDb('agg_push_live_');
    addTearDown(db.close);
    final FavoriteSentence sentence = _sentence();
    await _tombstoneEverything(db, sentence);

    Object? pushedJson;
    await AggregateSyncService(db).syncOverClient(
      fetchRemote: () async => _peerSnapshot(sentence).toJson(),
      pushMerged: (Object json) async => pushedJson = json,
    );

    expect(pushedJson, isNotNull);
    final AggregateSnapshot outgoing = AggregateSnapshot.fromJson(pushedJson);
    expect(outgoing.readingStats.map((ReadingStatRecord r) => r.title),
        <String>['Book B']);
    expect(outgoing.videoStats, isEmpty);
    expect(outgoing.lookupMiningCounters, isEmpty);
    expect(outgoing.favoriteWords.map((FavoriteWordRecord r) => r.expression),
        <String>['w2']);
    expect(outgoing.favoriteSentences, isEmpty);
    // wire 形状没变（仍是可解回的 JSON map）。
    expect(jsonEncode(pushedJson), contains('Book B'));
  });

  test('全部条目都被立碑时不推空快照', () async {
    final FushiDatabase db = await _freshDb('agg_push_allgone_');
    addTearDown(db.close);
    final FavoriteSentence sentence = _sentence();
    await db.writeSyncDeletionTombstone(
      kFavoriteSentenceTombstoneType,
      FavoriteSentenceRepository.itemKeyOf(sentence),
      2000,
    );

    bool pushCalled = false;
    await AggregateSyncService(db).syncOverClient(
      fetchRemote: () async =>
          AggregateSnapshot(favoriteSentences: <FavoriteSentence>[sentence])
              .toJson(),
      pushMerged: (Object json) async {
        pushCalled = true;
      },
    );
    expect(pushCalled, isFalse);
  });
}
