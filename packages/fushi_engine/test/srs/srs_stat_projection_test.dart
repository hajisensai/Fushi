// 有效复习投影（srs_stat_reviews）的真实库契约（BUG-3770）：
// - 增量维护的结果 = 整份重建的结果 = 从原始日志逐卡重放的结果；
// - undo / 再答 / 导入 revlog 都随卡片缓存重算；保留原始时刻，日界换了读时重分桶；
// - 存量库（缓存修订号 < 2）打开时补齐；
// - 统计读取路径不再读 srs_review_logs。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_bulk_fixture.dart' show importBench;

const String _uid = '01928c3e-0000-7000-8000-00000000a682';

/// 记下每条 SELECT 的 SQL（判「读取路径碰没碰日志表」）。
class _SqlLog extends QueryInterceptor {
  final List<String> selects = <String>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects.add(statement);
    return executor.runSelect(statement, args);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // JST 2026-10-14 10:00。
  int now = DateTime.utc(2026, 10, 14, 1).millisecondsSinceEpoch;
  const SrsDayContext jst = SrsDayContext(rolloverHour: 4, utcOffsetMin: 540);

  late _SqlLog sql;
  late FushiDatabase db;
  late SrsDbStore store;

  Future<SrsDbStore> open() => SrsDbStore.open(
    db: db,
    profileUid: _uid,
    deviceId: 'dev',
    engine: const FakeFsrsEngine(),
    trustedClock: SrsTrustedClock(
      wallClockMs: () => now,
      monotonicMs: () => now,
      bootId: 'b',
    ),
    fallbackRolloverHour: () => 4,
  );

  setUp(() async {
    now = DateTime.utc(2026, 10, 14, 1).millisecondsSinceEpoch;
    sql = _SqlLog();
    db = FushiDatabase.forTesting(NativeDatabase.memory().interceptWith(sql));
    store = await open();
  });

  tearDown(() => db.close());

  Future<List<String>> projectionRows() async => <String>[
    for (final QueryRow r
        in await db
            .customSelect(
              'SELECT log_id, card_id, occurred_at, utc_offset_min, rating, kind, '
              'duration_ms, prev_due_day, maturity_delta FROM srs_stat_reviews '
              'ORDER BY log_id',
            )
            .get())
      jsonEncode(r.data),
  ];

  /// 旧装载路径的结果：全量读日志、逐条 jsonDecode、按卡重放（BUG-3770 之前的实现）。
  Future<List<String>> fromRawLogs(SrsDayContext day) async {
    final Map<String, List<SrsReviewLog>> byCard =
        <String, List<SrsReviewLog>>{};
    for (final SrsReviewLogRow r in await db.select(db.srsReviewLogs).get()) {
      (byCard[r.cardId] ??= <SrsReviewLog>[]).add(
        SrsReviewLog.fromJson(
          (jsonDecode(r.json) as Map).cast<String, Object?>(),
        ),
      );
    }
    final List<String> out = <String>[];
    for (final List<SrsReviewLog> logs in byCard.values) {
      final ({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity})
      one = srsStatsFromHistory(SrsCardHistory(logs), day);
      out.addAll(one.reviews.map(_review));
      out.addAll(one.maturity.map(_maturity));
    }
    return out..sort();
  }

  Future<List<String>> fromLoader(SrsDayContext day) async {
    final SrsStatsData d = (await loadSrsStats(
      store,
      day: day,
      nowMs: now,
    )).data;
    return <String>[
      ...d.reviews.map(_review),
      ...d.maturityEvents.map(_maturity),
    ]..sort();
  }

  /// 导入 3 条笔记（6 张卡、每卡 3 条 revlog）+ 原生复习 / 撤销 / 隔天再答。
  Future<void> scenario() async {
    await importBench(store, 3);
    final List<String> cards = <String>[
      for (final SrsCardCacheRow c in await store.allCardRows()) c.id,
    ]..sort();
    await store.answer(cards[0], 3, durationMs: 4000);
    final SrsReviewLog wrong = await store.answer(cards[1], 1);
    expect(await store.undo(cards[1], wrong.id), isTrue);
    now += 26 * 3600 * 1000;
    await store.answer(cards[0], 4, durationMs: 2500);
    await store.answer(cards[2], 2, durationMs: 9000);
  }

