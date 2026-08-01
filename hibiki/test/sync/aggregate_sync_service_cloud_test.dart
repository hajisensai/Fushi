import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/aggregate_snapshot.dart';
import 'package:hibiki/src/sync/aggregate_sync_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
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

  test('hourly formats: materialize splits, old-peer totals lift unattributed',
      () async {
    // v67：本地按写入面分桶（epub 20s + manga 10s，同一小时）。
    final HibikiDatabase db = await _freshDb('agg_hourly_fmt_');
    addTearDown(db.close);
    await db.addHourlyReadingTime(
        dateKey: '2026-06-01',
        hour: 9,
        deltaMs: 20000,
        format: BookFormat.epub);
    await db.addHourlyReadingTime(
        dateKey: '2026-06-01',
        hour: 9,
        deltaMs: 10000,
        format: BookFormat.manga);

    final AggregateSyncService svc = AggregateSyncService(db);
    final AggregateSnapshot snap = await svc.materializeLocalSnapshot();
    // 旧 wire 字段 = 该小时全部阅读面之和（旧端看到的语义与拆分前一致）；
    // 拆分数据走 readingHourlyByFormat。
    expect(snap.readingHourly.single.durationMs, 30000);
    expect(snap.readingHourlyByFormat, hasLength(2));

    // 自我重放幂等：不产生未区分桶、不改变任何行。
    await svc.applySnapshotToLocal(snap);
    expect(await db.getHourlyLogsForDate('2026-06-01'), hasLength(2));

    // 旧端 peer 只带逐时总量 45s（不带 format）：与本地 30s 之差 15s 无法归因
    // 到任何写入面 → 落 ''（未区分）桶；已归因的 epub/manga 桶原样不动。
    const AggregateSnapshot oldPeer = AggregateSnapshot(
      readingHourly: <HourlyRecord>[
        HourlyRecord(dateKey: '2026-06-01', hour: 9, durationMs: 45000),
      ],
    );
    final AggregateSnapshot merged =
        AggregateSyncService.mergeSnapshots(snap, oldPeer);
    await svc.applySnapshotToLocal(merged);
    List<ReadingHourlyLogRow> logs =
        await db.getHourlyLogsForDate('2026-06-01');
    expect(logs, hasLength(3));
    expect(
        logs
            .singleWhere((l) => l.format == BookFormat.epub.dbValue)
            .readingTimeMs,
        20000);
    expect(
        logs
            .singleWhere((l) => l.format == BookFormat.manga.dbValue)
            .readingTimeMs,
        10000);
    expect(logs.singleWhere((l) => l.format.isEmpty).readingTimeMs, 15000);

    // 重复应用同一 merged 快照：差额为 0，幂等（不虚增未区分桶）。
    await svc.applySnapshotToLocal(merged);
    logs = await db.getHourlyLogsForDate('2026-06-01');
    expect(logs, hasLength(3));
    expect(logs.singleWhere((l) => l.format.isEmpty).readingTimeMs, 15000);
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

  test('取消收藏句后 peer 快照并集不复活（favoritesentence 墓碑抑制）', () async {
    final HibikiDatabase db = await _freshDb('agg_fs_tomb_');
    addTearDown(db.close);
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
    final FavoriteSentence s = FavoriteSentence(
      id: 'hl_x',
      text: '消したい文',
      bookTitle: 'BookA',
      bookKey: 'a',
      sectionIndex: 0,
      normCharOffset: 7,
      createdAt: DateTime.fromMillisecondsSinceEpoch(100),
    );
    // 收藏后取消 → 本地删掉 + 写墓碑。
    await repo.add(s);
    await repo.removeById('hl_x');
    expect(await repo.getAll(), isEmpty);

    // peer 快照仍带同一句（不同 id / 较晚 createdAt）→ 应用后**不得**复活。
    final AggregateSnapshot peer = AggregateSnapshot(
      favoriteSentences: <FavoriteSentence>[
        FavoriteSentence(
          id: 'hl_peer',
          text: '消したい文',
          bookTitle: 'BookA',
          bookKey: 'a',
          sectionIndex: 0,
          normCharOffset: 7,
          createdAt: DateTime.fromMillisecondsSinceEpoch(900),
        ),
      ],
    );
    await AggregateSyncService(db).applySnapshotToLocal(peer);
    expect(await repo.getAll(), isEmpty, reason: '有墓碑 → 并集不复活');

    // 重新收藏 → 清碑；此后 peer 快照的同句可正常并入。
    await repo.add(s);
    await AggregateSyncService(db).applySnapshotToLocal(peer);
    expect((await repo.getAll()).single.text, '消したい文');
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

  test('two devices converge lookup/mine counters to the per-column union',
      () async {
    final FakeAssetStore store = FakeAssetStore();

    final HibikiDatabase dbA = await _freshDb('agg_lmcA_');
    addTearDown(dbA.close);
    // A: 10 lookups, 2 mines on Book A / 2026-06-01, plus a no-book lookup.
    await dbA.setLookupCount(
      bookKey: 'keyA',
      title: 'Book A',
      sourceType: 'book',
      dateKey: '2026-06-01',
      count: 10,
    );
    await dbA.setMineCountPerBook(
      bookKey: 'keyA',
      title: 'Book A',
      sourceType: 'book',
      dateKey: '2026-06-01',
      count: 2,
    );
    await dbA.setLookupCount(
      title: '', // no-book lookup (home / standalone window / lyrics)
      sourceType: 'book',
      dateKey: '2026-06-01',
      count: 7,
    );
    await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');

    final HibikiDatabase dbB = await _freshDb('agg_lmcB_');
    addTearDown(dbB.close);
    // B: 4 lookups (lower), 9 mines (higher) on the same bucket.
    await dbB.setLookupCount(
      bookKey: 'keyA',
      title: 'Book A',
      sourceType: 'book',
      dateKey: '2026-06-01',
      count: 4,
    );
    await dbB.setMineCountPerBook(
      bookKey: 'keyA',
      title: 'Book A',
      sourceType: 'book',
      dateKey: '2026-06-01',
      count: 9,
    );
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');

    // B holds the union: lookup MAX(10,4)=10, mine MAX(2,9)=9 on the shared
    // bucket, plus A's no-book lookup bucket (title='').
    final List<LookupMiningCounterRow> bRows =
        await dbB.getLookupMiningCountersBySource('book');
    final LookupMiningCounterRow bShared =
        bRows.firstWhere((LookupMiningCounterRow r) => r.title == 'Book A');
    expect(bShared.lookupCount, 10);
    expect(bShared.mineCount, 9);
    expect(bShared.bookKey, 'keyA');
    final LookupMiningCounterRow bNoBook =
        bRows.firstWhere((LookupMiningCounterRow r) => r.title == '');
    expect(bNoBook.lookupCount, 7);

    // A syncs again and converges to the identical union; re-sync stays MAX,
    // never SUM (idempotent, no double count).
    await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
    await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
    final LookupMiningCounterRow aShared =
        (await dbA.getLookupMiningCountersBySource('book'))
            .firstWhere((LookupMiningCounterRow r) => r.title == 'Book A');
    expect(aShared.lookupCount, 10);
    expect(aShared.mineCount, 9);
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

  test('取消收藏词写墓碑后 peer 快照并集不复活；重新收藏清碑可再并入', () async {
    // 删除传播上线后行为更新：`removeFavoriteWord` 默认写 favoriteword 墓碑，
    // `applySnapshotToLocal` 跳过有碑收藏 → 取消收藏不再被 peer 并集复活（旧「delete does
    // not propagate」断言已随删除传播作废）。
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
    // 取消收藏 → 本地删 + 写墓碑。
    await dbB.removeFavoriteWord(
        expression: 'wShared', reading: 'r', sourceType: 'book');
    expect((await dbB.getAllFavoriteWords()).isEmpty, isTrue);

    // A 的快照仍带 wShared；B 再同步折进 merged，但墓碑令 applySnapshotToLocal 跳过它
    // → 保持删除（删除传播生效）。
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
    expect((await dbB.getAllFavoriteWords()).isEmpty, isTrue,
        reason: '墓碑抑制并集复活');

    // 重新收藏 → 清碑；此后 peer 快照的同词可正常并入（「重加清墓碑」语义）。
    await dbB.addFavoriteWord(
      expression: 'wShared',
      reading: 'r',
      glossary: 'g',
      sourceType: 'book',
      dateKey: '2026-06-02',
    );
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
    expect((await dbB.getAllFavoriteWords()).length, 1);
  });

  test(
      'a tombstoned book stat is NOT resurrected by a peer snapshot '
      '(TODO-1204 后续)', () async {
    final FakeAssetStore store = FakeAssetStore();
    final HibikiDatabase dbA = await _freshDb('agg_tombA_');
    addTearDown(dbA.close);
    await dbA.addReadingStatistic(
        title: 'Ghost', dateKey: '2026-06-01', charsRead: 100, timeMs: 6000);
    await dbA.addLookupCount(
        bookKey: 'book/Ghost',
        title: 'Ghost',
        sourceType: 'book',
        dateKey: '2026-06-01');
    await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');

    final HibikiDatabase dbB = await _freshDb('agg_tombB_');
    addTearDown(dbB.close);
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
    expect((await dbB.getAllReadingStatistics()).length, 1,
        reason: 'B pulled Ghost from A');

    // User deletes Ghost's stats on B -> local rows gone + tombstone written.
    await dbB.deleteReadingStatisticsForTitle('Ghost');
    expect(await dbB.getAllReadingStatistics(), isEmpty);

    // A's snapshot still carries Ghost; a re-sync folds it into merged, but the
    // tombstone must make applySnapshotToLocal skip it -> Ghost stays gone.
    await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
    expect(await dbB.getAllReadingStatistics(), isEmpty,
        reason: 'tombstone blocks resurrection of the deleted book stat');
    expect(await dbB.getLookupMiningCountersBySource('book'), isEmpty,
        reason: 'tombstone also blocks the lookup counter resurrection');

    // Re-reading Ghost on B clears the tombstone; future syncs may revive it
    // (matching the "重加书清墓碑" intent).
    await dbB.addReadingStatistic(
        title: 'Ghost', dateKey: '2026-06-02', charsRead: 5, timeMs: 60);
    expect(await dbB.getStatisticsTombstoneKeys(),
        isNot(contains(('Ghost', 'book'))));
  });
}
