import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';
import 'support/srs_stats_rows.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000aa';
const int kDayMs = 86400000;

/// JST（+9）、4 点翻日：真实用户最常见的口径。
const SrsDayContext kJst = SrsDayContext(utcOffsetMin: 540, rolloverHour: 4);

/// JST 本地时间 → 毫秒。
int jst(int y, int m, int d, int h, [int min = 0]) =>
    DateTime.utc(y, m, d, h, min).millisecondsSinceEpoch - 9 * 3600000;

int _seq = 0;

SrsReviewLog rlog(
  String card,
  int at, {
  required String type,
  int? rating,
  String kind = SrsLogKind.review,
  SrsScheduleResult? result,
  int dur = 8000,
  String? revokes,
  String? id,
  int utcOffsetMin = 540,
}) => SrsReviewLog(
  id: id ?? 'log-${_seq++}',
  profileUid: kProfile,
  cardId: card,
  kind: kind,
  rating: rating,
  revokesId: revokes,
  hlc: Hlc(at, _seq, 'w'),
  occurredAt: at,
  timeSource: SrsTimeSource.wall,
  origin: SrsLogOrigin.fushi,
  reviewType: type,
  durationMs: dur,
  utcOffsetMin: utcOffsetMin,
  result: result,
);

SrsScheduleResult res(SrsQueue q, {int ivl = 0, int? dueDay}) =>
    SrsScheduleResult(queue: q, scheduledDays: ivl, dueDay: dueDay);

/// 把内存里的日志（落库原文 = `canonical()`，与 `SrsDbStore` 写 `srs_review_logs` 同形）写进一份临时
/// srs.db，经 Rust `SrsCore.statProjection` 走生产的投影路径，再按 [day] 口径展开成统计记录（展开在生产里由
/// 内核 store/stats.rs 做，那边的单测钉同一组规则）。
/// 全部日志合成一个归属组，归属卡 = 第一条日志的卡。
({List<StatReviewRow> reviews, List<StatMaturityRow> maturity}) statsViaRust(
  List<SrsReviewLog> logs,
  SrsDayContext day,
) {
  final Directory dir = Directory.systemTemp.createTempSync('srs_stats_rust_');
  final SrsCore core = SrsCore.open('${dir.path}/srs.db')..legacyMarkNone();
  addTearDown(() {
    core.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });
  core.execBatch(
    <String>[
      'INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, '
          'review_type, origin, duration_ms, jslim) VALUES (srs_id(?), srs_id(?), srs_id(?), ?, ?, ?, ?, ?, ?, ?)',
    ],
    <(int, List<Object?>)>[
      for (final SrsReviewLog l in logs)
        (
          0,
          <Object?>[
            l.id,
            l.profileUid,
            l.cardId,
            l.kind,
            l.rating,
            l.occurredAt,
            l.reviewType,
            l.origin,
            l.durationMs,
            l.canonical(),
          ],
        ),
    ],
  );
  final String owner = logs.first.cardId;
  final List<String> group = <String>[
    owner,
    ...<String>{
      for (final SrsReviewLog l in logs) l.cardId,
    }.difference(<String>{owner}),
  ];
  final (int _, List<List<Object?>> rows) = srsDecodeRows(
    core.statProjection(<List<String>>[group]),
  );
  final List<StatReviewRow> reviews = <StatReviewRow>[];
  final List<StatMaturityRow> maturity = <StatMaturityRow>[];
  for (final List<Object?> r in rows) {
    final int at = r[2]! as int;
    final int dayIndex = day.dayIndexOf(at);
    final int? rating = r[4] as int?;
    final int? prevDue = r[7] as int?;
    if (rating != null) {
      reviews.add(
        StatReviewRow(
          cardId: owner,
          at: at,
          day: dayIndex,
          hour: ((at + (r[3]! as int) * 60000) % kDayMs) ~/ 3600000,
          rating: rating,
          kind: SrsStatReviewKind.values[r[5]! as int],
          durationMs: r[6]! as int,
          early: prevDue != null && prevDue > dayIndex,
        ),
      );
    }
    final int delta = r[8]! as int;
    if (delta != 0) maturity.add(StatMaturityRow(owner, dayIndex, delta));
  }
  return (reviews: reviews, maturity: maturity);
}

