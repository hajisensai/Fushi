// Drift 执行器 A/B（手动跑；默认跳过）：同一份库文件的两份副本，一份走 Drift 自带的
// NativeDatabase（Dart sqlite3），一份走 Rust 独占连接（srsDatabaseConnection），交替量同一批查询。
//
// FUSHI_SRS_EXEC_AB=<日志行数> dart test test/srs/srs_executor_ab_bench_test.dart
//
// 两份是不同的文件：Dart 的 SQLite 只开它自己那份副本（docs/specs/2026-10-23-srs-rust-store.md §1）。
// srs.db v18 起 `json` 是调 Rust SQL 函数的生成列，Dart 自带的 SQLite 读不了：Dart 那份读日志会报
// `no such function: srs_log_json`，本 A/B 只在 v18 之前的库上有意义。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:test/test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_EXEC_AB'];

  test(
    'executor A/B',
    () async {
      final int rows = int.parse(n!);
      final Directory tmp = Directory.systemTemp.createTempSync('srs_ab_');
      final String rustPath = '${tmp.path}${Platform.pathSeparator}srs.db';
      final SrsStorage rust = await SrsStorage.open(path: rustPath);
      rust.core.legacyMarkNone();
      final String payload =
          '{"id":"x","kind":"review","res":{"queue":"review"},'
          '"note":"${'あ' * 120}"}';
      await rust.db.batch((Batch b) {
        for (int i = 0; i < rows; i++) {
          // `json` 是生成列（srs.db v18）：原文写进 `jslim`（不瘦也合法）。
          b.customStatement(
            'INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, '
            'occurred_at, review_type, origin, jslim) '
            "VALUES (?, 'p', ?, 'review', ?, 'review', 'fushi', ?)",
            <Object?>['log$i', 'card${i ~/ 10}', i, payload],
          );
        }
      });
      await rust.close();
      final String dartPath = '${tmp.path}${Platform.pathSeparator}copy.db';
      File(rustPath).copySync(dartPath);
      final SrsStorage r = await SrsStorage.open(path: rustPath);
      final SrsDatabase d = SrsDatabase(
        NativeDatabase.createInBackground(File(dartPath)),
      );
      addTearDown(() async {
        await r.close();
        await d.close();
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      Future<int> time(SrsDatabase db) async {
        final Stopwatch sw = Stopwatch()..start();
        final List<SrsReviewLogRow> all = await db
            .select(db.srsReviewLogs)
            .get();
        for (int i = 0; i < 200; i++) {
          await (db.select(
            db.srsReviewLogs,
          )..where((t) => t.cardId.equals('card$i'))).get();
        }
        expect(all.length, rows);
        return sw.elapsedMilliseconds;
      }

      await time(r.db);
      await time(d);
      for (int round = 0; round < 4; round++) {
        final int a = await time(d);
        final int b = await time(r.db);
        // ignore: avoid_print
        print(
          'AB round=$round rows=$rows dartNative=${a}ms rustExecutor=${b}ms',
        );
      }
    },
    skip: n == null ? 'set FUSHI_SRS_EXEC_AB' : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
