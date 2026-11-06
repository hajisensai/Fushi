// 大库基准：统计页装载（`loadSrsStats`）与一次 AnkiConnect findNotes / notesInfo 的耗时与内存增量。
//
// 手动跑（库只读复制一份再开）：
//   FUSHI_SRS_L3_BENCH_DB=<srs.db 路径> FUSHI_SRS_L3_BENCH_PROFILE=<profile uid> \
//     dart tool/heavy.dart -- flutter test test/srs/srs_stats_load_bench_test.dart
// 不设环境变量时跳过。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_test_storage.dart';

/// 跑 [f]，交回 (毫秒, 期间 RSS 峰值相对开始时的增量 MB)。
Future<(int, int, T)> _measure<T>(Future<T> Function() f) async {
  final int base = ProcessInfo.currentRss;
  int peak = base;
  final Timer timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final int r = ProcessInfo.currentRss;
    if (r > peak) peak = r;
  });
  final Stopwatch sw = Stopwatch()..start();
  final T v = await f();
  sw.stop();
  timer.cancel();
  final int r = ProcessInfo.currentRss;
  if (r > peak) peak = r;
  return (sw.elapsedMilliseconds, (peak - base) >> 20, v);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? src = Platform.environment['FUSHI_SRS_L3_BENCH_DB'];
  final String uid =
      Platform.environment['FUSHI_SRS_L3_BENCH_PROFILE'] ??
      '01928c3e-0000-7000-8000-0000000a5e01';
  test(
    '基准：统计页装载 + AnkiConnect',
    () async {
      final Directory tmp = Directory.systemTemp.createTempSync('srs_l3_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      File(src!).copySync('${tmp.path}/srs.db');
      final TestSrs srs = await openTestSrsAt(
        '${tmp.path}/srs.db',
        inline: false,
      );
      final Stopwatch open = Stopwatch()..start();
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: uid,
        deviceId: 'dev',
        engine: const FakeFsrsEngine(),
        fallbackRolloverHour: () => 4,
      );
      stdout.writeln('BENCH open ${open.elapsedMilliseconds}ms');
      for (int i = 0; i < 3; i++) {
        final (int ms, int mb, SrsStatsBundle b) = await _measure(
          () => loadSrsStats(store),
        );
        stdout.writeln(
          'BENCH loadSrsStats#$i ${ms}ms +${mb}MB '
          'cards=${b.data.cards.length} reviews=${b.data.reviews.length} '
          'sources=${b.data.sourceShares().length}',
        );
      }
      final SrsAnkiConnectHandler h = SrsAnkiConnectHandler(
        store: () async => store,
        instanceId: 'bench',
      );
      Future<Object?> ok(String action, Map<String, Object?> params) async {
        final Map<String, Object?> r =
            (await h.handle(<String, Object?>{
                  'action': action,
                  'version': 6,
                  'params': params,
                }))
                as Map<String, Object?>;
        if (r['error'] != null) throw StateError('$action: ${r['error']}');
        return r['result'];
      }

      for (int i = 0; i < 2; i++) {
        final (int ms, int mb, Object? ids) = await _measure(
          () => ok('findNotes', <String, Object?>{'query': 'deck:*'}),
        );
        final List<Object?> notes = ids! as List<Object?>;
        stdout.writeln('BENCH findNotes#$i ${ms}ms +${mb}MB n=${notes.length}');
        final (int ms2, int mb2, Object? _) = await _measure(
          () => ok('notesInfo', <String, Object?>{
            'notes': notes.take(200).toList(),
          }),
        );
        stdout.writeln('BENCH notesInfo(200)#$i ${ms2}ms +${mb2}MB');
      }
      // 复习一张之后（修订号变了）再问一次。
      final String card = (await store.allCardRows())
          .firstWhere((SrsCardCacheRow c) => !c.hidden)
          .id;
      await store.answer(card, 3);
      final (int ms3, int mb3, Object? _) = await _measure(
        () => ok('findNotes', <String, Object?>{'query': 'deck:*'}),
      );
      stdout.writeln('BENCH findNotes(after answer) ${ms3}ms +${mb3}MB');
      final (int ms4, int mb4, SrsStatsBundle _) = await _measure(
        () => loadSrsStats(store),
      );
      stdout.writeln('BENCH loadSrsStats(after answer) ${ms4}ms +${mb4}MB');
    },
    skip: src == null ? 'FUSHI_SRS_L3_BENCH_DB 未设' : null,
    timeout: const Timeout(Duration(minutes: 60)),
  );
}