void main() {
  group('有效复习投影分类（srs.db → Rust stat_projection）', () {
    test('新卡 → 学习 → 年轻 → 成熟 → 重学，成熟事件 +1 / −1', () {
      final int d0 = jst(2026, 9, 1, 10);
      final List<SrsReviewLog> h = <SrsReviewLog>[
        rlog(
          'c',
          d0,
          type: SrsReviewType.learn,
          rating: 3,
          result: res(SrsQueue.learning),
        ),
        rlog(
          'c',
          d0 + 600000,
          type: SrsReviewType.learn,
          rating: 3,
          result: res(SrsQueue.review, ivl: 3),
        ),
        rlog(
          'c',
          d0 + 3 * kDayMs,
          type: SrsReviewType.review,
          rating: 3,
          result: res(SrsQueue.review, ivl: 25),
        ),
        rlog(
          'c',
          d0 + 28 * kDayMs,
          type: SrsReviewType.review,
          rating: 1,
          result: res(SrsQueue.relearning),
        ),
        rlog(
          'c',
          d0 + 28 * kDayMs + 600000,
          type: SrsReviewType.relearn,
          rating: 3,
          result: res(SrsQueue.review, ivl: 5),
        ),
      ];
      final out = statsViaRust(h, kJst);
      expect(out.reviews.map((StatReviewRow r) => r.kind), <SrsStatReviewKind>[
        SrsStatReviewKind.newCard,
        SrsStatReviewKind.learn,
        SrsStatReviewKind.young,
        SrsStatReviewKind.mature,
        SrsStatReviewKind.relearn,
      ]);
      expect(out.maturity.map((StatMaturityRow e) => e.delta), <int>[1, -1]);
      expect(out.maturity.first.day, kJst.dayIndexOf(d0 + 3 * kDayMs));
    });

    test('被 undo 撤销的评分不计', () {
      final int t = jst(2026, 9, 1, 10);
      final List<SrsReviewLog> h = <SrsReviewLog>[
        rlog(
          'c',
          t,
          id: 'a',
          type: SrsReviewType.learn,
          rating: 3,
          result: res(SrsQueue.learning),
        ),
        rlog(
          'c',
          t + 1000,
          kind: SrsLogKind.undo,
          type: SrsReviewType.manual,
          revokes: 'a',
        ),
        rlog(
          'c',
          t + 2000,
          type: SrsReviewType.learn,
          rating: 1,
          result: res(SrsQueue.learning),
        ),
      ];
      final out = statsViaRust(h, kJst);
      expect(out.reviews, hasLength(1));
      expect(out.reviews.single.rating, 1);
      // 撤销后它仍是新卡的第一次评分。
      expect(out.reviews.single.kind, SrsStatReviewKind.newCard);
    });

    test('翻日：凌晨 2 点算前一天；小时按日志自己的 UTC 偏移', () {
      final int lateNight = jst(2026, 10, 10, 2);
      final int morning = jst(2026, 10, 10, 5);
      final List<SrsReviewLog> h = <SrsReviewLog>[
        rlog(
          'c',
          lateNight,
          type: SrsReviewType.learn,
          rating: 3,
          result: res(SrsQueue.learning),
        ),
        // 旅行到 UTC+0 时复习的一条：小时按当时的本地时间（UTC 20 点）。
        rlog(
          'c',
          morning,
          type: SrsReviewType.learn,
          rating: 3,
          utcOffsetMin: 0,
          result: res(SrsQueue.learning),
        ),
      ];
      final out = statsViaRust(h, kJst);
      expect(out.reviews[0].day, srsDateToDay(2026, 10, 9));
      expect(out.reviews[0].hour, 2);
      expect(out.reviews[1].day, srsDateToDay(2026, 10, 10));
      expect(out.reviews[1].hour, 20);
    });

    test('到期前复习记为提前复习', () {
      final int t = jst(2026, 9, 1, 10);
      final int day = kJst.dayIndexOf(t);
      final List<SrsReviewLog> h = <SrsReviewLog>[
        rlog(
          'c',
          t,
          type: SrsReviewType.learn,
          rating: 3,
          result: res(SrsQueue.review, ivl: 10, dueDay: day + 10),
        ),
        rlog(
          'c',
          t + 2 * kDayMs,
          type: SrsReviewType.review,
          rating: 3,
          result: res(SrsQueue.review, ivl: 20, dueDay: day + 22),
        ),
        rlog(
          'c',
          t + 22 * kDayMs,
          type: SrsReviewType.review,
          rating: 3,
          result: res(SrsQueue.review, ivl: 40, dueDay: day + 62),
        ),
      ];
      final out = statsViaRust(h, kJst);
      expect(out.reviews.map((StatReviewRow r) => r.early), <bool>[
        false,
        true,
        false,
      ]);
    });

    test('手动改期 / 不认识的复习类型不进复习数，但更新状态', () {
      final int t = jst(2026, 9, 1, 10);
      final List<SrsReviewLog> h = <SrsReviewLog>[
        rlog(
          'c',
          t,
          kind: SrsLogKind.manual,
          type: SrsReviewType.manual,
          result: res(SrsQueue.review, ivl: 30),
        ),
        rlog(
          'c',
          t + kDayMs,
          type: SrsReviewType.review,
          rating: 4,
          result: res(SrsQueue.review, ivl: 60),
        ),
      ];
      final out = statsViaRust(h, kJst);
      expect(out.reviews.single.kind, SrsStatReviewKind.mature);
    });
  });

  group('loadSrsStats（真实库）', () {
    late SrsStorage srsStorage;
    late SrsDbStore store;
    int now = 0;

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      now = jst(2026, 10, 14, 10);
      srsStorage = await openTestSrsStorage();
      store = await SrsDbStore.open(
        db: srsStorage.db,
        core: srsStorage.core,
        profileUid: kProfile,
        deviceId: 'dev',
        engine: const _Engine(),
        trustedClock: SrsTrustedClock(
          wallClockMs: () => now,
          bootClockMs: () => now,
          bootId: 'b',
        ),
        fallbackRolloverHour: () => 4,
      );
    });

    Map<String, String> lapis(String expr) => <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expr,
    };

    test('评分 / 撤销 / 翻日 / 牌组筛选 / 可提取度', () async {
      final String sub = await store.createDeck('語彙');
      final String n1 = await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: lapis('食べる'),
        tags: const <String>['verb'],
        source: SrsSourceRef.book(
          bookKey: 'bk',
          sectionIndex: 0,
          charStart: 0,
          title: '本',
        ),
      );
      final String n2 = await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: lapis('飲む'),
        deckId: sub,
      );
      final String c1 = (await store.cardsOfNote(n1)).single.id;
      final String c2 = (await store.cardsOfNote(n2)).single.id;

      await store.answer(c1, 3, durationMs: 4000);
      final SrsReviewLog undone = await store.answer(c1, 1);
      expect(await store.undo(c1, undone.id), isTrue);
      // JST 次日凌晨 2 点：按 4 点翻日仍算 10/14。
      now = jst(2026, 10, 15, 2);
      await store.answer(c2, 4, durationMs: 6000);

      final SrsStatsLoad b = await loadSrsStats(
        store,
        day: kJst,
        nowMs: jst(2026, 10, 15, 3),
      );
      final StatsRows rows = StatsRows(await b.rows());
      expect(rows.reviews, hasLength(2));
      expect(
        rows.reviews.every(
          (StatReviewRow r) => r.kind == SrsStatReviewKind.newCard,
        ),
        isTrue,
      );
      expect(rows.reviews.map((StatReviewRow r) => r.day).toSet(), <int>{
        srsDateToDay(2026, 10, 14),
      });
      expect(rows.cards, hasLength(2));
      // 可提取度由内核按真 FSRS 公式算（不回调注入的 Dart 引擎）：有引擎就有值。
      expect(rows.retrievabilityAvailable, isTrue);
      final SrsStatsReport d = await b.report();
      expect(d.todayStats.count, 2);
      expect(d.todayStats.durationMs, 10000);
      expect(d.cardCounts.total, 2);
      expect(d.sources.map((SrsSourceShare s) => s.title), contains('本'));

      expect(b.subtree(sub), <String>{sub});
      expect(await b.cardIdsInDeck(sub), <String>[c2]);
      final SrsStatsReport inSub = await b.report(decks: b.subtree(sub));
      expect(inSub.todayStats.count, 1);
      expect(inSub.todayByDeck, <String, int>{sub: 1});
      expect(inSub.cardCounts.total, 1);
      expect(b.decks.map(((String, String) x) => x.$2), contains('語彙'));
    });

    // develop 上按 `SrsStatsData.sourceShares()` 写的同名用例（e10fe612256）：聚合搬进内核后，同一组出处、同一组
    // 期望值改走真实库——制卡写出处 → 笔记缓存行 → `stats_report`。
    test('制卡来源：带系列的出处按系列计（反馈 MCJLSBR5Wg），不带的按集标题', () async {
      Future<String> mine(String expr, SrsSourceRef source) => store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: lapis(expr),
        source: source,
      );
      await mine(
        '食べる',
        SrsSourceRef.media(
          kind: SrsSourceKind.video,
          mediaKey: 'e1',
          startMs: 0,
          title: 'RWBY - S01E01',
          seriesTitle: 'RWBY',
        ),
      );
      await mine(
        '飲む',
        SrsSourceRef.media(
          kind: SrsSourceKind.video,
          mediaKey: 'e2',
          startMs: 0,
          title: 'RWBY - S02E01',
          seriesTitle: 'RWBY',
        ),
      );
      await mine(
        '走る',
        SrsSourceRef.media(
          kind: SrsSourceKind.video,
          mediaKey: 'e3',
          startMs: 0,
          title: 'Solo',
        ),
      );

      final SrsStatsLoad b = await loadSrsStats(store, day: kJst, nowMs: now);
      final List<SrsSourceShare> s = (await b.report()).sources;
      expect(
        s.map((SrsSourceShare x) => (x.kind, x.title, x.notes)).toList(),
        <(String, String, int)>[
          (SrsSourceKind.video, 'RWBY', 2),
          (SrsSourceKind.video, 'Solo', 1),
        ],
      );
    });
  });
}

/// 确定性假内核（与 srs_db_store_test 同一套数值）。
class _Engine implements FsrsEngine {
  const _Engine();

  @override
  String get fsrsRev => 'fake';
  @override
  List<double> defaultParams(SrsAlgorithm a) =>
      List<double>.filled(a.paramCount, 1);
  @override
  String? validateParams(SrsAlgorithm a, List<double> p) => null;
  @override
  double retrievability({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsMemory memory,
    required double elapsedDays,
  }) => 0.9;
  @override
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
    SrsOptimizerControl? control,
  }) => defaultParams(algorithm);
  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
}
