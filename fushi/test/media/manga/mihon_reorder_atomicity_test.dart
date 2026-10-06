// HBK-AUDIT-031：一次排序意图中途写失败须整体回滚。
//
// 根因：reorderSources 逐行写 sort_order 没有事务，第 2 次写失败时第 1 次已
// 落库，库里留下重复 sortOrder 的半截顺序。修复后一次意图的全部写入在同一个
// Drift 事务里，失败整体回滚，worker 报错后新的意图照常可写。
// （迁自 Codex 第五轮复现 mihon_reorder_failure_recovery_repro.dart。）
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late _FailingDatabase database;
  late MihonManager manager;

  setUp(() async {
    database = _FailingDatabase();
    manager = MihonManager(
      database: database,
      rootDirectory: Directory.systemTemp,
      runtime: _UnusedRuntime(),
      ownsRuntime: false,
    );
    await database.replaceMangaOnlineSources(
      'pkg',
      <MangaOnlineSourcesCompanion>[
        for (int index = 0; index < 3; index++)
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: 'pkg',
            sourceId: <String>['a', 'b', 'c'][index],
            name: <String>['a', 'b', 'c'][index],
            language: 'ja',
            sortOrder: Value<int>(index),
          ),
      ],
    );
    await manager.reload();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
  });

  Future<void> failSecondWrite() async {
    final List<MangaOnlineSourceRow> rows = manager.sources;
    database.failOnWrite = 2;
    await expectLater(
      manager.reorderSources(<MangaOnlineSourceRow>[rows[2], rows[0], rows[1]]),
      throwsStateError,
    );
  }

  Future<Map<String, int>> storedOrders() async => <String, int>{
    for (final MangaOnlineSourceRow row
        in await database.getMangaOnlineSources())
      row.sourceId: row.sortOrder,
  };

  test(
    'HBK-AUDIT-031 failed reorder leaves storage and displayed snapshot consistent',
    () async {
      final Map<String, int> before = await storedOrders();
      await failSecondWrite();
      expect(
        await storedOrders(),
        before,
        reason:
            'one reorder is one intent: failing its second write must not '
            'leave the first write committed with duplicate sort orders',
      );
      expect(<String, int>{
        for (final MangaOnlineSourceRow row in manager.sources)
          row.sourceId: row.sortOrder,
      }, before);
    },
  );

  test(
    'HBK-AUDIT-031 a fresh reorder succeeds after the worker reports a write failure',
    () async {
      final List<MangaOnlineSourceRow> original = List<MangaOnlineSourceRow>.of(
        manager.sources,
      );
      await failSecondWrite();
      database.failOnWrite = null;
      await manager.reorderSources(original);
      expect(await storedOrders(), <String, int>{'a': 0, 'b': 1, 'c': 2});
      expect(
        manager.sources.map((MangaOnlineSourceRow row) => row.sourceId),
        <String>['a', 'b', 'c'],
      );
    },
  );
}

class _UnusedRuntime extends Fake implements MihonRuntime {}

class _FailingDatabase extends FushiDatabase {
  _FailingDatabase() : super.forTesting(NativeDatabase.memory());

  int writes = 0;
  int? failOnWrite;

  @override
  Future<void> updateMangaOnlineSourceSettings({
    required String extensionPackage,
    required String sourceId,
    bool? enabled,
    bool? pinned,
    int? sortOrder,
  }) async {
    writes++;
    if (writes == failOnWrite) {
      throw StateError('injected second-write failure');
    }
    await super.updateMangaOnlineSourceSettings(
      extensionPackage: extensionPackage,
      sourceId: sourceId,
      enabled: enabled,
      pinned: pinned,
      sortOrder: sortOrder,
    );
  }
}
