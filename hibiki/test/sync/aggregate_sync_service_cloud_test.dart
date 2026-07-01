import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/aggregate_snapshot.dart';
import 'package:hibiki/src/sync/aggregate_sync_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

// Cloud-channel tests for the aggregate sync dimension (TODO-1056 phase B):
// a real on-disk HibikiDatabase + the in-memory FakeAssetStore standing in for
// a cloud backend. They pin the DB materialise/apply round-trip, the per-device
// snapshot layout, two-device union over the store, second-sync idempotency,
// and the first-sync (empty namespace) no-op degradation.

Future<HibikiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  return HibikiDatabase(dir.path);
}

void main() {
  test('materialize then apply on empty peer round-trips local state',
      () async {
    final HibikiDatabase db = await _freshDb('agg_rt_');
    addTearDown(db.close);
    await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'Book A',
      dateKey: '2026-06-01',
      charactersRead: 120,
      readingTimeMs: 60000,
      lastStatisticModified: 10,
    ));
    await db.setMiningCount(
        sourceType: 'book', dateKey: '2026-06-01', count: 5);
    await db.addFavoriteWord(
      expression: 'w1',
      reading: 'r1',
      glossary: 'g1',
      sourceType: 'book',
      dateKey: '2026-06-01',
    );

    final AggregateSyncService svc = AggregateSyncService(db);
    final AggregateSnapshot snap = await svc.materializeLocalSnapshot();
    expect(snap.readingStats.single.charactersRead, 120);
    expect(snap.miningStats.single.count, 5);
    expect(snap.favoriteWords.single.expression, 'w1');

    // Applying the same snapshot back is a no-op (values unchanged).
    await svc.applySnapshotToLocal(snap);
    final List<ReadingStatisticRow> reading =
        await db.getAllReadingStatistics();
    expect(reading.single.charactersRead, 120);
    expect((await db.getMiningStatisticsBySource('book')).single.count, 5);
    expect((await db.getAllFavoriteWords()).length, 1);
  });

  test('first sync with empty namespace uploads own snapshot, no crash',
      () async {
    final HibikiDatabase db = await _freshDb('agg_first_');
    addTearDown(db.close);
    await db.setMiningCount(
        sourceType: 'book', dateKey: '2026-06-01', count: 2);

    final FakeAssetStore store = FakeAssetStore();
    await AggregateSyncService(db).sync(store: store, deviceId: 'dev-A');

    final String ns = await store.ensureNamespace(kSyncAggregateNamespace);
    final List<AssetEntry> children = await store.listChildren(ns);
    expect(children.length, 1);
    expect(children.single.name, 'dev-A.hibikiaggregate');
    final Object? json = await store.getJsonAsset(children.single.id);
    final AggregateSnapshot uploaded = AggregateSnapshot.fromJson(json);
    expect(uploaded.miningStats.single.count, 2);
  });

  test('empty device with empty namespace uploads nothing', () async {
    final HibikiDatabase db = await _freshDb('agg_empty_');
    addTearDown(db.close);
    final FakeAssetStore store = FakeAssetStore();
    await AggregateSyncService(db).sync(store: store, deviceId: 'dev-A');
    final String ns = await store.ensureNamespace(kSyncAggregateNamespace);
    expect((await store.listChildren(ns)).isEmpty, isTrue);
  });

  test('two devices converge to the union via the store', () async {
    final FakeAssetStore store = FakeAssetStore();

    final HibikiDatabase dbA = await _freshDb('agg_A_');
    addTearDown(dbA.close);
    await dbA.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'Book A',
      dateKey: '2026-06-01',
      charactersRead: 100,
      readingTimeMs: 1000,
      lastStatisticModified: 1,
    ));
    await dbA.setMiningCount(
        sourceType: 'book', dateKey: '2026-06-01', count: 3);
    await dbA.addFavoriteWord(
      expression: 'wA',
      reading: 'rA',
      glossary: 'gA',
      sourceType: 'book',
      dateKey: '2026-06-01',
    );
    await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');

    final HibikiDatabase dbB = await _freshDb('agg_B_');
    addTearDown(dbB.close);
    await dbB.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'Book A',
      dateKey: '2026-06-01',
      charactersRead: 40,
      readingTimeMs: 5000,
      lastStatisticModified: 2,
    ));
    await dbB.setMiningCount(
        sourceType: 'book', dateKey: '2026-06-01', count: 8);
    await dbB.addFavoriteWord(
      expression: 'wB',
      reading: 'rB',
      glossary: 'gB',
      sourceType: 'book',
      dateKey: '2026-06-01',
    );
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');

    // B holds the union: mining MAX(3,8)=8, chars MAX(100,40)=100,
    // readingTimeMs MAX(1000,5000)=5000, both favorite words.
    expect((await dbB.getMiningStatisticsBySource('book')).single.count, 8);
    final ReadingStatisticRow bReading =
        (await dbB.getAllReadingStatistics()).single;
    expect(bReading.charactersRead, 100);
    expect(bReading.readingTimeMs, 5000);
    final Set<String> bWords = (await dbB.getAllFavoriteWords())
        .map((FavoriteWordRow w) => w.expression)
        .toSet();
    expect(bWords, <String>{'wA', 'wB'});

    // A syncs again and converges to the same union.
    await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
    expect((await dbA.getMiningStatisticsBySource('book')).single.count, 8);
    final Set<String> aWords = (await dbA.getAllFavoriteWords())
        .map((FavoriteWordRow w) => w.expression)
        .toSet();
    expect(aWords, <String>{'wA', 'wB'});
    final ReadingStatisticRow aReading =
        (await dbA.getAllReadingStatistics()).single;
    expect(aReading.charactersRead, 100);
    expect(aReading.readingTimeMs, 5000);
  });

  test('re-syncing the same peer snapshot is idempotent (no double count)',
      () async {
    final FakeAssetStore store = FakeAssetStore();

    final HibikiDatabase dbA = await _freshDb('agg_idA_');
    addTearDown(dbA.close);
    await dbA.setMiningCount(
        sourceType: 'book', dateKey: '2026-06-01', count: 4);
    await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');

    final HibikiDatabase dbB = await _freshDb('agg_idB_');
    addTearDown(dbB.close);
    await dbB.setMiningCount(
        sourceType: 'book', dateKey: '2026-06-01', count: 4);
    // Sync twice: MAX(4,4) stays 4, never 8. Idempotent, no SUM.
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
    expect((await dbB.getMiningStatisticsBySource('book')).single.count, 4);
  });

  test('union re-adds a peer-still-present word; delete does not propagate',
      () async {
    final FakeAssetStore store = FakeAssetStore();

    final HibikiDatabase dbA = await _freshDb('agg_delA_');
    addTearDown(dbA.close);
    await dbA.addFavoriteWord(
      expression: 'wShared',
      reading: 'r',
      glossary: 'g',
      sourceType: 'book',
      dateKey: '2026-06-01',
    );
    await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');

    final HibikiDatabase dbB = await _freshDb('agg_delB_');
    addTearDown(dbB.close);
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
    expect((await dbB.getAllFavoriteWords()).length, 1);
    await dbB.removeFavoriteWord(
        expression: 'wShared', reading: 'r', sourceType: 'book');
    expect((await dbB.getAllFavoriteWords()).isEmpty, isTrue);

    // The aggregate model is union / only-grows: a peer snapshot that still
    // carries the word re-adds it on B. Deletion propagation is a deliberate
    // non-goal (a delete must be performed on every device).
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
    expect((await dbB.getAllFavoriteWords()).length, 1);
  });
}
