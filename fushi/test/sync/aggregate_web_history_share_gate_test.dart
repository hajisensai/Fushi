import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

import 'fake_asset_store.dart';

/// 浏览历史不跟「共享收藏夹」走（批量合并审查 B）：v128 把浏览历史挂在收藏族下，
/// 已开共享收藏的存量用户升级后第一轮同步就把整份浏览轨迹推到云端 / 互联 host。
/// 现在历史是独立一族，由设备级「同步浏览历史」（`kSyncWebHistoryPrefKey`，缺行 =
/// 关）代管，上下行一起裁；host 侧按 host 本机的同一开关决定发不发 / 收不收。
const WebHistoryRecord _localVisit = WebHistoryRecord(
  url: 'https://local-secret/',
  title: 'L',
  lastVisitedAt: 100,
  visitCount: 1,
);
const WebHistoryRecord _remoteVisit = WebHistoryRecord(
  url: 'https://remote-secret/',
  title: 'R',
  lastVisitedAt: 200,
  visitCount: 1,
);
const WebBookmarkRecord _bookmark = WebBookmarkRecord(
  uid: 'bm1',
  parentUid: null,
  title: 'B',
  url: 'https://bookmark/',
  position: 0,
  createdAt: 1,
  updatedAt: 1,
);

Future<void> _seedLocal(FushiDatabase db) async {
  await AggregateSyncService(db).foldIntoLocal(
    const AggregateSnapshot(
      webHistory: <WebHistoryRecord>[_localVisit],
      webBookmarks: <WebBookmarkRecord>[_bookmark],
    ),
  );
}

Future<Set<String>> _historyUrls(FushiDatabase db) async => <String>{
  for (final WebHistoryRecord r in (await AggregateSyncService(
    db,
  ).materializeLocalSnapshot()).webHistory)
    r.url,
};

void main() {
  late FushiDatabase db;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await _seedLocal(db);
  });
  tearDown(() => db.close());

  test('开关缺行即关；设备本地键不随备份出境', () async {
    expect(await readWebHistorySyncEnabled(db), isFalse);
    expect(await SyncRepository(db).isWebHistorySyncEnabled(), isFalse);
    await SyncRepository(db).setWebHistorySyncEnabled(true);
    expect(await readWebHistorySyncEnabled(db), isTrue);
    expect(
      SyncRepository.deviceLocalPrefKeys,
      contains(kSyncWebHistoryPrefKey),
    );
  });

  group('互联 client（syncOverClient）', () {
    Future<Map<String, Object?>?> runRound({required bool history}) async {
      Map<String, Object?>? pushed;
      await AggregateSyncService(db).syncOverClient(
        fetchRemote: () async => const AggregateSnapshot(
          webHistory: <WebHistoryRecord>[_remoteVisit],
        ).toJson(),
        pushMerged: (Object json) async =>
            pushed = (json as Map<Object?, Object?>).cast<String, Object?>(),
        shareStats: true,
        shareFavorites: true,
        shareWebHistory: history,
      );
      return pushed;
    }

    test('已开共享收藏、历史开关默认关：历史两个方向都不动，书签照常', () async {
      final Map<String, Object?>? pushed = await runRound(history: false);
      final AggregateSnapshot out = AggregateSnapshot.fromJson(pushed);
      expect(out.webHistory, isEmpty, reason: '本机浏览历史不得推给 host');
      expect(out.webBookmarks.single.uid, 'bm1');
      expect(await _historyUrls(db), <String>{
        _localVisit.url,
      }, reason: 'host 的历史不得折进本机');
    });

    test('显式打开后历史双向合并', () async {
      final Map<String, Object?>? pushed = await runRound(history: true);
      final AggregateSnapshot out = AggregateSnapshot.fromJson(pushed);
      expect(
        out.webHistory.map((WebHistoryRecord r) => r.url).toSet(),
        <String>{_localVisit.url, _remoteVisit.url},
      );
      expect(await _historyUrls(db), <String>{
        _localVisit.url,
        _remoteVisit.url,
      });
    });

    test('统计 / 收藏都关、只开历史：仍只同步历史族', () async {
      Map<String, Object?>? pushed;
      await AggregateSyncService(db).syncOverClient(
        fetchRemote: () async => null,
        pushMerged: (Object json) async =>
            pushed = (json as Map<Object?, Object?>).cast<String, Object?>(),
        shareStats: false,
        shareFavorites: false,
        shareWebHistory: true,
      );
      final AggregateSnapshot out = AggregateSnapshot.fromJson(pushed);
      expect(out.webHistory.single.url, _localVisit.url);
      expect(out.webBookmarks, isEmpty);
    });
  });

  group('云通道（sync）', () {
    test('默认不上传、不折入对端历史；打开后才上传', () async {
      final FakeAssetStore store = FakeAssetStore();
      final String ns = await store.ensureNamespace(kSyncAggregateNamespace);
      await store.putJsonAsset(
        ns,
        'peer.fushiaggregate',
        const AggregateSnapshot(
          webHistory: <WebHistoryRecord>[_remoteVisit],
        ).toJson(),
      );
      final AggregateSyncService svc = AggregateSyncService(db);

      await svc.sync(store: store, deviceId: 'me', shareStats: true);
      final AssetEntry? own = await store.findAsset(ns, 'me.fushiaggregate');
      final AggregateSnapshot uploaded = AggregateSnapshot.fromJson(
        await store.getJsonAsset(own!.id),
      );
      expect(uploaded.webHistory, isEmpty);
      expect(uploaded.webBookmarks.single.uid, 'bm1');
      expect(await _historyUrls(db), <String>{_localVisit.url});

      await svc.sync(
        store: store,
        deviceId: 'me',
        shareStats: true,
        shareWebHistory: true,
      );
      final AggregateSnapshot again = AggregateSnapshot.fromJson(
        await store.getJsonAsset(own.id),
      );
      expect(
        again.webHistory.map((WebHistoryRecord r) => r.url).toSet(),
        <String>{_localVisit.url, _remoteVisit.url},
      );
    });
  });

  group('互联 host（getAggregateSnapshot / applyAggregateSnapshot）', () {
    LocalLibraryHostService host() => LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );

    test('host 未开历史开关：不发出本机历史，也不收对端历史', () async {
      final LocalLibraryHostService h = host();
      final AggregateSnapshot served = await h.getAggregateSnapshot();
      expect(served.webHistory, isEmpty);
      expect(served.webBookmarks.single.uid, 'bm1');

      await h.applyAggregateSnapshot(
        const AggregateSnapshot(webHistory: <WebHistoryRecord>[_remoteVisit]),
      );
      expect(await _historyUrls(db), <String>{_localVisit.url});
    });

    test('host 打开后两个方向都参与', () async {
      await db.setPrefTyped<bool>(kSyncWebHistoryPrefKey, true);
      final LocalLibraryHostService h = host();
      expect(
        (await h.getAggregateSnapshot()).webHistory.single.url,
        _localVisit.url,
      );
      await h.applyAggregateSnapshot(
        const AggregateSnapshot(webHistory: <WebHistoryRecord>[_remoteVisit]),
      );
      expect(await _historyUrls(db), <String>{
        _localVisit.url,
        _remoteVisit.url,
      });
    });
  });
}
