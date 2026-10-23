// 删牌组等批量操作在较大规模上的墙钟耗时（手动跑；默认跳过）。
//
// FUSHI_SRS_BULK_BENCH=<笔记数> dart test test/srs/srs_bulk_ops_bench_test.dart
//
// 库开在临时文件上、走 createInBackground（与 app 同一种连接：语句经后台 isolate 往返）。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'apkg/srs_apkg_import_bench_test.dart' show benchApkg;
import 'apkg/srs_apkg_import_test.dart' show kFullOptions;
import 'support/srs_query_counter.dart';
import 'support/srs_test_storage.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_BULK_BENCH'];

  test(
    '删牌组耗时',
    () async {
      final int notes = int.parse(n!);
      final CountingInterceptor counter = CountingInterceptor();
      final Directory tmp = Directory.systemTemp.createTempSync('srs_bulk_');
      final TestSrs srs = await openTestSrsAt(
        '${tmp.path}/srs.db',
        interceptor: counter,
        inline: false,
      );
      addTearDown(() async {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      const String uid = '01928c3e-0000-7000-8000-0000000be4c6';
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: uid,
        deviceId: 'bench',
        engine: const FakeFsrsEngine(),
        fallbackRolloverHour: () => 4,
      );
      await importAnkiPackage(
        store: store,
        bytes: benchApkg(notes),
        storeMedia: (String name, Uint8List b) async => name,
        options: kFullOptions,
        zstdDecompress: (Uint8List b) => null,
      );
      final SrsDeckTree tree = await store.deckTree();
      final String lang = tree.decks
          .firstWhere((SrsDeckView d) => tree.fullName(d.id) == 'Lang')
          .id;
      counter.reset();
      final Stopwatch sw = Stopwatch()..start();
      await store.deleteDeck(lang);
      final int deleteMs = sw.elapsedMilliseconds;
      final String stmts = counter.summary();
      sw.reset();
      final List<SrsDeckSummary> decks = await store.deckSummaries();
      // ignore: avoid_print
      print(
        'BENCH notes=$notes cards=${notes * 2} deleteDeck=${deleteMs}ms '
        'then deckSummaries=${sw.elapsedMilliseconds}ms(${decks.length}) '
        'statements: $stmts',
      );
    },
    skip: n == null ? 'set FUSHI_SRS_BULK_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
