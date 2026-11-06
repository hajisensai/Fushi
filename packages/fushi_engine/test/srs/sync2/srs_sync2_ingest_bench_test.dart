// 收段端到端测量（默认跳过）。分两个进程跑，峰值 RSS 才只算收段那一侧：
//   1. `FUSHI_SRS_INGEST_BENCH=<笔记数> FUSHI_SRS_INGEST_BENCH_DIR=<空目录>`：设备 A 写一批带长字段的笔记、发段，
//      位置上的文件落进目录；
//   2. 同样的环境变量再跑一次（目录已有文件）：新设备 B 一轮同步收下全部段，量这一轮的墙钟耗时（含 FFI、跨
//      isolate 拷贝、缓存刷新）与进程峰值 RSS 相对开库后的增量。Windows 上另报峰值私有提交（`PeakPagedMemorySize64`）：
//      峰值 RSS（工作集）把 SQLite mmap 进来的库文件页也算进去（srs.db 开 256 MiB mmap），那部分是可回收的
//      文件页；私有提交才是收段真正占住的堆。同一轮里另起一路循环作答 B 自己的一张卡，报每次作答的等待时间
//      （收段的解码 / 验签在写锁外时，作答只等锁内的投递）。
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
  // 两次作答之间隔多久（毫秒，默认 20 = 持续抢锁的压力；0 = 收段期间不作答，量没人等锁时的墙钟）。
  final int answerGapMs =
      int.tryParse(
        Platform.environment['FUSHI_SRS_INGEST_BENCH_ANSWER_MS'] ?? '',
      ) ??
      20;

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
        final String own = await b.createNote(
          noteTypeId: b.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(kProfile, 'Expression'): '自分',
          },
        );
        final String card = (await b.cardsOfNote(own)).single.id;
        await b.answer(card, 3);
        final int priv0 = _peakPrivateBytes();
        final int rss0 = ProcessInfo.maxRss;
        final Stopwatch sw = Stopwatch()..start();
        bool ingesting = true;
        final List<int> waits = <int>[];
        final Future<void> answering = () async {
          while (ingesting && answerGapMs > 0) {
            final Stopwatch one = Stopwatch()..start();
            await b.answer(card, 3);
            waits.add(one.elapsedMilliseconds);
            await Future<void>.delayed(Duration(milliseconds: answerGapMs));
          }
        }();
        final SrsSync2Report r = await round(b, loc);
        sw.stop();
        ingesting = false;
        await answering;
        waits.sort();
        final int rss1 = ProcessInfo.maxRss;
        final int priv1 = _peakPrivateBytes();
        expect(r.error, isNull);
        expect(r.applied, greaterThan(0));
        // ignore: avoid_print
        print(
          'INGEST_BENCH notes=$notes applied=${r.applied} '
          'ms=${sw.elapsedMilliseconds} '
          'maxRssBeforeMiB=${rss0 >> 20} maxRssAfterMiB=${rss1 >> 20} '
          'peakDeltaMiB=${(rss1 - rss0) >> 20} '
          'peakPrivateDeltaMiB=${priv0 < 0 ? 'n/a' : (priv1 - priv0) >> 20} '
          'answers=${waits.length} '
          'answerP50Ms=${waits.isEmpty ? 0 : waits[waits.length ~/ 2]} '
          'answerP90Ms=${waits.isEmpty ? 0 : waits[waits.length * 9 ~/ 10]} '
          'answerMaxMs=${waits.isEmpty ? 0 : waits.last}',
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

/// 本进程的峰值私有提交（字节；非 Windows 为 -1）。
int _peakPrivateBytes() {
  if (!Platform.isWindows) return -1;
  final ProcessResult r = Process.runSync('powershell', <String>[
    '-NoProfile',
    '-Command',
    '(Get-Process -Id $pid).PeakPagedMemorySize64',
  ]);
  return int.tryParse((r.stdout as String).trim()) ?? -1;
}
