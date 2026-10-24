// 「从 Anki 迁移」对真实集合的端到端耗时（手动跑，默认跳过）。
//
// 先把集合**拷一份**（collection.anki2 + collection.media/）到自己的目录，别指向在用的 Anki 数据：
//
// ```
// FUSHI_SRS_MIGRATION_BENCH_DIR=<副本目录> flutter test test/srs/srs_anki_migration_real_bench_test.dart
// ```
//
// 库开在临时文件上、走 createInBackground + WAL（与 app 同一种连接）；媒体落真实的 SrsMediaStore。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_anki_migration.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

void main() {
  final String? source = Platform.environment['FUSHI_SRS_MIGRATION_BENCH_DIR'];
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    '真实集合迁移端到端耗时',
    () async {
      final Directory src = Directory(source!);
      final Directory work = Directory(
        p.join(
          src.parent.path,
          'bench_${DateTime.now().millisecondsSinceEpoch}',
        ),
      )..createSync(recursive: true);
      final Stopwatch total = Stopwatch()..start();
      final Stopwatch sw = Stopwatch()..start();
      final AnkiCollectionSnapshot snap = await snapshotAnkiCollection(
        collection: File(p.join(src.path, ankiCollectionFileName)),
        tempParent: Directory(p.join(work.path, 'snap')),
      );
      final int snapshotMs = sw.elapsedMilliseconds;

      // 与 app 的连接同一组 PRAGMA（fushi_core database.dart 的 applyPragmas）。
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.createInBackground(
          File(p.join(work.path, 'fushi.db')),
          setup: (sqlite3.Database d) {
            d.execute('PRAGMA busy_timeout = 5000');
            d.execute('PRAGMA journal_mode=WAL');
            d.execute('PRAGMA foreign_keys = ON');
          },
        ),
      );
      final Directory mediaDir = Directory(p.join(work.path, 'srs_media', 'p'));
      const String uid = '01928c3e-0000-7000-8000-0000000be4c6';
      final SrsStorage srs = await SrsStorage.open(
        path: p.join(work.path, 'srs.db'),
      );
      addTearDown(srs.close);
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: uid,
        deviceId: 'bench',
        engine: FfiFsrsEngine.tryCreate(),
        fallbackRolloverHour: () => 4,
        styles: SrsStyleStore(mediaDir),
      );
      final List<String> marks = <String>[];
      double lastMark = 0;
      sw.reset();
      final SrsImportReport r = await runSrsAnkiMigration(
        store: store,
        media: SrsMediaStore(mediaDir),
        source: SrsAnkiMigrationFromCollection(snap),
        onProgress: (double v) {
          if (v - lastMark >= 0.02 || v == 1) {
            lastMark = v;
            marks.add(
              '${(v * 100).round()}%@${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
            );
          }
        },
      );
      final int importMs = sw.elapsedMilliseconds;
      await snap.discard();
      final int mediaFiles = mediaDir.existsSync()
          ? mediaDir.listSync().length
          : 0;
      // ignore: avoid_print
      print(
        'BENCH snapshot=${snapshotMs}ms import=${importMs}ms '
        'total=${total.elapsedMilliseconds}ms\n'
        'report: notes+${r.notesAdded} cards+${r.cardsAdded} '
        'logs=${r.reviewLogsImported} anchors=${r.anchorsWritten} '
        'media=${r.mediaStored} missing=${r.mediaMissing.length} files=$mediaFiles '
        'conflicts=${r.conflictNotes.length}\n'
        'progress: ${marks.join(' ')}',
      );
      await db.close();
      try {
        work.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    },
    skip: source == null ? 'set FUSHI_SRS_MIGRATION_BENCH_DIR' : false,
    timeout: const Timeout(Duration(hours: 2)),
  );
}
