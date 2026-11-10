// 本机写路径的往返验收（SRS 收掉 Dart 写路径第 2 步，M3）：每种写操作经 Drift 执行器送进内核的语句数
// （`SrsRustDelegate.debugStatements`，含 BEGIN / COMMIT / 本机状态行 upsert）与内核命令数（`debugCoreCommands`）。
//
// 写命令（apply / sched / import / resolve / purge / checkpoint / restore / retire / dedup）由内核在同一个
// savepoint 里完成命令本体、缓存刷新、排队与本机状态行（native/fushi_fsrs/src/store/ffi.rs `local_write`）：Dart 不再
// 为它们开 Drift 事务（BEGIN / COMMIT），也不再单独 upsert 本机状态行。改动前（每条命令套一笔 Drift 事务、事务里再
// upsert 一次本机状态行）各多 3 条语句：createNote 4、answer 3、checkpoint 3、purge 3、import 3、sched 3、
// applyRemote 4；内核命令数不变。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_bulk_fixture.dart';

typedef _Cost = ({int statements, int core});

/// 跑一次 [op]，返回它送进内核的语句数与内核命令数。
Future<_Cost> _cost(SrsDbStore store, Future<void> Function() op) async {
  final int core = store.debugCoreCommands;
  SrsRustDelegate.debugStatements = 0;
  await op();
  return (
    statements: SrsRustDelegate.debugStatements,
    core: store.debugCoreCommands - core,
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('本机写操作的语句数与内核命令数', () async {
    final BulkFixture f = await BulkFixture.open(notes: 6);
    final SrsDbStore s = f.store;
    final SrsNoteTypeView basic = (await s.noteType(basicTypeId(s)))!;
    int created = 0;
    Future<String> newNote() => s.createNote(
      noteTypeId: basic.id,
      fieldsById: <String, String>{
        basic.fields[0].id: 'front ${created++}',
        basic.fields[1].id: 'back',
      },
    );
    final List<String> cards = <String>[
      for (final SrsCardCacheRow c in await s.allCardRows()) c.id,
    ];
    final List<String> notes = await s.noteIdsOfType(basic.id);

    final BulkFixture src = await BulkFixture.open(notes: 3, deviceId: 'src');
    final List<SrsEvent> remote = await src.store.exportAll();
    final BulkFixture dst = await BulkFixture.open(notes: 0, deviceId: 'other');

    // 每种操作先预热一次（首次的懒加载不计），再量第二次。
    final Map<String, _Cost> costs = <String, _Cost>{};
    Future<void> measure(String name, Future<void> Function() op) async {
      await op();
      costs[name] = await _cost(s, op);
    }

    await measure('createNote', newNote);
    int answered = 0;
    await measure('answer', () => s.answer(cards[answered++], 3));
    await measure('checkpoint', () => s.sync2Checkpoint('m', 'manual'));
    int purged = 0;
    await measure(
      'purge',
      () => s.sync2Purge(SrsEntityKind.note, notes[purged++]),
    );
    final Uint8List exported = await s.sync2ExportOps();
    await measure('import', () => s.sync2ImportOps(exported));
    await measure('sched', () => s.resetCard(cards.last));
    costs['applyRemote'] = await _cost(
      dst.store,
      () => dst.store.applyRemote(remote, serverTimeMs: 1),
    );

    for (final MapEntry<String, _Cost> e in costs.entries) {
      // ignore: avoid_print
      print(
        'WRITE_COST ${e.key}: statements=${e.value.statements} '
        'core=${e.value.core}',
      );
    }
    // 改动前（见文件头）各多 BEGIN / COMMIT / 本机状态 upsert 3 条；createNote / applyRemote 剩下的 1 条是发命令前的
    // Drift 预读，不属于这一步。
    expect(costs, <String, _Cost>{
      'createNote': (statements: 1, core: 1),
      'answer': (statements: 0, core: 2),
      'checkpoint': (statements: 0, core: 1),
      'purge': (statements: 0, core: 1),
      'import': (statements: 0, core: 2),
      'sched': (statements: 0, core: 1),
      'applyRemote': (statements: 1, core: 1),
    });
  });
}
