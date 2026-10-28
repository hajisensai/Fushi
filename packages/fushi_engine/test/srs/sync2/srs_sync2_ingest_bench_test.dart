// 收段端到端测量（默认跳过）。分两个进程跑，峰值 RSS 才只算收段那一侧：
//   1. `FUSHI_SRS_INGEST_BENCH=<笔记数> FUSHI_SRS_INGEST_BENCH_DIR=<空目录>`：设备 A 写一批带长字段的笔记、发段，
//      位置上的文件落进目录；
//   2. 同样的环境变量再跑一次（目录已有文件）：新设备 B 一轮同步收下全部段，量这一轮的墙钟耗时（含 FFI、跨
//      isolate 拷贝、缓存刷新）与进程峰值 RSS 相对开库后的增量。
// 只用来出 PR 里的前后对比数字。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000ef';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final int notes =
      int.tryParse(Platform.environment['FUSHI_SRS_INGEST_BENCH'] ?? '') ?? 0;
  final String dirPath =
      Platform.environment['FUSHI_SRS_INGEST_BENCH_DIR'] ?? '';

  test(
    'ingest bench',
    () async {
      Future<SrsDbStore> device(String id) async {
        final SrsStorage st = await openTestSrsStorage();
        return SrsDbStore.open(
          db: st.db,
          core: st.core,
          profileUid: kProfile,
          deviceId: id,
          engine: FfiFsrsEngine.tryCreate(),
        );
      }

      Future<SrsSync2Report> round(SrsSync2Host s, SrsLocationStore loc) =>
          srsSync2Round(
            host: s,
            location: loc,
            locationId: 'loc',
            nowMs: () => DateTime.now().millisecondsSinceEpoch,
          );

      final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
      final Directory dir = Directory(dirPath)..createSync(recursive: true);
      final List<File> saved = <File>[
        for (final FileSystemEntity f in dir.listSync(recursive: true))
          if (f is File) f,
      ];
      if (saved.isNotEmpty) {
        for (final File f in saved) {
          final String rel = f.path
              .substring(dir.path.length + 1)
              .replaceAll(Platform.pathSeparator, '/');
          loc.files[rel] = f.readAsBytesSync();
        }
        final SrsDbStore b = await device('B');
        final int rss0 = ProcessInfo.maxRss;
        final Stopwatch sw = Stopwatch()..start();
        final SrsSync2Report r = await round(b, loc);
        sw.stop();
        final int rss1 = ProcessInfo.maxRss;
        expect(r.error, isNull);
        expect(r.applied, greaterThan(0));
        // ignore: avoid_print
        print(
          'INGEST_BENCH notes=$notes applied=${r.applied} '
          'ms=${sw.elapsedMilliseconds} '
          'maxRssBeforeMiB=${rss0 >> 20} maxRssAfterMiB=${rss1 >> 20} '
          'peakDeltaMiB=${(rss1 - rss0) >> 20}',
        );
        return;
      }
      final SrsDbStore a = await device('A');
      final String filler = List<String>.filled(400, '日本語の例文。').join();
      final List<SrsEventDraft> drafts = <SrsEventDraft>[];
      for (int i = 0; i < notes; i++) {
        drafts.addAll(
          a.newNoteDrafts(
            noteTypeId: a.lapisNoteTypeId,
            guid: 'bench-$i',
            fieldsById: <String, String>{
              srsLapisFieldId(kProfile, 'Expression'): '語$i',
              srsLapisFieldId(kProfile, 'Sentence'): '$filler$i',
            },
          ),
        );
      }
      await a.importDrafts(drafts);
      final SrsSync2Report up = await round(a, loc);
      expect(up.error, isNull);

      for (final MapEntry<String, Uint8List> f in loc.files.entries) {
        File('${dir.path}/${f.key}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(f.value);
      }
      // ignore: avoid_print
      print('INGEST_BENCH seeded ${loc.files.length} files');
    },
    skip: notes <= 0 || dirPath.isEmpty
        ? 'set FUSHI_SRS_INGEST_BENCH=<notes> and FUSHI_SRS_INGEST_BENCH_DIR to run'
        : false,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
