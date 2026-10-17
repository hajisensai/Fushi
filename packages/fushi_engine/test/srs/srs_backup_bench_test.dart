// 复习备份 / 恢复在真实规模数据上的耗时（手动跑；默认跳过）。
//
// FUSHI_SRS_BENCH_DB=<fushi.db 的只读副本> FUSHI_SRS_BENCH_MEDIA=<srs_media/<uid> 目录（只读）>
// dart test test/srs/srs_backup_bench_test.dart
// 测试会改这份副本（打开时迁移 + 恢复写事件），绝不要指向正在用的库。
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_point_in_time_restore.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';

void main() {
  final String? dbPath = Platform.environment['FUSHI_SRS_BENCH_DB'];
  final String? mediaPath = Platform.environment['FUSHI_SRS_BENCH_MEDIA'];
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    '真实规模：备份 / 改动 / 恢复耗时',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase(File(dbPath!)),
      );
      addTearDown(db.close);
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

      sw.reset();
      final SrsBackupInfo info = await bs.create(
        store,
        kind: SrsBackupKind.manual,
        profileName: 'bench',
      );
      final int backupMs = sw.elapsedMilliseconds;
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
        'restore=${restoreMs}ms $report',
      );
      expect(report.logsRevoked, cards.length);
    },
    skip: dbPath == null ? 'set FUSHI_SRS_BENCH_DB' : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
