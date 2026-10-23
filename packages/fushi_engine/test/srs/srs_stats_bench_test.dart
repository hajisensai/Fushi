// 复习统计装载在大日志量下的墙钟 / 内存（手动跑；默认跳过）。
//
// FUSHI_SRS_STATS_BENCH=<笔记数> dart test test/srs/srs_stats_bench_test.dart
//
// 每条笔记两张卡、每卡 3 条导入 revlog（+ 导入锚点），33334 条笔记 ≈ 20 万条复习。
// 库开在临时文件上、走 createInBackground（与 app 同一种连接）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_bulk_fixture.dart';
import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_STATS_BENCH'];

  test(
    '统计装载耗时',
    () async {
      final int notes = int.parse(n!);
      final Directory tmp = Directory.systemTemp.createTempSync('srs_stats_');
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.createInBackground(File('${tmp.path}/b.db')),
      );
      addTearDown(() async {
        await db.close();
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      final SrsDbStore store = await SrsDbStore.open(
        db: db,
        profileUid: kBulkUid,
        deviceId: 'bench',
        engine: const FakeFsrsEngine(),
        trustedClock: fixedTrustedClock(),
        fallbackRolloverHour: () => 4,
      );
      await importBench(store, notes);
      final int logCount = await db
          .customSelect('SELECT COUNT(*) AS c FROM srs_review_logs')
          .map((QueryRow r) => r.read<int>('c'))
          .getSingle();
      final SrsDayContext day = await store.dayContext();

      final Stopwatch sw = Stopwatch()..start();
      final List<SrsReviewLogRow> rows = await (db.select(
        db.srsReviewLogs,
      )..where((t) => t.profileUid.equals(kBulkUid))).get();
      final int rowsMs = sw.elapsedMilliseconds;
      sw.reset();
      final Map<String, List<SrsReviewLog>> byCard =
          <String, List<SrsReviewLog>>{};
      for (final SrsReviewLogRow r in rows) {
        (byCard[r.cardId] ??= <SrsReviewLog>[]).add(
          SrsReviewLog.fromJson(
            (jsonDecode(r.json) as Map).cast<String, Object?>(),
          ),
        );
      }
      final int decodeMs = sw.elapsedMilliseconds;
      sw.reset();
      int reviews = 0;
      for (final List<SrsReviewLog> l in byCard.values) {
        reviews += srsStatsFromHistory(SrsCardHistory(l), day).reviews.length;
      }
      final int historyMs = sw.elapsedMilliseconds;
      sw.reset();
      final $SrsReviewLogsTable t = db.srsReviewLogs;
      final int narrow =
          (await (db.selectOnly(t)
                    ..addColumns(<Expression<Object>>[
                      t.cardId,
                      t.kind,
                      t.rating,
                      t.occurredAt,
                      t.reviewType,
                      t.origin,
                      t.durationMs,
                    ])
                    ..where(t.profileUid.equals(kBulkUid)))
                  .get())
              .length;
      final int narrowMs = sw.elapsedMilliseconds;

      Future<String> timed(String label, Future<Object?> Function() f) async {
        final Stopwatch s = Stopwatch()..start();
        await f();
        return '$label=${s.elapsedMilliseconds}ms';
      }

      final List<String> other = <String>[
        await timed('deckTree', store.deckTree),
        await timed('allCardRows', store.allCardRows),
        await timed(
          'notesCache',
          () => (db.select(
            db.srsNotesCache,
          )..where((x) => x.profileUid.equals(kBulkUid))).get(),
        ),
        await timed('allNoteViews', store.allNoteViews),
        await timed('noteTypes', store.noteTypes),
      ];
      // ignore: avoid_print
      print('BENCH other: ${other.join(' ')}');

      await db.customStatement(
        'CREATE TABLE tmp_proj (log_id TEXT PRIMARY KEY, profile_uid TEXT, '
        'card_id TEXT, occurred_at INT, utc_offset_min INT, rating INT, '
        'kind INT, duration_ms INT, prev_due_day INT, maturity INT)',
      );
      await db.customStatement(
        'INSERT INTO tmp_proj SELECT id, profile_uid, card_id, occurred_at, '
        '540, rating, 1, duration_ms, NULL, 0 FROM srs_review_logs '
        "WHERE kind = 'review'",
      );
      sw.reset();
      final int projRows =
          (await db
                  .customSelect(
                    'SELECT card_id, occurred_at, utc_offset_min, rating, kind, '
                    'duration_ms, prev_due_day, maturity FROM tmp_proj '
                    'WHERE profile_uid = ?',
                    variables: <Variable<Object>>[Variable<String>(kBulkUid)],
                  )
                  .get())
              .length;
      // ignore: avoid_print
      print('BENCH proj($projRows)=${sw.elapsedMilliseconds}ms');

      sw.reset();
      final int rss0 = ProcessInfo.currentRss;
      final SrsStatsBundle b = await loadSrsStats(store);
      final int loadMs = sw.elapsedMilliseconds;
      final int rssDelta = ProcessInfo.currentRss - rss0;
      sw.reset();
      final SrsStatsBundle b2 = await loadSrsStats(store);
      final int warmMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        'BENCH notes=$notes logs=$logCount reviews=$reviews/${b.data.reviews.length} '
        'cards=${b.data.cards.length} | phases: rows=${rowsMs}ms '
        'decode=${decodeMs}ms history=${historyMs}ms narrowCols($narrow)=${narrowMs}ms | '
        'loadSrsStats cold=${loadMs}ms warm=${warmMs}ms(${b2.data.reviews.length}) '
        'rssDelta=${rssDelta ~/ (1 << 20)}MB maxRss=${ProcessInfo.maxRss ~/ (1 << 20)}MB',
      );
    },
    skip: n == null ? 'set FUSHI_SRS_STATS_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
