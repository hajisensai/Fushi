// HBK-AUDIT-016：Mihon 已装来源连续重排的旧排序竞态。
//
// 根因：reorderSources 并发执行，且按调用方快照里旧行的 sortOrder 判「没变」。
// A0/B1 拖成 BA 的保存还没完成就再拖回 AB，第二次所有行都「没变」而跳过写入，
// 第一次的写入随后落库，库里停在 BA。修复后排序意图串行提交、只提交最后一次，
// 比较基准是写入前现读的存储顺序。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late Directory root;
  late _GatedDatabase database;
  late MihonManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-mihon-reorder-');
    database = _GatedDatabase();
    manager = MihonManager(
      database: database,
      rootDirectory: Directory('${root.path}/mihon'),
      runtime: _UnusedRuntime(),
      ownsRuntime: false,
    );
    for (final (String id, int order) in <(String, int)>[
      ('a', 0),
      ('b', 1),
      ('c', 2),
    ]) {
      await database
          .into(database.mangaOnlineSources)
          .insert(
            MangaOnlineSourcesCompanion.insert(
              extensionPackage: 'pkg',
              sourceId: id,
              name: id.toUpperCase(),
              language: 'ja',
              sortOrder: Value<int>(order),
            ),
          );
    }
    await manager.reload();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  MangaOnlineSourceRow row(List<MangaOnlineSourceRow> rows, String id) =>
      rows.firstWhere((MangaOnlineSourceRow r) => r.sourceId == id);

  Future<List<String>> storedOrder() async => <String>[
    for (final MangaOnlineSourceRow r in await database.getMangaOnlineSources(
      mediaKind: 'manga',
    ))
      r.sourceId,
  ];

  test('拖成 BA 未落库再拖回 AB：最终存储是 AB（不再停在 BA）', () async {
    // 两次意图都基于同一份旧快照（A0/B1/C2）——正是 UI 在保存在飞时的处境。
    final List<MangaOnlineSourceRow> snapshot = manager.sources;
    final MangaOnlineSourceRow a = row(snapshot, 'a');
    final MangaOnlineSourceRow b = row(snapshot, 'b');
    final MangaOnlineSourceRow c = row(snapshot, 'c');

    database.gate = Completer<void>();
    final Future<void> first = manager.reorderSources(<MangaOnlineSourceRow>[
      b,
      a,
      c,
    ]);
    // 第一次的首个写入被卡住时，第二次意图到达。
    await database.gateReached.future;
    final Future<void> second = manager.reorderSources(<MangaOnlineSourceRow>[
      a,
      b,
      c,
    ]);
    database.gate!.complete();

    await Future.wait(<Future<void>>[first, second]);
    expect(await storedOrder(), <String>['a', 'b', 'c']);
    expect(
      manager.sources.map((MangaOnlineSourceRow r) => r.sourceId),
      <String>['a', 'b', 'c'],
    );
  });

  test('保存在飞时连发多次意图：中间被覆盖的意图不落库，只提交最后一次', () async {
    final List<MangaOnlineSourceRow> snapshot = manager.sources;
    final MangaOnlineSourceRow a = row(snapshot, 'a');
    final MangaOnlineSourceRow b = row(snapshot, 'b');
    final MangaOnlineSourceRow c = row(snapshot, 'c');

    database.gate = Completer<void>();
    final Future<void> first = manager.reorderSources(<MangaOnlineSourceRow>[
      c,
      a,
      b,
    ]);
    await database.gateReached.future;
    // 被下一次覆盖、永远不该写的中间意图。
    final Future<void> middle = manager.reorderSources(<MangaOnlineSourceRow>[
      b,
      c,
      a,
    ]);
    final Future<void> last = manager.reorderSources(<MangaOnlineSourceRow>[
      a,
      c,
      b,
    ]);
    database.gate!.complete();

    await Future.wait(<Future<void>>[first, middle, last]);
    expect(await storedOrder(), <String>['a', 'c', 'b']);
    // 第一次意图 CAB 全写（3 行都变）；最后一次 ACB 相对当前存储 CAB 只改
    // a、c 两行（b 仍在 2）。若中间意图 BCA 也落库会多出写入。
    expect(database.sortOrderWrites, 5);
  });

  test('每次调用的 Future 在其意图（或覆盖它的意图）落库后才完成', () async {
    final List<MangaOnlineSourceRow> snapshot = manager.sources;
    final MangaOnlineSourceRow a = row(snapshot, 'a');
    final MangaOnlineSourceRow b = row(snapshot, 'b');
    final MangaOnlineSourceRow c = row(snapshot, 'c');

    database.gate = Completer<void>();
    bool firstDone = false;
    final Future<void> first = manager
        .reorderSources(<MangaOnlineSourceRow>[b, a, c])
        .then((_) => firstDone = true);
    await database.gateReached.future;
    final Future<void> second = manager.reorderSources(<MangaOnlineSourceRow>[
      c,
      b,
      a,
    ]);
    // 闸门未开：谁都不能先完成。
    await Future<void>.delayed(Duration.zero);
    expect(firstDone, isFalse);
    database.gate!.complete();
    await first;
    // 第一次的 Future 完成时，覆盖它的第二次意图也已落库。
    expect(await storedOrder(), <String>['c', 'b', 'a']);
    await second;
  });
}

/// 第一次写排序时停在 [gate] 上，模拟「保存尚未完成」的窗口；统计排序写入数。
class _GatedDatabase extends FushiDatabase {
  _GatedDatabase() : super.forTesting(NativeDatabase.memory());

  Completer<void>? gate;
  final Completer<void> gateReached = Completer<void>();
  int sortOrderWrites = 0;

  @override
  Future<void> updateMangaOnlineSourceSettings({
    required String extensionPackage,
    required String sourceId,
    bool? enabled,
    bool? pinned,
    int? sortOrder,
  }) async {
    if (sortOrder != null) sortOrderWrites++;
    final Completer<void>? pending = gate;
    if (pending != null && !pending.isCompleted) {
      if (!gateReached.isCompleted) gateReached.complete();
      await pending.future;
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

/// 重排路径不碰运行时；任何调用都说明测试越界。
class _UnusedRuntime implements MihonRuntime {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('runtime not used by reorder');
}
