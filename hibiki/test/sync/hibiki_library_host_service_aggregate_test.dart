import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/aggregate_snapshot.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1056 phase C host-service 聚合端点测试：互联 `/api/library/aggregate` 的
/// service 层 getAggregateSnapshot / applyAggregateSnapshot 必须复用云后端 phase B
/// 的 AggregateSyncService（materialize/apply），保证 MAX / 并集 / 幂等语义在互联
/// 通道与云通道完全一致（不是第二套实现）。
AppModelLibraryHostService _svc(HibikiDatabase db) =>
    AppModelLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('getAggregateSnapshot（materialize host DB）', () {
    test('空库 → 空快照', () async {
      final AggregateSnapshot snap = await _svc(db).getAggregateSnapshot();
      expect(snap.isEmpty, isTrue);
    });

    test('有统计 + 挖掘 + 收藏词 → 快照带回真实字段', () async {
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

      final AggregateSnapshot snap = await _svc(db).getAggregateSnapshot();
      expect(snap.readingStats.single.charactersRead, 120);
      expect(snap.miningStats.single.count, 5);
      expect(snap.favoriteWords.single.expression, 'w1');
    });
  });

  group('applyAggregateSnapshot（host-apply：真写统计/收藏 DB）', () {
    test('空 host 收到 client 快照 → MAX / 并集写入本机 DB', () async {
      final AppModelLibraryHostService svc = _svc(db);
      final AggregateSnapshot incoming = AggregateSnapshot(
        readingStats: const <ReadingStatRecord>[
          ReadingStatRecord(
            title: 'Book A',
            dateKey: '2026-06-01',
            charactersRead: 200,
            readingTimeMs: 7000,
            lastStatisticModified: 3,
          ),
        ],
        miningStats: const <MiningRecord>[
          MiningRecord(sourceType: 'book', dateKey: '2026-06-01', count: 9),
        ],
        favoriteWords: const <FavoriteWordRecord>[
          FavoriteWordRecord(
            expression: 'wX',
            reading: 'rX',
            glossary: 'gX',
            sourceType: 'book',
            dateKey: '2026-06-01',
            createdAt: 111,
          ),
        ],
      );

      await svc.applyAggregateSnapshot(incoming);

      expect((await db.getAllReadingStatistics()).single.charactersRead, 200);
      expect((await db.getMiningStatisticsBySource('book')).single.count, 9);
      expect((await db.getAllFavoriteWords()).single.expression, 'wX');
    });

    test('host 已有更大统计 → apply 更小值不缩小（MAX 语义）', () async {
      await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
        title: 'Book A',
        dateKey: '2026-06-01',
        charactersRead: 500,
        readingTimeMs: 9000,
        lastStatisticModified: 20,
      ));
      final AppModelLibraryHostService svc = _svc(db);
      await svc.applyAggregateSnapshot(AggregateSnapshot(
        readingStats: const <ReadingStatRecord>[
          ReadingStatRecord(
            title: 'Book A',
            dateKey: '2026-06-01',
            charactersRead: 100, // 更小
            readingTimeMs: 1000, // 更小
            lastStatisticModified: 5,
          ),
        ],
      ));
      final ReadingStatisticRow row =
          (await db.getAllReadingStatistics()).single;
      expect(row.charactersRead, 500); // MAX 保留大值
      expect(row.readingTimeMs, 9000);
    });

    test('重复 apply 同一快照 → 幂等（挖掘 MAX 非 SUM，不翻倍）', () async {
      final AppModelLibraryHostService svc = _svc(db);
      final AggregateSnapshot snap = AggregateSnapshot(
        miningStats: const <MiningRecord>[
          MiningRecord(sourceType: 'book', dateKey: '2026-06-01', count: 4),
        ],
      );
      await svc.applyAggregateSnapshot(snap);
      await svc.applyAggregateSnapshot(snap);
      expect((await db.getMiningStatisticsBySource('book')).single.count, 4);
    });

    test('收藏词并集：host 已有的保留，client 独有的新增', () async {
      await db.addFavoriteWord(
        expression: 'wHost',
        reading: 'r',
        glossary: 'g',
        sourceType: 'book',
        dateKey: '2026-06-01',
      );
      final AppModelLibraryHostService svc = _svc(db);
      await svc.applyAggregateSnapshot(AggregateSnapshot(
        favoriteWords: const <FavoriteWordRecord>[
          FavoriteWordRecord(
            expression: 'wPeer',
            reading: 'r',
            glossary: 'g',
            sourceType: 'book',
            dateKey: '2026-06-01',
            createdAt: 222,
          ),
        ],
      ));
      final Set<String> got = (await db.getAllFavoriteWords())
          .map((FavoriteWordRow w) => w.expression)
          .toSet();
      expect(got, <String>{'wHost', 'wPeer'});
    });
  });
}