  test('增量 = 整份重建 = 从原始日志逐卡重放', () async {
    await scenario();
    final List<String> incremental = await projectionRows();
    expect(incremental, isNotEmpty);
    expect(await fromLoader(jst), await fromRawLogs(jst));

    await store.rebuildCaches();
    expect(await projectionRows(), incremental);
    expect(await fromLoader(jst), await fromRawLogs(jst));
  });

  test('undo 撤掉的复习不在投影里，再答进来；原始时刻保留、日界读时重分桶', () async {
    await importBench(store, 1);
    final String card = (await store.allCardRows()).first.id;
    final int before = (await projectionRows()).length;
    final SrsReviewLog l = await store.answer(card, 3, durationMs: 1234);
    expect(await projectionRows(), hasLength(before + 1));
    expect(await store.undo(card, l.id), isTrue);
    expect(await projectionRows(), hasLength(before));

    // JST 次日凌晨 2 点：按 4 点翻日算 10/14，按 0 点翻日算 10/15。
    now = DateTime.utc(2026, 10, 14, 17).millisecondsSinceEpoch;
    final SrsReviewLog again = await store.answer(card, 3, durationMs: 777);
    final QueryRow row = await db
        .customSelect(
          'SELECT occurred_at, duration_ms FROM srs_stat_reviews '
          'WHERE log_id = ?',
          variables: <Variable<Object>>[Variable<String>(again.id)],
        )
        .getSingle();
    expect(row.read<int>('occurred_at'), now);
    expect(row.read<int>('duration_ms'), 777);

    int dayOf(SrsStatsData d) =>
        d.reviews.firstWhere((SrsStatReview r) => r.at == now).day;
    final SrsStatsData at4 = (await loadSrsStats(store, day: jst)).data;
    const SrsDayContext midnight = SrsDayContext(
      rolloverHour: 0,
      utcOffsetMin: 540,
    );
    final SrsStatsData at0 = (await loadSrsStats(store, day: midnight)).data;
    expect(dayOf(at4), srsDateToDay(2026, 10, 14));
    expect(dayOf(at0), srsDateToDay(2026, 10, 15));
  });

  test('存量库（缓存修订号 1、投影表为空）打开时补齐', () async {
    await scenario();
    final List<String> want = await projectionRows();
    await db.customStatement('DELETE FROM srs_stat_reviews');
    await db.customStatement(
      "UPDATE srs_local_state SET json = json_set(json, '\$.cacheRev', 1)",
    );
    expect(await projectionRows(), isEmpty);

    store = await open();
    expect(await projectionRows(), want);
    final String json =
        (await db.customSelect('SELECT json FROM srs_local_state').getSingle())
            .read<String>('json');
    expect((jsonDecode(json) as Map)['cacheRev'], 2);
  });

  test('统计读取路径不读复习日志表（大量日志：240 条笔记 × 2 卡 × 4 条）', () async {
    await importBench(store, 240);
    final int logs =
        (await db
                .customSelect('SELECT COUNT(*) AS c FROM srs_review_logs')
                .getSingle())
            .read<int>('c');
    expect(logs, greaterThanOrEqualTo(1440));
    sql.selects.clear();
    final SrsStatsBundle b = await loadSrsStats(store, day: jst, nowMs: now);
    expect(b.data.reviews, hasLength(240 * 2 * 3));
    expect(
      sql.selects.where((String s) => s.contains('srs_review_logs')),
      isEmpty,
      reason: '统计页回到全量读日志 + 逐条 jsonDecode，就会随日志量线性变慢',
    );
    expect(await fromLoader(jst), await fromRawLogs(jst));
  });
}

String _review(SrsStatReview r) =>
    'r ${r.cardId} ${r.at} ${r.day} ${r.hour} ${r.rating} ${r.kind.name} '
    '${r.durationMs} ${r.early}';

String _maturity(SrsStatMaturityEvent m) => 'm ${m.cardId} ${m.day} ${m.delta}';
