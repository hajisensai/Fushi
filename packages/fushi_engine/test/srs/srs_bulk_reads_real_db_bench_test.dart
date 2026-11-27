// 大库批量读基准（BUG-5566：复习历史捐赠页首次统计慢）：捐赠预览那三步——`notes`（可见卡的全部笔记物化）、
// `entityViews`（同一批笔记一条命令）、`histories`（这些笔记的可见卡的历史重放）——各要多久。内核一侧的分段见
// native/fushi_fsrs/src/store/gen4/cmd/views_realdb_bench_tests.rs。
//
// 手动跑（库复制一份再开，原件不动；FUSHI_FSRS_ID_AUDIT=0 用 release 库，FUSHI_HEAVY_OFFLOAD=off 留在本机）：
//   FUSHI_SRS_BULK_BENCH_DB=<新代库目录> [FUSHI_SRS_BULK_BENCH_PROFILE=<uid>] [FUSHI_FSRS_LIB=<fushi_fsrs.dll>] \
//     dart ../../fushi/tool/heavy.dart -- dart test test/srs/srs_bulk_reads_real_db_bench_test.dart
// 不设环境变量时跳过。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:fushi_engine/srs/srs_reads.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_test_storage.dart';

/// 跑 [f]，交回 (毫秒, 结果)，并打印这段时间里各条内核命令的次数 / 用时 / 交回字节（[SrsOpLedger]）：与总用时的差就是
/// Dart 侧（解码、物化输入、物化内核）的。
Future<(int, T)> _timed<T>(Future<T> Function() f) async {
  SrsOpLedger.reset();
  final Stopwatch sw = Stopwatch()..start();
  final T v = await f();
  final int ms = sw.elapsedMilliseconds;
  for (final MapEntry<String, ({int count, int totalUs, int maxUs, int bytes})>
      e
      in SrsOpLedger.debugWindow().entries) {
    stdout.writeln(
      'BENCH   ${e.key} ${e.value.count}x ${e.value.totalUs ~/ 1000}ms '
      '${e.value.bytes >> 20}MB',
    );
  }
  return (ms, v);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? src = Platform.environment['FUSHI_SRS_BULK_BENCH_DB'];
  final String uid =
      Platform.environment['FUSHI_SRS_BULK_BENCH_PROFILE'] ??
      '01a13df4-d911-7042-926d-1ca6cad819a8';
  test(
    '基准：捐赠预览的批量读',
    () async {
      SrsOpLedger.reset();
      final TestSrs srs = await openRealDataTestSrs(src!);
      final SrsDbStore store = await SrsDbStore.open(
        core: srs.core,
        profileUid: uid,
        deviceId: 'bench',
        engine: const FakeFsrsEngine(),
        fallbackRolloverHour: () => 4,
      );
      for (final MapEntry<
            String,
            ({int count, int totalUs, int maxUs, int bytes})
          >
          e
          in SrsOpLedger.debugWindow().entries) {
        stdout.writeln(
          'BENCH open: ${e.key} ${e.value.count}x ${e.value.totalUs ~/ 1000}ms',
        );
      }
      final List<SrsCardCacheRow> all = await store.cardRowsWhere(
        const <String, Object?>{},
      );
      final Map<String, List<String>> cardsOf = <String, List<String>>{};
      for (final SrsCardCacheRow c in all) {
        if (!c.hidden) (cardsOf[c.noteId] ??= <String>[]).add(c.id);
      }
      final List<String> noteIds = cardsOf.keys.toList();
      final List<String> cardIds = <String>[
        for (final List<String> cs in cardsOf.values) ...cs,
      ];
      stdout.writeln(
        'BENCH ${all.length} cards, ${cardIds.length} visible, '
        '${noteIds.length} notes',
      );
      // 与内核基准（views_realdb_bench_tests.rs）同一条命令：一条读命令 4096 条，宿主一侧的往返与内核本身对照。
      for (int round = 0; round < 2; round++) {
        final Stopwatch one = Stopwatch()..start();
        await srsRead(srs.core, uid, 'edits', <String, Object?>{
          'kind': 'note',
          'ids': noteIds.take(4096).toList(),
        });
        final int editsMs = one.elapsedMilliseconds;
        one.reset();
        await srsRead(srs.core, uid, 'logs', <String, Object?>{
          'cards': cardIds.take(4096).toList(),
        });
        stdout.writeln(
          'BENCH one command #$round: read edits(4096 notes) ${editsMs}ms, '
          'read logs(4096 cards) ${one.elapsedMilliseconds}ms',
        );
      }
      // `notes` 的分段（同 SrsDbStore.notes：每块 500 条读身份记录与修改记录，再一次物化）：内核读 / Dart 拼物化输入 /
      // 物化内核（含回包解码）各多少。
      int readUs = 0, glueUs = 0, matUs = 0;
      for (int at = 0; at < noteIds.length; at += 500) {
        final List<String> chunk = noteIds.sublist(
          at,
          at + 500 > noteIds.length ? noteIds.length : at + 500,
        );
        final Stopwatch sw = Stopwatch()..start();
        final SrsReadResult ents = await srsRead(
          srs.core,
          uid,
          'entities',
          <String, Object?>{'ids': chunk},
        );
        final SrsReadResult eds = await srsRead(
          srs.core,
          uid,
          'edits',
          <String, Object?>{'kind': 'note', 'ids': chunk},
        );
        readUs += sw.elapsedMicroseconds;
        sw.reset();
        final Map<String, List<SrsEditItem>> byId =
            <String, List<SrsEditItem>>{};
        final SrsColumns ec = eds.table;
        for (int i = 0; i < ec.rows; i++) {
          (byId[ec.strings('e')[i]] ??= <SrsEditItem>[]).add(
            SrsEditItem.stored(ec.strings('j').bytes(i), ec.ints('st').at(i)),
          );
        }
        final SrsColumns nc = ents.table;
        final List<SrsEntitySource> src = <SrsEntitySource>[
          for (int i = 0; i < nc.rows; i++)
            SrsEntitySource(
              nc.strings('id')[i],
              nc.strings('payload_json')[i],
              byId[nc.strings('id')[i]] ?? <SrsEditItem>[],
            ),
        ];
        glueUs += sw.elapsedMicroseconds;
        sw.reset();
        srsMaterializeNotes(src);
        matUs += sw.elapsedMicroseconds;
      }
      stdout.writeln(
        'BENCH notes split: kernel reads ${readUs ~/ 1000}ms, '
        'glue ${glueUs ~/ 1000}ms, materialize ${matUs ~/ 1000}ms',
      );
      for (int round = 0; round < 2; round++) {
        final (int nMs, Map<String, SrsNoteView?> notes) = await _timed(
          () => store.notes(noteIds),
        );
        stdout.writeln(
          'BENCH #$round notes(${noteIds.length}) ${nMs}ms '
          '(${(nMs * 1000 / noteIds.length).round()}us each, '
          '${notes.values.whereType<SrsNoteView>().length} found)',
        );
        final (int vMs, List<SrsEntityView> views) = await _timed(
          () => store.entityViews(SrsEntityKind.note, ids: noteIds),
        );
        stdout.writeln(
          'BENCH #$round entityViews(${noteIds.length}) ${vMs}ms '
          '(${(vMs * 1000 / noteIds.length).round()}us each, '
          '${views.length} views)',
        );
        final (int hMs, Map<String, SrsCardHistory> hs) = await _timed(
          () => store.histories(cardIds),
        );
        stdout.writeln(
          'BENCH #$round histories(${cardIds.length}) ${hMs}ms '
          '(${(hMs * 1000 / cardIds.length).round()}us each, '
          '${hs.length} histories)',
        );
      }
    },
    skip: src == null ? 'set FUSHI_SRS_BULK_BENCH_DB' : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
