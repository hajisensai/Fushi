import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';

import 'package:fushi/src/srs/srs_home_stats.dart';

import 'srs_test_support.dart';

/// 复习首页（今日计划 / 牌组行进度 / 热力图 / 未来 7 天 / 牌组详情）取统计结果里的数。
///
/// 聚合本身（今天按牌组计、窗口、到期预测、打卡）在内核 store/stats.rs，那边的单测钉口径；这里核对首页从
/// 内核结果里取哪些数、怎么折算，以及牌组详情真的按牌组子树向内核要子集。
void main() {
  /// 内核 `stats_report` 形状的最小结果（只填首页读的字段，其余给空值）。
  SrsStatsReport report({
    int today = 20000,
    int count = 0,
    List<int> streak = const <int>[0, 0],
    Map<int, int> countsByDay = const <int, int>{},
    List<int> recent = const <int>[0, 0, 0, 0, 0, 0, 0, 14],
    int overdue = 0,
    List<int> perDay = const <int>[0, 0, 0, 0, 0, 0, 0],
    Map<String, int> todayByDeck = const <String, int>{},
  }) {
    final Map<String, Object?> hist = <String, Object?>{
      'bins': <Object?>[],
      'total': 0,
      'mean': null,
      'median': null,
      'openEnded': false,
      'sum': 0.0,
    };
    return SrsStatsReport.fromJson(
      <String, Object?>{
        'today': today,
        'empty': false,
        'earliestDay': today,
        'firstDay': today - 29,
        'retrievabilityAvailable': true,
        'todayStats': <Object?>[
          count,
          0,
          <int>[0, 0, 0, 0],
          <int>[0, 0, 0, 0, 0, 0],
          0,
          0,
          0,
        ],
        'streak': streak,
        'countsByDay': <Object?>[
          for (final MapEntry<int, int> e in countsByDay.entries)
            <int>[e.key, e.value],
        ],
        'future': <String, Object?>{
          'overdue': overdue,
          'byRecall': 0,
          'load': 0.0,
          'perDay': perDay,
          'youngPerDay': List<int>.filled(perDay.length, 0),
          'unit': 'day',
          'buckets': <Object?>[],
        },
        'furthestDue': 30,
        'rwkvNow': null,
        'hasDueDateCards': true,
        'reviews': <String, Object?>{'unit': 'day', 'buckets': <Object?>[]},
        'matureAt': <int>[],
        'added': <int>[],
        'cardCounts': <int>[0, 0, 0, 0, 0, 0, 0],
        'hist': <String, Object?>{
          'interval': hist,
          'stability': hist,
          'difficulty': hist,
          'retrievability': hist,
        },
        'hourly': <Object?>[List<int>.filled(24, 0), List<int>.filled(24, 0)],
        'buttons': <Object?>[
          <int>[0, 0, 0, 0],
          <int>[0, 0, 0, 0],
          <int>[0, 0, 0, 0],
        ],
        'windows': <String, Object?>{
          'recent': recent,
          kSrsStatsRangeWindow: <int>[0, 0, 0, 0, 0, 0, 0, 30],
        },
        'desiredRetention': null,
        'sources': <Object?>[],
        'todayByDeck': todayByDeck,
        'learningDueAts': <int>[],
        'reviewsNextDay': 0,
      },
      range: SrsStatsRange.month,
      nowMs: 0,
    );
  }

  group('srsHomeStatsOf', () {
    test('没有复习记录：今天 0、用时 0、连续 0、预测全 0', () {
      final SrsHomeStats s = srsHomeStatsOf(report());
      expect(s.doneToday, 0);
      expect(s.averageMsPerCard, 0);
      expect(s.streak, 0);
      expect(s.longestStreak, 0);
      expect(s.countsByDay, isEmpty);
      expect(s.forecast, List<int>.filled(kSrsHomeForecastDays, 0));
      expect(s.today, 20000);
    });

    test('今天次数 / 连续 / 最长连续 / 热力图照抄；平均用时 = 最近窗口的用时 ÷ 次数', () {
      final SrsHomeStats s = srsHomeStatsOf(
        report(
          count: 2,
          streak: const <int>[3, 4],
          countsByDay: const <int, int>{20000: 2, 19996: 1},
          // [年轻答对, 年轻总数, 成熟答对, 成熟总数, 次数, 用时, 学习天数, 天数]
          recent: const <int>[0, 0, 0, 0, 2, 8000, 2, 14],
        ),
      );
      expect(s.doneToday, 2);
      expect(s.streak, 3);
      expect(s.longestStreak, 4);
      expect(s.averageMsPerCard, 4000);
      expect(s.countsByDay[20000], 2, reason: '热力图：日序号 → 复习次数');
      expect(s.countsByDay[19996], 1);
    });

    test('每个牌组今天的复习次数：父牌组含子牌组', () {
      final SrsHomeStats s = srsHomeStatsOf(
        report(todayByDeck: const <String, int>{'parent': 2, 'child': 1}),
      );
      expect(s.doneTodayByDeck, <String, int>{'parent': 2, 'child': 1});
      expect(s.doneTodayIn(<String>{'parent', 'child'}), 3);
      expect(s.doneTodayIn(<String>{'child'}), 1);
      expect(s.doneTodayIn(<String>{'other'}), 0);
    });

    test('全库未来 7 天：逾期并进今天', () {
      final SrsHomeStats s = srsHomeStatsOf(
        report(overdue: 1, perDay: const <int>[1, 2, 0, 0, 0, 0, 1]),
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
        dailyLoad: 0,
      );
      expect(srsHomeForecastOf(due), <int>[6, 2, 3]);
    });
  });

  group('srsHomeDeckDetailOf / detailFor（真实库）', () {
    test('父牌组连同子牌组一起算、子牌组只算自己；按牌组记住结果；没有装载时为 null', () async {
      final SrsTestClock clock = SrsTestClock();
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore(
        clock: clock,
      );
      addTearDown(db.close);
      final String parent = await store.createDeck('Parent');
      final String child = await store.createDeck('Child', parentId: parent);
      Future<String> card(String deck, String word) async {
        final String note = await store.createNote(
          noteTypeId: store.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(kSrsTestProfile, 'Expression'): word,
          },
          deckId: deck,
        );
        return (await store.cardsOfNote(note)).single.id;
      }

      final String p1 = await card(parent, '食べる');
      final String c1 = await card(child, '飲む');
      await card(child, '見る');
      await store.answer(p1, 3);
      await store.answer(c1, 3);

      final SrsStatsLoad load = await loadSrsStats(store);
      final SrsHomeStats s = srsHomeStatsOf(
        await srsHomeReportOf(load),
        load: load,
      );
      expect(s.doneToday, 2);
      expect(s.doneTodayByDeck, <String, int>{parent: 1, child: 1});

      final Future<SrsHomeDeckDetail>? first = s.detailFor(parent, <String>{
        parent,
        child,
      });
      expect(first, isNotNull);
      expect(
        identical(s.detailFor(parent, <String>{parent, child}), first),
        isTrue,
      );
      final SrsHomeDeckDetail all = await first!;
      expect(all.newCards, 1);
      expect(all.reviewsRecent, 2);
      expect(all.forecast, hasLength(kSrsHomeForecastDays));
      final SrsHomeDeckDetail only = await srsHomeDeckDetailOf(load, <String>{
        child,
      });
      expect(only.newCards, 1);
      expect(only.reviewsRecent, 1);
      final SrsHomeDeckDetail none = await srsHomeDeckDetailOf(load, <String>{
        'empty',
      });
      expect(none.retention, isNull);
      expect(none.reviewsRecent, 0);
      expect(none.newCards, 0);
      expect(none.desiredRetention, isNull);

      expect(
        SrsHomeStats(
          doneToday: 0,
          averageMsPerCard: 0,
          streak: 0,
        ).detailFor(parent, <String>{parent}),
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
