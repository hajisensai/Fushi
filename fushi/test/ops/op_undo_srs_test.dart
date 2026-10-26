// 复习（SRS）域写操作的撤销往返（spec §5.2 / §5.3）：经 [OpInvoker] 以模型身份执行 →
// `undo.revert` → 状态回到执行前；执行后被手动改过的，撤销报 superseded 且不覆盖。
// 撤销载荷先过一遍 JSON 往返（与持久化进 ai_agent_actions 同口径）。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../srs/srs_test_support.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('复习操作不应访问 ref（依赖经 debugOverrideSrsCtlDeps 注入）');
}

Future<String> _addNote(
  SrsDbStore s,
  String expression,
  String reading, {
  String sentence = '',
}) => s.createNote(
  noteTypeId: s.lapisNoteTypeId,
  fieldsById: <String, String>{
    srsLapisFieldId(kSrsTestProfile, 'Expression'): expression,
    srsLapisReadingFieldId(kSrsTestProfile): reading,
    if (sentence.isNotEmpty)
      srsLapisFieldId(kSrsTestProfile, 'Sentence'): sentence,
  },
);

/// 一个 store 上的操作目录与调用器。
class _Ops {
  _Ops(SrsDbStore store) {
    final OpContext context = OpContext(ref: _UnusedRef());
    debugOverrideSrsCtlDeps(
      context,
      SrsCtlDeps(
        store: () async => store,
        moduleEnabled: () => true,
        changed: () => changed++,
      ),
    );
    catalog = buildAppOpCatalog(context, buildDomainOpRoutes(context));
    invoker = OpInvoker(catalog);
  }

  late final OpCatalog catalog;
  late final OpInvoker invoker;
  int changed = 0;

  Future<(Object?, OpUndoRecord)> run(
    String id,
    Map<String, Object?> args,
  ) async {
    final OpInvocation done = await invoker.invoke(
      id,
      args,
      caller: OpCaller.model,
      captureUndo: true,
    );
    expect(done.undo, isNotNull, reason: '$id 应返回撤销载荷');
    return (done.result, done.undo!);
  }

  Future<OpUndoStatus> undo(String id, OpUndoRecord record) async {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(record.payload)) as Map<String, Object?>;
    return (await catalog[id]!.undo!.revert(payload)).status;
  }
}

