import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';
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
/// srs.db，经 Rust `SrsCore.statProjection` 走生产的投影路径，再按 [day] 口径展开成统计记录。
/// 全部日志合成一个归属组，归属卡 = 第一条日志的卡。
({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity})
statsViaRust(List<SrsReviewLog> logs, SrsDayContext day) {
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
  return srsStatsFromProjection(<SrsStatProjection>[
    for (final List<Object?> r in rows)
      SrsStatProjection(
        logId: r[1]! as String,
        cardId: owner,
        occurredAt: r[2]! as int,
        utcOffsetMin: r[3]! as int,
        rating: r[4] as int?,
        kind: SrsStatReviewKind.values[r[5]! as int],
        durationMs: r[6]! as int,
        prevDueDay: r[7] as int?,
        maturityDelta: r[8]! as int,
      ),
  ], day);
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
      expect(out.reviews.map((SrsStatReview r) => r.kind), <SrsStatReviewKind>[
        SrsStatReviewKind.newCard,
        SrsStatReviewKind.learn,
        SrsStatReviewKind.young,
        SrsStatReviewKind.mature,
        SrsStatReviewKind.relearn,
      ]);
      expect(out.maturity.map((SrsStatMaturityEvent e) => e.delta), <int>[
        1,
        -1,
      ]);
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
      expect(out.reviews.map((SrsStatReview r) => r.early), <bool>[
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

  group('srsStatsBuckets', () {
    test('≤ 92 天逐日、≤ 400 天逐周（末周完整）、更长按自然月', () {
      final int today = srsDateToDay(2026, 10, 15);
      final (SrsBucketUnit u1, List<SrsDayBucket> b1) = srsStatsBuckets(
        today - 29,
        today,
      );
      expect(u1, SrsBucketUnit.day);
      expect(b1, hasLength(30));
      final (SrsBucketUnit u2, List<SrsDayBucket> b2) = srsStatsBuckets(
        today - 364,
        today,
      );
      expect(u2, SrsBucketUnit.week);
      expect(b2.last, SrsDayBucket(today - 6, today));
      expect(b2.first.firstDay, today - 364);
      expect(b2.fold<int>(0, (int a, SrsDayBucket b) => a + b.days), 365);
      final (SrsBucketUnit u3, List<SrsDayBucket> b3) = srsStatsBuckets(
        srsDateToDay(2025, 1, 20),
        today,
      );
      expect(u3, SrsBucketUnit.month);
      expect(
        b3.first,
        SrsDayBucket(srsDateToDay(2025, 1, 20), srsDateToDay(2025, 1, 31)),
      );
      expect(b3.last, SrsDayBucket(srsDateToDay(2026, 10, 1), today));
      expect(b3, hasLength(22));
    });
  });

  group('SrsStatsData 聚合', () {
    final int nowMs = jst(2026, 10, 15, 21);
    final int today = kJst.dayIndexOf(nowMs);

    SrsStatReview rv(
      String card,
      int day,
      int rating,
      SrsStatReviewKind kind, {
      int hour = 10,
      int dur = 10000,
      bool early = false,
    }) => SrsStatReview(
      cardId: card,
      at: kJst.dayStartMs(day) + (hour - 4) * 3600000,
      day: day,
      hour: hour,
      rating: rating,
      kind: kind,
      durationMs: dur,
      early: early,
    );

    final SrsStatsData data = SrsStatsData(
      day: kJst,
      nowMs: nowMs,
      reviews: <SrsStatReview>[
        rv('a', today, 3, SrsStatReviewKind.newCard, hour: 9),
        rv('a', today, 1, SrsStatReviewKind.learn, hour: 9),
        rv('b', today, 4, SrsStatReviewKind.mature, hour: 21),
        rv('c', today, 1, SrsStatReviewKind.mature, hour: 21),
        rv('d', today, 3, SrsStatReviewKind.young, early: true),
        rv('b', today - 1, 3, SrsStatReviewKind.young),
        rv('b', today - 2, 2, SrsStatReviewKind.young),
        rv('c', today - 4, 3, SrsStatReviewKind.relearn),
        rv('c', today - 40, 3, SrsStatReviewKind.filtered),
      ],
      cards: <SrsStatCard>[
        SrsStatCard(
          id: 'a',
          noteId: 'n1',
          deckId: 'd',
          state: SrsStatCardState.learning,
          dueAt: nowMs + 600000,
          addedDay: today,
        ),
        SrsStatCard(
          id: 'b',
          noteId: 'n2',
          deckId: 'd',
          state: SrsStatCardState.mature,
          intervalDays: 30,
          dueDay: today + 30,
          stability: 40,
          difficulty: 5.5,
          retrievability: 0.92,
          addedDay: today - 60,
          desiredRetention: 0.9,
        ),
        SrsStatCard(
          id: 'c',
          noteId: 'n2',
          deckId: 'd',
          state: SrsStatCardState.young,
          intervalDays: 2,
          dueDay: today - 3,
          stability: 2,
          difficulty: 9,
          retrievability: 0.61,
          lapses: 9,
          addedDay: today - 60,
          desiredRetention: 0.8,
        ),
        SrsStatCard(
          id: 'd',
          noteId: 'n3',
          deckId: 'd',
          state: SrsStatCardState.young,
          intervalDays: 5,
          dueDay: today + 1,
          stability: 5,
          difficulty: 1,
          suspended: true,
          addedDay: today - 1,
        ),
        SrsStatCard(
          id: 'e',
          noteId: 'n4',
          deckId: 'd',
          state: SrsStatCardState.newCard,
          buried: true,
          addedDay: today - 100,
        ),
      ],
      maturityEvents: const <SrsStatMaturityEvent>[],
      sources: <String, SrsSourceRef?>{
        'n1': SrsSourceRef.book(
          bookKey: 'k',
          sectionIndex: 0,
          charStart: 0,
          title: '無職転生',
        ),
        'n2': SrsSourceRef.book(
          bookKey: 'k',
          sectionIndex: 1,
          charStart: 5,
          title: '無職転生',
        ),
        'n3': SrsSourceRef.media(
          kind: SrsSourceKind.video,
          mediaKey: 'v',
          startMs: 0,
          title: 'Frieren',
        ),
      },
    );

    test('今日：数量、用时、评分分布、各类计数、提前复习、成熟正确率', () {
      final SrsTodayStats s = data.todayStats();
      expect(s.count, 5);
      expect(s.durationMs, 50000);
      expect(s.ratings, <int>[2, 0, 2, 1]);
      expect(s.correct, 3);
      expect(s.kind(SrsStatReviewKind.mature), 2);
      expect(s.early, 1);
      expect(s.matureCorrect, 1);
      expect(s.matureTotal, 2);
    });

    test('未来到期：逾期单列、学习卡算今天、暂停不算、负担 Σ1/间隔', () {
      final SrsFutureDue f = data.futureDue(31);
      expect(f.overdue, 1); // c
      expect(f.dueToday, 1); // a（学习中）
      expect(f.dueTomorrow, 0); // d 已暂停
      expect(f.perDay[30], 1); // b
      expect(f.youngPerDay[30], 0);
      expect(f.total, 2);
      expect(f.dailyLoad, closeTo(1 + 1 / 30 + 1 / 2, 1e-9));
    });

    test('打卡：今天有复习从今天数，最长连续', () {
      final SrsStreak s = data.streak();
      expect(s.current, 3);
      expect(s.longest, 3);
    });

    test('复习量按日分桶，范围外的不计', () {
      final (SrsBucketUnit unit, List<SrsReviewBucket> b) = data.reviewBuckets(
        SrsStatsRange.month,
      );
      expect(unit, SrsBucketUnit.day);
      expect(b, hasLength(30));
      expect(b.last.totalCount, 5);
      expect(b.last.counts[SrsStatReviewKind.mature], 2);
      expect(b.fold<int>(0, (int a, SrsReviewBucket x) => a + x.totalCount), 8);
      final SrsReviewTotals tot = data.reviewTotals(SrsStatsRange.month);
      expect(tot.daysStudied, 4);
      expect(tot.count, 8);
      expect(data.reviewTotals(SrsStatsRange.threeMonths).count, 9);
    });

    test('卡片计数：暂停 / 搁置优先于学习状态', () {
      final SrsCardCounts c = data.cardCounts();
      expect(c.learning, 1);
      expect(c.mature, 1);
      expect(c.young, 1);
      expect(c.suspended, 1);
      expect(c.buried, 1);
      expect(c.newCards, 0);
      expect(c.total, 5);
    });

    test('分布：间隔 / 难度 / 可提取度', () {
      final SrsHistogram iv = data.intervalHistogram();
      expect(iv.total, 3);
      expect(iv.mean, closeTo((30 + 2 + 5) / 3, 1e-9));
      final SrsHistogram d = data.difficultyHistogram();
      expect(d.total, 3);
      expect(d.bins.first.count, 1); // D=1 → 0%
      final SrsHistogram r = data.retrievabilityHistogram();
      expect(r.total, 2);
      expect(r.sum, closeTo(1.53, 1e-9));
    });

    test('按小时与评分按钮', () {
      final SrsHourly h = data.hourly(SrsStatsRange.month);
      expect(h.counts[21], 2);
      expect(h.rateAt(21), 0.5);
      expect(h.counts[9], 2);
      final SrsButtons b = data.buttons(SrsStatsRange.month);
      expect(b.learning.ratings, <int>[1, 0, 2, 0]);
      expect(b.mature.ratings, <int>[1, 0, 0, 1]);
      expect(b.young.ratings, <int>[0, 1, 2, 0]);
      // 筛选复习不进按钮分布。
      expect(data.buttons(SrsStatsRange.all).learning.total, 3);
    });

    test('真实保留率与期望保留率', () {
      final SrsRetention r = data.retentionBetween(today - 29, today);
      expect(r.youngTotal, 3);
      expect(r.youngCorrect, 3);
      expect(r.matureTotal, 2);
      expect(r.matureRate, 0.5);
      expect(data.desiredRetention(), closeTo((0.9 + 0.8 + 0.8) / 3, 1e-9));
      expect(data.lapsesBetween(today, today), 1);
    });

    test('添加、易忘、来源、筛选', () {
      final (_, List<SrsReviewBucket> b) = data.reviewBuckets(
        SrsStatsRange.month,
      );
      final List<int> added = data.addedCounts(<SrsDayBucket>[
        for (final SrsReviewBucket x in b) x.bucket,
      ]);
      expect(added.last, 1);
      expect(added[28], 1);
      expect(added.fold<int>(0, (int a, int x) => a + x), 2);
      expect(data.leeches().single.id, 'c');
      final List<SrsSourceShare> s = data.sourceShares();
      expect(s.first.title, '無職転生');
      expect(s.first.notes, 2);
      expect(s.map((SrsSourceShare x) => x.kind), contains(''));
      final SrsStatsData sub = data.subset(<String>{'b'});
      expect(sub.cards.single.id, 'b');
      expect(sub.reviews, hasLength(3));
      expect(data.firstDayOf(SrsStatsRange.all), today - 100);
    });

    test('成熟卡增长：按桶末累计', () {
      final SrsStatsData d = SrsStatsData(
        day: kJst,
        nowMs: nowMs,
        reviews: const <SrsStatReview>[],
        cards: const <SrsStatCard>[],
        maturityEvents: <SrsStatMaturityEvent>[
          SrsStatMaturityEvent(cardId: 'x', day: today - 50, delta: 1),
          SrsStatMaturityEvent(cardId: 'y', day: today - 5, delta: 1),
          SrsStatMaturityEvent(cardId: 'x', day: today - 2, delta: -1),
        ],
      );
      final List<int> m = d.matureCountsAt(<SrsDayBucket>[
        SrsDayBucket(today - 10, today - 6),
        SrsDayBucket(today - 5, today - 3),
        SrsDayBucket(today - 2, today),
      ]);
      expect(m, <int>[1, 2, 1]);
    });

    test('RWKV 此刻：现在该复习 / 接近目标线按 R 与所在牌组目标数；日均只数这些卡近 30 天的复习', () {
      SrsStatCard rwkv(String id, double? r, {bool suspended = false}) =>
          SrsStatCard(
            id: id,
            noteId: 'n$id',
            deckId: 'd',
            state: SrsStatCardState.mature,
            suspended: suspended,
            retrievability: r,
            desiredRetention: 0.8,
            byRecall: true,
          );
      SrsStatReview review(String cardId, int day) => SrsStatReview(
        cardId: cardId,
        at: kJst.dayStartMs(day),
        day: day,
        hour: 9,
        rating: 3,
        kind: SrsStatReviewKind.mature,
      );
      final SrsStatsData d = SrsStatsData(
        day: kJst,
        nowMs: nowMs,
        reviews: <SrsStatReview>[
          review('a', today),
          review('b', today - 29),
          review('b', today - 30), // 超出 30 天
          review('f', today), // FSRS 卡不算
        ],
        cards: <SrsStatCard>[
          rwkv('a', 0.8), // = 目标：该复习
          rwkv('b', 0.84), // 接近
          rwkv('c', 0.9),
          rwkv('e', 0.1, suspended: true),
          const SrsStatCard(
            id: 'f',
            noteId: 'nf',
            deckId: 'd2',
            state: SrsStatCardState.young,
            dueDay: 0,
          ),
        ],
        maturityEvents: const <SrsStatMaturityEvent>[],
      );
      final SrsRwkvNow now = d.rwkvNow!;
      expect(now.total, 3);
      expect(now.due, 1);
      expect(now.near, 1);
      expect(now.dailyAverage, closeTo(2 / 30, 1e-9));
      expect(d.hasDueDateCards, isTrue, reason: 'FSRS 卡 f 按到期日');
      final SrsStatsData onlyRwkv = d.subset(<String>{'a', 'b', 'c'});
      expect(onlyRwkv.hasDueDateCards, isFalse);
      expect(d.subset(<String>{'f'}).rwkvNow, isNull, reason: '没有按 R 排队的卡');
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

      final SrsStatsBundle b = await loadSrsStats(
        store,
        day: kJst,
        nowMs: jst(2026, 10, 15, 3),
      );
      final SrsStatsData d = b.data;
      expect(d.reviews, hasLength(2));
      expect(
        d.reviews.every(
          (SrsStatReview r) => r.kind == SrsStatReviewKind.newCard,
        ),
        isTrue,
      );
      expect(d.reviews.map((SrsStatReview r) => r.day).toSet(), <int>{
        srsDateToDay(2026, 10, 14),
      });
      expect(d.todayStats().count, 2);
      expect(d.todayStats().durationMs, 10000);
      expect(d.cards, hasLength(2));
      expect(
        d.cards.firstWhere((SrsStatCard c) => c.id == c1).retrievability,
        0.9,
      );
      expect(
        d.sourceShares().map((SrsSourceShare s) => s.title),
        contains('本'),
      );

      final Set<String> inSub = b.index.cardIdsInDeck(sub);
      expect(inSub, <String>{c2});
      expect(d.subset(inSub).reviews.single.cardId, c2);
      expect(b.index.decks.map(((String, String) x) => x.$2), contains('語彙'));
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
  SrsMemory _step(SrsMemory? m, int r) => SrsMemory(
    stability: switch (r) {
      1 => 0.3,
      2 => 1.5 + (m?.stability ?? 0),
      3 => 3 + (m?.stability ?? 0) * 2,
      _ => 6 + (m?.stability ?? 0) * 3,
    },
    difficulty: 5,
  );
  @override
  SrsNextStates nextStates({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double desiredRetention,
    required SrsMemory? memory,
    required double elapsedDays,
  }) {
    SrsItemState st(int r) {
      final SrsMemory m = _step(memory, r);
      return SrsItemState(memory: m, interval: m.stability);
    }

    return SrsNextStates(again: st(1), hard: st(2), good: st(3), easy: st(4));
  }

  @override
  SrsMemory? memoryState({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsFsrsReview> reviews,
    SrsMemory? starting,
  }) {
    SrsMemory? m = starting;
    for (final SrsFsrsReview r in reviews) {
      m = _step(m, r.rating);
    }
    return m;
  }

  @override
  SrsMemory memoryStateFromSm2({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double easeFactor,
    required double intervalDays,
    required double sm2Retention,
  }) => SrsMemory(stability: intervalDays, difficulty: 5);
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
