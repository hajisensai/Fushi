// 写入路径周边的读放大（H1 / H5 / M2 / L1 / L2）在较大规模上的墙钟耗时与读回行数（手动跑；默认跳过）。
//
// FUSHI_SRS_WP_BENCH=<笔记数> dart test test/srs/srs_write_path_perf_bench_test.dart
//
// 库开在临时文件上、走 createInBackground（与 app 同一种连接：语句经后台 isolate 往返）。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'apkg/srs_apkg_import_bench_test.dart' show benchApkg;
import 'apkg/srs_apkg_import_test.dart' show kFullOptions;
import 'support/srs_query_counter.dart';
import 'support/srs_test_storage.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_WP_BENCH'];

  test(
    '写入路径读放大',
    () async {
      final int notes = int.parse(n!);
      final CountingInterceptor counter = CountingInterceptor();
      final Directory tmp = Directory.systemTemp.createTempSync('srs_wp_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      final TestSrs srs = await openTestSrsAt(
        '${tmp.path}/b.db',
        interceptor: counter,
        inline: false,
      );
      const String uid = '01928c3e-0000-7000-8000-0000000be4c7';
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
      final Map<String, int> byType = await store.noteCountsByType();
      final String typeId = byType.entries
          .reduce(
            (MapEntry<String, int> a, MapEntry<String, int> b) =>
                a.value >= b.value ? a : b,
          )
          .key;
      final SrsNoteTypeView type = (await store.noteType(typeId))!;
      final List<String> lines = <String>[];

      Future<void> measure(
        String label,
        Future<Object?> Function() body,
      ) async {
        counter.reset();
        final Stopwatch sw = Stopwatch()..start();
        final Object? r = await body();
        lines.add(
          '$label=${sw.elapsedMilliseconds}ms rows=${counter.rowsRead} '
          '${r is int ? 'value=$r ' : ''}[${counter.summary()}]',
        );
      }

      // H5：改非缓存键（CSS / 字段说明）与缓存键（词条字段、模板）。
      await measure('setCss', () => store.setCss(typeId, '${type.css}\n/*x*/'));
      await measure(
        'setFieldDescription',
        () => store.setFieldDescription(typeId, type.fields.first.id, 'd'),
      );
      await measure(
        'setTermField',
        () => store.setTermField(typeId, type.fields.first.id),
      );
      await measure(
        'updateTemplate',
        () => store.updateTemplate(
          typeId,
          type.templates.first.id,
          back: '${type.templates.first.back} ',
        ),
      );
      // H1：冲突角标（牌组列表每次重读都算一遍）。
      await measure(
        'syncConflicts+pending',
        () async =>
            (await store.syncConflicts()).length +
            await store.pendingDecisionCount(),
      );
      // M2：一屏词条。
      final List<SrsTermQuery> qs = <SrsTermQuery>[
        for (int i = 0; i < 20; i++) SrsTermQuery('語${i * 7}'),
      ];
      await measure('lookupTermStatus x20 (one call each)', () async {
        int hit = 0;
        for (final SrsTermQuery q in qs) {
          hit += (await store.lookupTermStatus(<SrsTermQuery>[q])).length;
        }
        return hit;
      });
      await measure(
        'lookupTermStatus x20 (batched)',
        () async => (await store.lookupTermStatus(qs)).length,
      );
      // L1 / L2。
      await measure(
        'noteIdsOfType',
        () async => (await store.noteIdsOfType(typeId)).length,
      );
      await measure(
        'noteCountsByType',
        () async => (await store.noteCountsByType()).length,
      );
      final SrsDeckTree tree = await store.deckTree();
      await measure(
        'cardIdsInDecks(all)',
        () async => (await store.cardIdsInDecks(<String>{
          for (final SrsDeckView d in tree.decks) d.id,
        })).length,
      );
      // ignore: avoid_print
      print('BENCH notes=$notes cards=${notes * 2}\n  ${lines.join('\n  ')}');
    },
    skip: n == null ? 'set FUSHI_SRS_WP_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