/// 两台设备、一条被 A 删除且被 B 并发修改的笔记，B 这边已扣住删除。
Future<(List<FushiDatabase>, SrsDbStore, String, String)> _heldDelete() async {
  final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
    deviceId: 'a',
  );
  final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
    deviceId: 'b',
  );
  final SrsMemoryLocationStore location = SrsMemoryLocationStore();
  Future<void> syncAll() async {
    for (int r = 0; r < 2; r++) {
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        await srsSync2Round(
          host: s,
          location: location,
          locationId: 'test',
          nowMs: () => s.now().$1,
        );
      }
    }
  }

  final String noteId = await _addNote(a, '魚', 'さかな');
  await syncAll();
  await a.deleteNote(noteId);
  await b.updateNote(
    noteId,
    fieldsById: <String, String>{
      srsLapisFieldId(kSrsTestProfile, 'Sentence'): '離線編集',
    },
  );
  await syncAll();
  final String conflict = (await b.sync2Conflicts()).single['id']! as String;
  return (<FushiDatabase>[dbA, dbB], b, noteId, conflict);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('描述：保留被扣住的删除是 irreversible（带 confirm 表态），其余写操作都可撤销', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    final _Ops ops = _Ops(store);
    final FushiOp keep = ops.catalog['srs.conflict.held.keep']!;
    expect(keep.risk, OpRisk.irreversible);
    expect(keep.undo, isNull);
    expect(
      keep.params.where((OpParam p) => p.userGate).map((OpParam p) => p.name),
      <String>['confirm'],
    );
    for (final String id in <String>[
      'srs.conflict.held.delete',
      'srs.conflict.field.resolve',
      'srs.duplicates.merge',
      'srs.duplicates.dismiss',
    ]) {
      expect(ops.catalog[id]!.risk, OpRisk.write, reason: id);
      expect(ops.catalog[id]!.undo, isNotNull, reason: id);
    }
    for (final String id in <String>[
      'srs.decks.list',
      'srs.notes.search',
      'srs.note.get',
      'srs.stats',
      'srs.conflicts.list',
    ]) {
      expect(ops.catalog[id]!.risk, OpRisk.read, reason: id);
    }
  });

  group('被扣住的删除选「删除」', () {
    test('执行 → 撤销 → 笔记复活', () async {
      final (List<FushiDatabase> dbs, SrsDbStore b, String noteId, String id) =
          await _heldDelete();
      addTearDown(() async {
        for (final FushiDatabase db in dbs) {
          await db.close();
        }
      });
      final _Ops ops = _Ops(b);
      final (Object? _, OpUndoRecord record) = await ops.run(
        'srs.conflict.held.delete',
        <String, Object?>{'id': id},
      );
      expect((await b.cardsOfNote(noteId)).single.hidden, isTrue);
      expect(
        await ops.undo('srs.conflict.held.delete', record),
        OpUndoStatus.done,
      );
      expect((await b.note(noteId))!.deletedAt, isNull);
      expect((await b.cardsOfNote(noteId)).single.hidden, isFalse);
      expect(await b.sync2Conflicts(), isEmpty, reason: '复活不会让冲突重新冒出来');
    });

    test('执行后手动恢复过 → superseded，不再写', () async {
      final (List<FushiDatabase> dbs, SrsDbStore b, String noteId, String id) =
          await _heldDelete();
      addTearDown(() async {
        for (final FushiDatabase db in dbs) {
          await db.close();
        }
      });
      final _Ops ops = _Ops(b);
      final (Object? _, OpUndoRecord record) = await ops.run(
        'srs.conflict.held.delete',
        <String, Object?>{'id': id},
      );
      await b.restoreNote(noteId);
      await b.deleteNote(noteId);
      expect(
        await ops.undo('srs.conflict.held.delete', record),
        OpUndoStatus.superseded,
      );
      expect(
        (await b.note(noteId))!.deletedAt,
        isNotNull,
        reason: '用户后来的删除不被覆盖',
      );
    });
  });

  group('被覆盖的标志', () {
    Future<(List<FushiDatabase>, SrsDbStore, String, Map<String, Object?>)>
    flagConflict() async {
      final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
        deviceId: 'a',
      );
      final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
        deviceId: 'b',
      );
      final SrsMemoryLocationStore location = SrsMemoryLocationStore();
      Future<void> syncAll() async {
        for (int r = 0; r < 2; r++) {
          for (final SrsDbStore s in <SrsDbStore>[a, b]) {
            await srsSync2Round(
              host: s,
              location: location,
              locationId: 'test',
              nowMs: () => s.now().$1,
            );
          }
        }
      }

      final String noteId = await _addNote(a, '花', 'はな');
      await syncAll();
      final String card = (await a.cardsOfNote(noteId)).single.id;
      await a.setFlag(card, 1);
      await b.setFlag(card, 2);
      await syncAll();
      final (SrsEntityKind _, String _, SrsRegister reg) =
          (await b.syncConflicts()).single;
      return (
        <FushiDatabase>[dbA, dbB],
        b,
        card,
        <String, Object?>{
          'kind': 'card',
          'entity': card,
          'key': reg.key,
          'keep': 'replaced',
        },
      );
    }

    test('改回被覆盖的值 → 撤销 → 当时生效的值写回', () async {
      final (
        List<FushiDatabase> dbs,
        SrsDbStore b,
        String card,
        Map<String, Object?> args,
      ) = await flagConflict();
      addTearDown(() async {
        for (final FushiDatabase db in dbs) {
          await db.close();
        }
      });
      final int before = (await b.cardRow(card))!.flag;
      final _Ops ops = _Ops(b);
      final (Object? _, OpUndoRecord record) = await ops.run(
        'srs.conflict.field.resolve',
        args,
      );
      expect((await b.cardRow(card))!.flag, isNot(before));
      expect(
        await ops.undo('srs.conflict.field.resolve', record),
        OpUndoStatus.done,
      );
      expect((await b.cardRow(card))!.flag, before);
    });

    test('之后又手动改过 → superseded', () async {
      final (
        List<FushiDatabase> dbs,
        SrsDbStore b,
        String card,
        Map<String, Object?> args,
      ) = await flagConflict();
      addTearDown(() async {
        for (final FushiDatabase db in dbs) {
          await db.close();
        }
      });
      final _Ops ops = _Ops(b);
      final (Object? _, OpUndoRecord record) = await ops.run(
        'srs.conflict.field.resolve',
        args,
      );
      await b.setFlag(card, 5);
      expect(
        await ops.undo('srs.conflict.field.resolve', record),
        OpUndoStatus.superseded,
      );
      expect((await b.cardRow(card))!.flag, 5);
    });
  });

  group('重复笔记合并', () {
    late FushiDatabase db;
    late SrsDbStore store;
    setUp(() async => (db, store) = await openSrsTestStore());
    tearDown(() => db.close());

    test('合并 → 撤销 → 拆开：被吸收的复活、补的字段与标签写回、复习历史各归各', () async {
      final String keep = await _addNote(store, '雪', 'ゆき');
      final String other = await _addNote(store, '雪', 'ゆき', sentence: '雪が降る');
      await store.updateNote(other, tags: <String>['jlpt']);
      final String keepCard = (await store.cardsOfNote(keep)).first.id;
      final String otherCard = (await store.cardsOfNote(other)).first.id;
      await store.answer(keepCard, 3);
      await store.answer(keepCard, 3);
      await store.answer(otherCard, 1);
      final SrsNoteView keptBefore = (await store.note(keep))!;

      final _Ops ops = _Ops(store);
      final (Object? _, OpUndoRecord record) = await ops.run(
        'srs.duplicates.merge',
        <String, Object?>{
          'keep': keep,
          'absorb': <String>[other],
        },
      );
      expect((await store.history(keepCard)).effective, hasLength(3));
      expect((await store.note(keep))!.tags, contains('jlpt'));
      expect(await store.duplicateNoteGroups(), isEmpty);

      expect(await ops.undo('srs.duplicates.merge', record), OpUndoStatus.done);
      final SrsNoteView keptAfter = (await store.note(keep))!;
      expect((await store.note(other))!.deletedAt, isNull);
      expect(
        keptAfter.field(srsLapisFieldId(kSrsTestProfile, 'Sentence')),
        keptBefore.field(srsLapisFieldId(kSrsTestProfile, 'Sentence')),
      );
      expect(keptAfter.tags, keptBefore.tags);
      expect((await store.history(keepCard)).effective, hasLength(2));
      expect((await store.history(otherCard)).effective, hasLength(1));
      expect((await store.cardsOfNote(other)).first.hidden, isFalse);
      expect(await store.duplicateNoteGroups(), hasLength(1), reason: '建议回来了');
    });

    test('合并后保留的笔记又被改过 → superseded，不拆', () async {
      final String keep = await _addNote(store, '星', 'ほし');
      final String other = await _addNote(store, '星', 'ほし');
      final _Ops ops = _Ops(store);
      final (Object? _, OpUndoRecord record) = await ops.run(
        'srs.duplicates.merge',
        <String, Object?>{
          'keep': keep,
          'absorb': <String>[other],
        },
      );
      await store.updateNote(keep, tags: <String>['edited']);
      expect(
        await ops.undo('srs.duplicates.merge', record),
        OpUndoStatus.superseded,
      );
      expect((await store.note(other))!.deletedAt, isNotNull);
    });
  });

  group('不是重复', () {
    test('标记 → 撤销 → 建议回来；之后又改过 → superseded', () async {
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
      addTearDown(db.close);
      final String a = await _addNote(store, '雨', 'あめ');
      final String b = await _addNote(store, '雨', 'あめ');
      final _Ops ops = _Ops(store);
      final (Object? _, OpUndoRecord record) = await ops.run(
        'srs.duplicates.dismiss',
        <String, Object?>{
          'notes': <String>[a, b],
        },
      );
      expect(await store.duplicateNoteGroups(), isEmpty);
      expect(
        await ops.undo('srs.duplicates.dismiss', record),
        OpUndoStatus.done,
      );
      expect(await store.duplicateNoteGroups(), hasLength(1));

      final (Object? _, OpUndoRecord again) = await ops.run(
        'srs.duplicates.dismiss',
        <String, Object?>{
          'notes': <String>[a, b],
        },
      );
      await store.writeEdits(<SrsEditSpec>[
        SrsEditSpec(
          SrsEntityKind.note,
          a,
          SrsDuplicateNotes.notDuplicateKey(b),
          false,
        ),
      ]);
      expect(
        await ops.undo('srs.duplicates.dismiss', again),
        OpUndoStatus.superseded,
      );
    });
  });
}
