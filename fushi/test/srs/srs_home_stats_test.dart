import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/srs/srs_home_stats.dart';

/// 复习首页（今日计划 / 牌组行进度 / 热力图 / 未来 7 天 / 牌组详情）的统计换算。
void main() {
  const SrsDayContext utc = SrsDayContext(utcOffsetMin: 0, rolloverHour: 0);
  const int dayMs = 86400000;
  // 2026-11-04 12:00 UTC。
  final int nowMs = DateTime.utc(2026, 11, 4, 12).millisecondsSinceEpoch;
  final int today = utc.dayIndexOf(nowMs);

  SrsStatReview review(
    String card,
    int day, {
    int durationMs = 0,
    int rating = 3,
    SrsStatReviewKind kind = SrsStatReviewKind.young,
  }) => SrsStatReview(
    cardId: card,
    at: nowMs - (today - day) * dayMs,
    day: day,
    hour: 12,
    rating: rating,
    kind: kind,
    durationMs: durationMs,
  );

  SrsStatCard card(
    String id,
    String deck, {
    SrsStatCardState state = SrsStatCardState.young,
    int? dueDay,
    double desiredRetention = 0.9,
  }) => SrsStatCard(
    id: id,
    noteId: 'n-$id',
    deckId: deck,
    state: state,
    intervalDays: 3,
    dueDay: dueDay,
    desiredRetention: desiredRetention,
  );

  SrsStatsData data(
    List<SrsStatReview> reviews, {
    List<SrsStatCard> cards = const <SrsStatCard>[],
  }) => SrsStatsData(day: utc, nowMs: nowMs, reviews: reviews, cards: cards);

  group('srsHomeStatsOf', () {
    test('没有复习记录：今天 0、用时 0、连续 0、预测全 0', () {
      final SrsHomeStats s = srsHomeStatsOf(data(const <SrsStatReview>[]));
      expect(s.doneToday, 0);
      expect(s.averageMsPerCard, 0);
      expect(s.streak, 0);
      expect(s.longestStreak, 0);
      expect(s.countsByDay, isEmpty);
      expect(s.forecast, List<int>.filled(kSrsHomeForecastDays, 0));
      expect(s.today, today);
    });

    test('今天按次数计（同一张卡重复学习算两次），连续天数截至今天，最长连续取历史', () {
      final SrsHomeStats s = srsHomeStatsOf(
        data(<SrsStatReview>[
          review('a', today, durationMs: 4000),
          review('a', today, durationMs: 6000),
          review('b', today - 1, durationMs: 8000),
          review('c', today - 2, durationMs: 6000),
          // 断了一天：不再计入连续。
          review('d', today - 4, durationMs: 6000),
          review('d', today - 5, durationMs: 6000),
          review('d', today - 6, durationMs: 6000),
          review('d', today - 7, durationMs: 6000),
        ]),
      );
      expect(s.doneToday, 2);
      expect(s.streak, 3);
      expect(s.longestStreak, 4);
      expect(s.averageMsPerCard, 6000);
      expect(s.countsByDay[today], 2, reason: '热力图：日序号 → 复习次数');
      expect(s.countsByDay[today - 4], 1);
    });

    test('平均用时只看最近 ${SrsHomeStats.recentDays} 天', () {
      final SrsHomeStats s = srsHomeStatsOf(
        data(<SrsStatReview>[
          review('a', today, durationMs: 3000),
          review('b', today - SrsHomeStats.recentDays + 1, durationMs: 5000),
          // 窗口外：不计入平均。
          review('c', today - SrsHomeStats.recentDays, durationMs: 100000),
        ]),
      );
      expect(s.averageMsPerCard, 4000);
      expect(s.doneToday, 1);
    });

    test('每个牌组今天的复习次数按卡片直接所在的牌组记，昨天的不算', () {
      final SrsHomeStats s = srsHomeStatsOf(
        data(
          <SrsStatReview>[
            review('a', today),
            review('a', today),
            review('b', today),
            review('b', today - 1),
            // 卡片已不可见（删掉 / 隐藏）：不归到任何牌组。
            review('gone', today),
          ],
          cards: <SrsStatCard>[card('a', 'parent'), card('b', 'child')],
        ),
      );
      expect(s.doneTodayByDeck, <String, int>{'parent': 2, 'child': 1});
      expect(s.doneTodayIn(<String>{'parent', 'child'}), 3, reason: '父牌组含子牌组');
      expect(s.doneTodayIn(<String>{'child'}), 1);
      expect(s.doneTodayIn(<String>{'other'}), 0);
    });

    test('全库未来 7 天：逾期并进今天，超出 7 天的不算', () {
      final SrsHomeStats s = srsHomeStatsOf(
        data(
          const <SrsStatReview>[],
          cards: <SrsStatCard>[
            card('overdue', 'd', dueDay: today - 3),
            card('today', 'd', dueDay: today),
            card('tomorrow1', 'd', dueDay: today + 1),
            card('tomorrow2', 'd', dueDay: today + 1),
            card('day6', 'd', dueDay: today + 6),
            card('far', 'd', dueDay: today + 7),
            card('new', 'd', state: SrsStatCardState.newCard),
          ],
        ),
      );
      expect(s.forecast, <int>[2, 2, 0, 0, 0, 0, 1]);
    });
  });

  group('srsHomeForecastOf', () {
    test('第 0 天 = 今天到期 + 已逾期，其余逐日照抄', () {
      const SrsFutureDue due = SrsFutureDue(
        overdue: 5,
        perDay: <int>[1, 2, 3],
        youngPerDay: <int>[0, 0, 0],
        daily: true,
        dailyLoad: 0,
        byRecall: 0,
      );
      expect(srsHomeForecastOf(due), <int>[6, 2, 3]);
    });
  });

  group('srsHomeDeckDetailOf / detailFor', () {
    final SrsStatsData d = data(
      <SrsStatReview>[
        review('p1', today, rating: 3),
        review('c1', today - 3, rating: 1),
        review('c1', today - 2, rating: 3, kind: SrsStatReviewKind.mature),
        // 30 天窗口外：不进保持率与近期复习数。
        review('p1', today - kSrsHomeRetentionDays, rating: 1),
        // 学习中的复习不算保持率，但算复习次数。
        review('c2', today, kind: SrsStatReviewKind.learn),
        // 别的牌组：不算。
        review('x1', today, rating: 1),
      ],
      cards: <SrsStatCard>[
        card('p1', 'parent', dueDay: today + 1),
        card('c1', 'child', state: SrsStatCardState.mature, dueDay: today + 2),
        card('c2', 'child', state: SrsStatCardState.newCard),
        card('c3', 'child', state: SrsStatCardState.newCard),
        card('x1', 'other', dueDay: today),
      ],
    );

    test('父牌组连同子牌组的卡一起算：张数、预测、保持率、近 30 天复习数、目标保持率', () {
      final SrsHomeDeckDetail detail = srsHomeDeckDetailOf(d, <String>{
        'parent',
        'child',
      });
      expect(detail.newCards, 2);
      expect(detail.matureCards, 1);
      expect(detail.forecast, <int>[0, 1, 1, 0, 0, 0, 0]);
      expect(detail.reviewsRecent, 4);
      // 复习卡口径：p1 今天对、c1 错一次对一次 → 2 / 3。
      expect(detail.retention, closeTo(2 / 3, 1e-9));
      expect(detail.desiredRetention, closeTo(0.9, 1e-9));
    });

    test('子牌组单独看只算自己的卡', () {
      final SrsHomeDeckDetail detail = srsHomeDeckDetailOf(d, <String>{
        'child',
      });
      expect(detail.newCards, 2);
      expect(detail.forecast, <int>[0, 0, 1, 0, 0, 0, 0]);
      expect(detail.retention, closeTo(1 / 2, 1e-9));
    });

    test('没有复习：保持率为 null', () {
      final SrsHomeDeckDetail detail = srsHomeDeckDetailOf(d, <String>{
        'empty',
      });
      expect(detail.retention, isNull);
      expect(detail.reviewsRecent, 0);
      expect(detail.newCards, 0);
      expect(detail.desiredRetention, isNull);
    });

    test('detailFor 按牌组记住结果；没有原始数据时为 null', () {
      final SrsHomeStats s = srsHomeStatsOf(d);
      final SrsHomeDeckDetail? first = s.detailFor('parent', <String>{
        'parent',
        'child',
      });
      expect(first, isNotNull);
      expect(
        identical(s.detailFor('parent', <String>{'parent', 'child'}), first),
        isTrue,
      );
      expect(
        SrsHomeStats(
          doneToday: 0,
          averageMsPerCard: 0,
          streak: 0,
        ).detailFor('parent', <String>{'parent'}),
        isNull,
      );
    });
  });

  group('SrsHomeStats', () {
    test('minutesFor：按平均用时估算并向上取整，最少 1 分钟', () {
      final SrsHomeStats s = SrsHomeStats(
        doneToday: 0,
        averageMsPerCard: 8000,
        streak: 0,
      );
      expect(s.minutesFor(30), 4, reason: '30 × 8 s = 240 s = 4 min');
      expect(s.minutesFor(31), 5, reason: '248 s 向上取整到 5 min');
      expect(s.minutesFor(1), 1, reason: '不足一分钟按 1 分钟');
      expect(s.minutesFor(0), isNull, reason: '没有剩余不显示');
    });

    test('minutesFor：没有用时数据时返回 null', () {
      final SrsHomeStats s = SrsHomeStats(
        doneToday: 5,
        averageMsPerCard: 0,
        streak: 1,
      );
      expect(s.minutesFor(20), isNull);
    });

    test('progressWith：已复习 ÷（已复习 + 剩余），全零视为完成', () {
      final SrsHomeStats s = SrsHomeStats(
        doneToday: 30,
        averageMsPerCard: 0,
        streak: 0,
      );
      expect(s.progressWith(10), 0.75);
      expect(s.progressWith(0), 1);
      final SrsHomeStats none = SrsHomeStats(
        doneToday: 0,
        averageMsPerCard: 0,
        streak: 0,
      );
      expect(none.progressWith(0), 1);
      expect(none.progressWith(12), 0);
    });
  });

  group('srsTodayProgress', () {
    test('已复习 ÷（已复习 + 剩余）；今天没事做时为 null', () {
      expect(srsTodayProgress(done: 1, remaining: 3), 0.25);
      expect(srsTodayProgress(done: 0, remaining: 5), 0);
      expect(srsTodayProgress(done: 4, remaining: 0), 1);
      expect(srsTodayProgress(done: 0, remaining: 0), isNull);
    });
  });
}
