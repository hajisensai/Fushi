import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/aggregate_sync_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import 'temp_dir_cleanup.dart';

/// 互联「共享统计 / 共享收藏夹」两个开关。
///
/// 聚合快照的字段天然分成互不重叠的两族（统计族 / 收藏族），两个开关各管一族。
/// 这里锁三件事：
///   ① 纯函数 [AggregateSnapshot.select] 的裁剪是整族的、且两族互不牵连；
///   ② 裁剪对**上下行都生效**——只裁上行的话，关掉开关后对端数据仍会折进本地，
///      用户看到的是「关了还在同步」；
///   ③ 两族都关时整轮 no-op，连请求都不发。
Future<FushiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  return FushiDatabase(dir.path);
}

FavoriteSentence _sentence() => FavoriteSentence(
      id: 'fav-peer',
      text: '対端の文',
      bookTitle: 'Peer Book',
      bookKey: 'bk-peer',
      sectionIndex: 0,
      normCharOffset: 10,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

/// 一份两族齐全的对端快照。
AggregateSnapshot _peerSnapshot() => AggregateSnapshot(
      readingStats: const <ReadingStatRecord>[
        ReadingStatRecord(
          title: 'Peer Book',
          dateKey: '2026-06-01',
          charactersRead: 120,
          readingTimeMs: 60000,
          lastStatisticModified: 10,
        ),
      ],
      videoStats: const <VideoStatRecord>[
        VideoStatRecord(
          title: 'Peer Video',
          dateKey: '2026-06-01',
          subtitleChars: 50,
          watchTimeMs: 30000,
          lastModified: 12,
        ),
      ],
      lookupMiningCounters: const <LookupMiningRecord>[
        LookupMiningRecord(
          bookKey: 'bk-peer',
          title: 'Peer Book',
          sourceType: 'book',
          dateKey: '2026-06-01',
          lookupCount: 7,
          mineCount: 3,
        ),
      ],
      favoriteWords: const <FavoriteWordRecord>[
        FavoriteWordRecord(
          expression: 'peerword',
          reading: 'r1',
          glossary: 'g1',
          sourceType: 'book',
          dateKey: '2026-06-01',
          createdAt: 100,
        ),
      ],
      favoriteSentences: <FavoriteSentence>[_sentence()],
    );

void main() {
  group('AggregateSnapshot.select 按族裁剪', () {
    test('只共享统计：收藏族整族清空，统计族原样保留', () {
      final AggregateSnapshot out =
          _peerSnapshot().select(stats: true, favorites: false);

      expect(out.readingStats, hasLength(1));
      expect(out.videoStats, hasLength(1));
      expect(out.lookupMiningCounters, hasLength(1));
      expect(out.favoriteWords, isEmpty);
      expect(out.favoriteSentences, isEmpty);
    });

    test('只共享收藏：统计族整族清空，收藏族原样保留', () {
      final AggregateSnapshot out =
          _peerSnapshot().select(stats: false, favorites: true);

      expect(out.readingStats, isEmpty);
      expect(out.videoStats, isEmpty);
      expect(out.lookupMiningCounters, isEmpty);
      expect(out.favoriteWords, hasLength(1));
      expect(out.favoriteSentences, hasLength(1));
    });

    test('收藏关掉时，取消收藏的墓碑也不外流', () {
      final AggregateSnapshot withTombstones = AggregateSnapshot(
        favoriteWordTombstones: const <AggregateTombstoneRecord>[
          AggregateTombstoneRecord(itemKey: 'k1', deletedAt: 5),
        ],
        favoriteSentenceTombstones: const <AggregateTombstoneRecord>[
          AggregateTombstoneRecord(itemKey: 'k2', deletedAt: 6),
        ],
      );

      final AggregateSnapshot out =
          withTombstones.select(stats: true, favorites: false);
      expect(out.favoriteWordTombstones, isEmpty);
      expect(out.favoriteSentenceTombstones, isEmpty);
    });

    test('两族都许可时零拷贝返回入参本身', () {
      final AggregateSnapshot snap = _peerSnapshot();
      expect(
          identical(snap.select(stats: true, favorites: true), snap), isTrue);
    });

    test('两族都不许可时是空快照', () {
      expect(_peerSnapshot().select(stats: false, favorites: false).isEmpty,
          isTrue);
    });
  });

  group('syncOverClient 的许可裁剪（上下行都要生效）', () {
    test('关掉共享收藏：上行 payload 无收藏族，且对端收藏不落本地库', () async {
      final FushiDatabase db = await _freshDb('agg_share_fav_off_');
      addTearDown(db.close);

      Object? pushedJson;
      await AggregateSyncService(db).syncOverClient(
        fetchRemote: () async => _peerSnapshot().toJson(),
        pushMerged: (Object json) async => pushedJson = json,
        shareStats: true,
        shareFavorites: false,
      );

      final AggregateSnapshot outgoing = AggregateSnapshot.fromJson(pushedJson);
      expect(outgoing.readingStats.map((ReadingStatRecord r) => r.title),
          contains('Peer Book'),
          reason: '统计仍许可，必须照常共享');
      expect(outgoing.favoriteWords, isEmpty);
      expect(outgoing.favoriteSentences, isEmpty);

      // 下行：对端的收藏词不得被折进本地库。
      expect(await db.getAllFavoriteWords(), isEmpty);
    });

    test('关掉共享统计：上行 payload 无统计族，且对端统计不落本地库', () async {
      final FushiDatabase db = await _freshDb('agg_share_stats_off_');
      addTearDown(db.close);

      Object? pushedJson;
      await AggregateSyncService(db).syncOverClient(
        fetchRemote: () async => _peerSnapshot().toJson(),
        pushMerged: (Object json) async => pushedJson = json,
        shareStats: false,
        shareFavorites: true,
      );

      final AggregateSnapshot outgoing = AggregateSnapshot.fromJson(pushedJson);
      expect(outgoing.readingStats, isEmpty);
      expect(outgoing.videoStats, isEmpty);
      expect(outgoing.lookupMiningCounters, isEmpty);
      expect(outgoing.favoriteWords.map((FavoriteWordRecord r) => r.expression),
          contains('peerword'),
          reason: '收藏仍许可，必须照常共享');

      // 下行：对端的阅读统计不得被折进本地库。
      expect(await db.getAllReadingStatistics(), isEmpty);
    });

    test('两个都关：不发请求，也不推任何东西', () async {
      final FushiDatabase db = await _freshDb('agg_share_both_off_');
      addTearDown(db.close);

      bool fetched = false;
      bool pushed = false;
      await AggregateSyncService(db).syncOverClient(
        fetchRemote: () async {
          fetched = true;
          return _peerSnapshot().toJson();
        },
        pushMerged: (Object json) async => pushed = true,
        shareStats: false,
        shareFavorites: false,
      );

      expect(fetched, isFalse, reason: '关掉了就不该再问对端要数据');
      expect(pushed, isFalse);
    });

    test('老 host（fetchRemote 返回 null）的退化推送同样过裁剪', () async {
      final FushiDatabase db = await _freshDb('agg_share_oldhost_');
      addTearDown(db.close);
      // 本机有一条收藏词，作为唯一可推内容。
      await db.addFavoriteWord(
        expression: 'localword',
        reading: 'r',
        glossary: 'g',
        sourceType: 'book',
        dateKey: '2026-06-01',
      );

      Object? pushedJson;
      await AggregateSyncService(db).syncOverClient(
        fetchRemote: () async => null,
        pushMerged: (Object json) async => pushedJson = json,
        shareStats: true,
        shareFavorites: false,
      );

      // 收藏关掉后本机没有任何可共享内容 → 退化路径也不该推空快照。
      expect(pushedJson, isNull);
    });
  });

  group('偏好键默认值', () {
    test('共享统计 / 共享收藏夹默认开启，且可持久化关掉', () async {
      final FushiDatabase db = await _freshDb('agg_share_prefs_');
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(await repo.isInterconnectSyncStatsEnabled(), isTrue);
      expect(await repo.isInterconnectSyncFavoritesEnabled(), isTrue);

      await repo.setInterconnectSyncStatsEnabled(false);
      await repo.setInterconnectSyncFavoritesEnabled(false);

      expect(await repo.isInterconnectSyncStatsEnabled(), isFalse);
      expect(await repo.isInterconnectSyncFavoritesEnabled(), isFalse);
    });

    test('两个开关互不牵连', () async {
      final FushiDatabase db = await _freshDb('agg_share_prefs_indep_');
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setInterconnectSyncStatsEnabled(false);

      expect(await repo.isInterconnectSyncFavoritesEnabled(), isTrue);
    });
  });
}
