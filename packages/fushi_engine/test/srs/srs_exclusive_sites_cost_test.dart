// 收掉 Dart 写路径第 10 步：四处「Dart 读 → 判 → 写」的独占区（批量改字段的落计划 / 撤销、合并重复笔记、媒体
// 回收、远程作答核对基准）各改成内核的意图命令。这里量它们经 Drift 执行器送进内核的语句数与内核命令数
// （口径同 srs_write_statement_cost_test.dart）。
//
// 改动前（第 9 步的头 0cae4963576 + 那一步的库，本机实测）见 PR 说明；改动后全部 0 条语句：
// - 落计划 / 撤销：读笔记视图 + `editFieldsBatch` → 一条 `note_fields_if`；
// - 合并：读笔记 + 读卡 + 还原点 + 3 + N 条写命令 → 一条 `merge_notes`；
// - 彻底清除一条笔记并回收：读笔记 + `purge` + 存活引用的读 + 写本机状态行两次 → `media_gc_queue` + `purge` +
//   `media_gc_collect`；
// - 保留期维护：`media_gc_queue` + `media_gc_collect`；
// - 带基准的远程作答：读卡缓存行 + 预览 + `apply` → 预览 + 带 `expectLast` 的 `apply`。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_purge.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_remote_store_routes.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'support/srs_bulk_fixture.dart';

typedef _Cost = ({int statements, int core});

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

  test('第 10 步：落计划 / 撤销 / 合并 / 媒体回收 / 带基准的远程作答的语句数与内核命令数', () async {
    final BulkFixture f = await BulkFixture.open(notes: 8);
    final SrsDbStore s = f.store;
    final SrsNoteTypeView basic = (await s.noteType(basicTypeId(s)))!;
    final String front = basic.fields[0].id;
    final String back = basic.fields[1].id;
    final List<String> notes = await s.noteIdsOfType(basic.id);
    final Map<String, SrsNoteView?> views = await s.notes(notes);
    final Map<String, _Cost> costs = <String, _Cost>{};

    // ---- 批量改字段：落计划、撤销
    final SrsNoteFieldPlan plan = SrsNoteFieldPlan(
      changes: <SrsNoteFieldChange>[
        for (final String id in notes.take(3))
          SrsNoteFieldChange(
            noteId: id,
            fieldId: back,
            fieldName: basic.fields[1].name,
            before: views[id]!.field(back),
            after: 'changed',
          ),
      ],
      skipped: const <String>[],
      unchanged: 0,
      missing: const <String>[],
    );
    late SrsNoteFieldApplied applied;
    costs['applyPlan'] = await _cost(s, () async {
      applied = await srsApplyNoteFieldPlan(s, plan);
    });
    expect(applied.changes, hasLength(3));
    expect(applied.conflicts, 0);
    costs['revertPlan'] = await _cost(s, () async {
      expect(await srsRevertNoteFieldChanges(s, applied.changes), 0);
    });
    expect((await s.note(notes[0]))!.field(back), views[notes[0]]!.field(back));

    // ---- 合并重复笔记（一条保留、两条被吸收）
    late SrsMergeReport merged;
    costs['mergeNotes'] = await _cost(s, () async {
      merged = await s.mergeNotes(
        keepId: notes[3],
        absorbIds: <String>[notes[4], notes[5]],
      );
    });
    expect(merged.linkedCards, 4);
    expect((await s.note(notes[4]))!.deletedAt, isNotNull);

    // ---- 媒体回收
    final Directory media = Directory.systemTemp.createTempSync('srs_wp10_');
    addTearDown(() {
      try {
        media.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final DateTime old = DateTime.now().subtract(const Duration(days: 2));
    File file(String name) => File(p.join(media.path, name))
      ..writeAsStringSync('x')
      ..setLastModifiedSync(old);
    Future<String> deletedNote(String name) async {
      final String id = await s.createNote(
        noteTypeId: basic.id,
        fieldsById: <String, String>{
          front: 'media $name',
          back: '<img src="$name">',
        },
      );
      await s.deleteNote(id);
      return id;
    }

    // 名字避开基准包：它的笔记类型模板引用着 `a.png`（srs_apkg_import_test.dart `legacyModels`），那是存活引用。
    final File a = file('wp10-gone.png');
    final File b = file('wp10-trash.png');
    final String goneA = await deletedNote('wp10-gone.png');
    await deletedNote('wp10-trash.png');
    late SrsPurgeReport report;
    costs['purgeNotesNow'] = await _cost(s, () async {
      report = await srsPurgeNotesNow(s, <String>[goneA], mediaRoot: media);
    });
    expect(report.notes, 1);
    expect(report.mediaFiles, 1);
    expect(a.existsSync(), isFalse);
    expect(b.existsSync(), isTrue, reason: '删除未满保留期的笔记还引用着');
    costs['purgeExpired'] = await _cost(s, () async {
      report = await srsPurgeExpiredTombstones(
        s,
        mediaRoot: media,
        after: Duration.zero,
      );
    });
    expect(report.mediaFiles, 1);
    expect(b.existsSync(), isFalse);

    // ---- 带基准的远程作答（主机路由）
    final SrsRemoteStoreService service = SrsRemoteStoreService(
      readStore: () async => s,
      readMedia: (String name) async => null,
    );
    final String card = (await s.cardsOfNotes(<String>[
      notes[6],
    ]))[notes[6]]!.first.id;
    final String? base = (await s.cardRow(card))!.lastLogId;
    late int status;
    costs['remoteAnswer'] = await _cost(s, () async {
      final shelf.Response res = await handleSrsRemoteStoreRequest(
        service,
        shelf.Request(
          'POST',
          Uri.parse('http://host/api/srs/remote/call'),
          body: jsonEncode(<String, Object?>{
            'profile': kBulkUid,
            'op': 'answerAndStudy',
            'request': 'wp10-cost',
            'args': <String, Object?>{
              'card': card,
              'rating': 3,
              'durationMs': 1000,
              'checkBase': true,
              'base': base,
            },
          }),
        ),
        'POST',
        '/api/srs/remote/call',
      );
      status = res.statusCode;
    });
    expect(status, 200);

    for (final MapEntry<String, _Cost> e in costs.entries) {
      // ignore: avoid_print
      print(
        'WRITE_COST ${e.key}: statements=${e.value.statements} '
        'core=${e.value.core}',
      );
    }
    expect(costs, <String, _Cost>{
      'applyPlan': (statements: 0, core: 1),
      'revertPlan': (statements: 0, core: 1),
      'mergeNotes': (statements: 0, core: 1),
      'purgeNotesNow': (statements: 0, core: 3),
      'purgeExpired': (statements: 0, core: 2),
      'remoteAnswer': (statements: 0, core: 2),
    });
  });
}
