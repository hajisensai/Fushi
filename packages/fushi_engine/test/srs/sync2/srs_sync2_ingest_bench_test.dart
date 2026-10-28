// 收段端到端测量（默认跳过；`FUSHI_SRS_INGEST_BENCH=<笔记数>` 打开）：设备 A 写一批带长字段的笔记并发段，
// 新设备 B 一轮同步收下全部段，量 B 这一轮的墙钟耗时（含 FFI、跨 isolate 拷贝、缓存刷新）与进程峰值 RSS 的增量。
// 只用来出 PR 里的前后对比数字，不做断言之外的判断。
import 'dart:io';

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
    },
    skip: notes <= 0 ? 'set FUSHI_SRS_INGEST_BENCH=<notes> to run' : false,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
