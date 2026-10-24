// 复习备份 / 恢复在真实规模数据上的耗时（手动跑；默认跳过）。
//
// FUSHI_SRS_BENCH_DB=<fushi.db 的只读副本> FUSHI_SRS_BENCH_MEDIA=<srs_media/<uid> 目录（只读）>
// dart test test/srs/srs_backup_bench_test.dart
// 测试会改这份副本（打开时迁移 + 恢复写事件），绝不要指向正在用的库。
//
// 没有真实库时先合成一份（单独一个进程跑，免得生成阶段的内存峰值盖住备份阶段）：
// FUSHI_SRS_BENCH_GEN=<新库路径> FUSHI_SRS_BENCH_GEN_NOTES=5000 dart test test/srs/srs_backup_bench_test.dart
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_point_in_time_restore.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsReviewLog;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';

void main() {
  final String? dbPath = Platform.environment['FUSHI_SRS_BENCH_DB'];
  final String? mediaPath = Platform.environment['FUSHI_SRS_BENCH_MEDIA'];
  final String? genPath = Platform.environment['FUSHI_SRS_BENCH_GEN'];
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    '合成真实规模的库（每条笔记一张卡、复习 3 次，第 3 次撤销）',
    () async {
      final int notes = int.parse(
        Platform.environment['FUSHI_SRS_BENCH_GEN_NOTES'] ?? '5000',
      );
      // FUSHI_SRS_BENCH_GEN 现在指向一份 srs.db。
      final TestSrs srs = await openTestSrsAt(genPath!);
      const String uid = '01928c3e-0000-7000-8000-0000000be4c4';
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: uid,
        deviceId: 'gen',
        engine: const SrsFakeEngine(),
      );
      for (int i = 0; i < notes; i++) {
        final String n = await store.createNote(
          noteTypeId: store.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(uid, 'Expression'): '語$i',
            srsLapisFieldId(uid, 'Sentence'): '例文その$i。' * 4,
          },
        );
        final String card = (await store.cardsOfNote(n)).single.id;
        await store.answer(card, 3);
        await store.answer(card, 3);
        final SrsReviewLog last = await store.answer(card, 1);
        await store.undo(card, last.id);
      }
    },
    skip: genPath == null ? 'set FUSHI_SRS_BENCH_GEN' : false,
    timeout: const Timeout(Duration(hours: 2)),
  );

  test(
    '真实规模：备份 / 改动 / 恢复耗时',
    () async {
      // FUSHI_SRS_BENCH_DB 现在指向一份 srs.db。
      final TestSrs srs = await openTestSrsAt(dbPath!);
      final SrsDatabase db = srs.db;
      final QueryRow r = await db
          .customSelect(
            'SELECT profile_uid, COUNT(*) AS c FROM srs_entities '
            "WHERE kind = 'note' GROUP BY profile_uid ORDER BY c DESC LIMIT 1",
          )
          .getSingle();
      final String uid = r.read<String>('profile_uid');
      final Stopwatch sw = Stopwatch()..start();
      final SrsDbStore store = await SrsDbStore.open(
        db: db,
        core: srs.core,
        profileUid: uid,
        deviceId: 'bench',
        engine: const SrsFakeEngine(),
      );
      final int openMs = sw.elapsedMilliseconds;
      final Directory tmp = await Directory.systemTemp.createTemp('srs_bench_');
      addTearDown(() => tmp.delete(recursive: true));
      final SrsBackupStore bs = SrsBackupStore(
        root: Directory(p.join(tmp.path, 'srs_backups')),
        profileUid: uid,
        mediaDir: Directory(mediaPath ?? p.join(tmp.path, 'none')),
      );

      final int rssBefore = ProcessInfo.currentRss;
      final int peakBefore = ProcessInfo.maxRss;
      sw.reset();
      final SrsBackupInfo info = await bs.create(
        store,
        kind: SrsBackupKind.manual,
        profileName: 'bench',
      );
      final int backupMs = sw.elapsedMilliseconds;
      final int peakAfter = ProcessInfo.maxRss;
      sw.reset();
      final SrsBackupInfo again = await bs.create(
        store,
        kind: SrsBackupKind.manual,
        profileName: 'bench',
      );
      final int backup2Ms = sw.elapsedMilliseconds;

      // 备份之后的改动：删 50 条笔记、复习 50 张卡。
      final List<SrsCardCacheRow> cards = (await store.allCardRows())
          .where((SrsCardCacheRow c) => !c.hidden)
          .take(50)
          .toList();
      for (final SrsCardCacheRow c in cards) {
        await store.answer(c.id, 3);
        await store.deleteNote(c.noteId);
      }

      sw.reset();
      final SrsBackupArchive a = await SrsBackupStore.read(info.file);
      final int readMs = sw.elapsedMilliseconds;
      sw.reset();
      final SrsRestoreReport report = await bs.restore(store, a);
      final int restoreMs = sw.elapsedMilliseconds;
      a.close();

      // ignore: avoid_print
      print(
        'BENCH notes=${info.manifest.noteCount} cards=${info.manifest.cardCount} '
        'reviews=${info.manifest.reviewCount} events=${info.manifest.eventCount} '
        'file=${info.fileBytes}B media=${info.manifest.media.length}/'
        '${info.manifest.mediaBytes}B | open=${openMs}ms backup=${backupMs}ms '
        'backup2=${backup2Ms}ms(file ${again.fileBytes}B) read=${readMs}ms '
        'restore=${restoreMs}ms $report | rss before backup=${rssBefore >> 20}MiB '
        'peak before=${peakBefore >> 20}MiB peak after backup=${peakAfter >> 20}MiB',
      );
      expect(report.logsRevoked, cards.length);
    },
    skip: dbPath == null ? 'set FUSHI_SRS_BENCH_DB' : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
