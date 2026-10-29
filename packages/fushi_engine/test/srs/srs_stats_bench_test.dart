// 复习统计装载在大日志量下的墙钟 / 内存（手动跑；默认跳过）。
//
// FUSHI_SRS_STATS_BENCH=<笔记数> dart test test/srs/srs_stats_bench_test.dart
//
// 每条笔记两张卡、每卡 3 条导入 revlog + 1 条导入锚点：25000 条笔记 = 20 万条日志 / 15 万条复习。
// phases 是旧装载路径（全量读日志 → jsonDecode）与按卡在 Rust 里算投影（`SrsCore.statProjection`）各段的
// 耗时，作对照；loadSrsStats 是现在的路径（读有效复习投影 srs_stat_reviews，BUG-3772）。
// 库开在临时 srs.db 上、走后台 isolate（与 app 同一种连接）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_bulk_fixture.dart';
import 'support/srs_test_storage.dart';
import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_STATS_BENCH'];

  test(
    '统计装载耗时',
    () async {
      final int notes = int.parse(n!);
      final Directory tmp = Directory.systemTemp.createTempSync('srs_stats_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      final TestSrs srs = await openTestSrsAt(
        '${tmp.path}/srs.db',
        inline: false,
      );
      final SrsDatabase db = srs.db;
      final SrsDbStore store = await SrsDbStore.open(
        db: db,
        core: srs.core,
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
      // 每张卡单独一组（基准包没有更改笔记类型）：Rust 读日志、选取、分类。
      final (int _, List<List<Object?>> projected) = srsDecodeRows(
        srs.core.statProjection(<List<String>>[
          for (final String c in byCard.keys) <String>[c],
        ]),
      );
      final int reviews = srsStatsFromProjection(<SrsStatProjection>[
        for (final List<Object?> r in projected)
          SrsStatProjection(
            logId: r[1]! as String,
            cardId: byCard.keys.elementAt(r[0]! as int),
            occurredAt: r[2]! as int,
            utcOffsetMin: r[3]! as int,
            rating: r[4] as int?,
            kind: SrsStatReviewKind.values[r[5]! as int],
            durationMs: r[6]! as int,
            prevDueDay: r[7] as int?,
            maturityDelta: r[8]! as int,
          ),
      ], day).reviews.length;
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
        await timed('noteTypes', store.noteTypes),
      ];
      // ignore: avoid_print
      print('BENCH other: ${other.join(' ')}');

      // 存量库升级（缓存修订号 1 → 当前）时一次性补算投影的耗时。
      await db.customStatement('DELETE FROM srs_stat_reviews');
      await db.customStatement(
        "UPDATE srs_local_state SET json = json_set(json, '\$.cacheRev', 1)",
      );
      sw.reset();
      await SrsDbStore.open(
        db: db,
        core: srs.core,
        profileUid: kBulkUid,
        deviceId: 'bench',
        engine: const FakeFsrsEngine(),
        trustedClock: fixedTrustedClock(),
        fallbackRolloverHour: () => 4,
      );
      // ignore: avoid_print
      print('BENCH upgradeBackfill=${sw.elapsedMilliseconds}ms');

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
