// 复习统计「聚合结果」的对拍向量：统计页 / 首页 / 桌面小组件 / 操作目录读到的每一项聚合值。
//
// 输入是 srs_stats_vectors_test 的冻结库（fixtures/srs_stats_vectors.db.gz），可提取度用真排程内核
// （[FfiFsrsEngine]，与生产同一个函数）。条件矩阵：两种装载（FSRS / 挂上 RWKV-Instant 假打分器）× 三个「此刻」
// （最后一天评分刚答完——今天有复习、学习卡稍后到期、明天有到期；数据所在的那天；一年多以后——「全部」范围超过 400 天、按自然月分桶，到期全变逾期）× 两种日界（profile 的
// 4 点 + UTC+9；0 点 + UTC−5）× 四个范围 × 全部牌组与每个牌组子树。
//
// 期望值 fixtures/srs_stats_report_vectors.json.gz 由**聚合搬进内核之前的 Dart 实现**（`SrsStatsData` 的各个方法，
// 2026-11-10）算出；聚合搬进 Rust 之后，新实现必须在同一份库、同一组条件下逐值给出同样的结果。
//
// 重新生成（只在有意改变统计语义时）：SRS_STATS_REPORT_WRITE=1 跑本文件。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

const String _profile = '01928c3e-0000-7000-8000-0000000000c3';

final String _fixtures = '${Directory.current.path}/test/srs/fixtures'
    .replaceAll('\\', '/');

/// 确定性假打分器（同 srs_stats_vectors_test）：R 只取决于卡 ID 与它最后一条日志是否存在。
final class _FakeRwkv implements SrsRwkvScheduling {
  @override
  bool get ready => true;

  List<double> _scores(List<SrsRwkvCandidate> cards) => <double>[
    for (final SrsRwkvCandidate c in cards)
      ((c.id.codeUnits.fold<int>(0, (int a, int b) => a + b) +
                  (c.lastLogId == null ? 0 : 7)) %
              97) /
          100.0,
  ];

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int atMs,
  }) async => _scores(cards);

  @override
  Future<List<double>?> currentRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  }) async => _scores(cards);

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {}

  @override
  Future<void> onCardsPurged(List<String> cardIds) async {}
}

/// 「此刻」：最后一天评分刚答完（今天有复习、学习卡几分钟后到期、明天有到期）；数据所在的那天；一年多以后。
final List<int> _nows = <int>[
  DateTime.utc(2026, 10, 4, 6, 6).millisecondsSinceEpoch,
  DateTime.utc(2026, 10, 6, 9).millisecondsSinceEpoch,
  DateTime.utc(2027, 12, 15, 2, 30).millisecondsSinceEpoch,
];

/// 日界：(UTC 偏移分钟, 翻日小时)。
const List<(int, int)> _days = <(int, int)>[(540, 4), (-300, 0)];

/// 统计页「未来到期」看几天（与 srs_statistics_page.dart `_futureDays` 同一张表；「全部」= 最晚到期日）。
int _futureDaysOf(SrsStatsData d, SrsStatsRange range) => switch (range) {
  SrsStatsRange.month => 31,
  SrsStatsRange.threeMonths => 91,
  SrsStatsRange.year => 366,
  SrsStatsRange.all => d.furthestDueOffset(),
};

List<Object?> _hist(SrsHistogram h) => <Object?>[
  <Object?>[
    for (final SrsHistogramBin b in h.bins) <Object?>[b.lo, b.hi, b.count],
  ],
  h.total,
  h.mean,
  h.median,
  h.openEnded,
  h.sum,
];

/// 一个时间窗（[firstDay]..[lastDay]）的保留率与复习合计。
List<Object?> _window(SrsStatsData d, int firstDay, int lastDay) {
  final SrsRetention r = d.retentionBetween(firstDay, lastDay);
  final SrsReviewTotals t = d.reviewTotalsBetween(firstDay, lastDay);
  return <Object?>[
    r.youngCorrect,
    r.youngTotal,
    r.matureCorrect,
    r.matureTotal,
    t.count,
    t.durationMs,
    t.daysStudied,
    t.days,
  ];
}

/// 一份数据在一个范围下的全部聚合值（规范形：与实现无关，只有数）。
Map<String, Object?> _report(SrsStatsData d, SrsStatsRange range) {
  final int today = d.today;
  final int first = d.firstDayOf(range);
  final SrsTodayStats ts = d.todayStats();
  final SrsStreak streak = d.streak();
  final Map<int, int> byDay = d.countsByDay();
  final SrsFutureDue f = d.futureDue(_futureDaysOf(d, range));
  final (SrsBucketUnit futureUnit, List<SrsDayBucket> futureSpans) =
      srsStatsBuckets(today, today + f.perDay.length - 1);
  final SrsRwkvNow? now = d.rwkvNow;
  final (SrsBucketUnit unit, List<SrsReviewBucket> buckets) = d.reviewBuckets(
    range,
  );
  final List<SrsDayBucket> spans = <SrsDayBucket>[
    for (final SrsReviewBucket b in buckets) b.bucket,
  ];
  final (_, List<SrsDayBucket> addedSpans) = srsStatsBuckets(first, today);
  final SrsCardCounts cc = d.cardCounts();
  final SrsHourly hourly = d.hourly(range);
  final SrsButtons buttons = d.buttons(range);
  // 首页：卡片直接所在的牌组 → 今天的复习数（srs_home_stats.dart `srsHomeStatsOf`）。
  final Map<String, String> deckOfCard = <String, String>{
    for (final SrsStatCard c in d.cards) c.id: c.deckId,
  };
  final Map<String, int> todayByDeck = <String, int>{};
  for (final SrsStatReview r in d.reviewsBetween(today, today)) {
    final String? deck = deckOfCard[r.cardId];
    if (deck == null) continue;
    todayByDeck[deck] = (todayByDeck[deck] ?? 0) + 1;
  }
  // 桌面小组件（widget_snapshot_source.dart `_srsStatsDigest`）。
  final List<int> learningDueAts = <int>[];
  int reviewsNextDay = 0;
  for (final SrsStatCard card in d.cards) {
    if (!card.fushiScheduled || card.suspended || card.buried) continue;
    switch (card.state) {
      case SrsStatCardState.learning || SrsStatCardState.relearning:
        final int? at = card.dueAt;
        if (at != null && at > d.nowMs) learningDueAts.add(at);
      case SrsStatCardState.young || SrsStatCardState.mature:
        if (!card.byRecall && card.dueDay == today + 1) reviewsNextDay++;
      case SrsStatCardState.newCard:
        break;
    }
  }
  return <String, Object?>{
    'today': today,
    'empty': d.isEmpty,
    'earliestDay': d.earliestDay,
    'firstDay': first,
    'retrievabilityAvailable': d.retrievabilityAvailable,
    'todayStats': <Object?>[
      ts.count,
      ts.durationMs,
      ts.ratings,
      <int>[
        for (final SrsStatReviewKind k in SrsStatReviewKind.values) ts.kind(k),
      ],
      ts.early,
      ts.matureCorrect,
      ts.matureTotal,
    ],
    'streak': <int>[streak.current, streak.longest],
    'countsByDay': <Object?>[
      for (final int day in byDay.keys.toList()..sort())
        <int>[day, byDay[day]!],
    ],
    'future': <String, Object?>{
      'days': f.perDay.length,
      'overdue': f.overdue,
      'byRecall': f.byRecall,
      'load': f.dailyLoad,
      'perDay': <Object?>[
        for (int i = 0; i < f.perDay.length; i++)
          if (f.perDay[i] != 0) <int>[i, f.perDay[i], f.youngPerDay[i]],
      ],
      'unit': futureUnit.name,
      'buckets': <Object?>[
        for (final SrsDayBucket b in futureSpans)
          () {
            int all = 0, young = 0;
            for (int x = b.firstDay; x <= b.lastDay; x++) {
              all += f.perDay[x - today];
              young += f.youngPerDay[x - today];
            }
            return <int>[b.firstDay, b.lastDay, all, young];
          }(),
      ],
    },
    'furthestDue': d.furthestDueOffset(),
    'rwkvNow': now == null
        ? null
        : <Object?>[now.total, now.due, now.near, now.dailyAverage],
    'hasDueDateCards': d.hasDueDateCards,
    'reviews': <String, Object?>{
      'unit': unit.name,
      'buckets': <Object?>[
        for (final SrsReviewBucket b in buckets)
          <Object?>[
            b.bucket.firstDay,
            b.bucket.lastDay,
            <int>[
              for (final SrsStatReviewKind k in SrsStatReviewKind.values)
                b.counts[k] ?? 0,
            ],
            <int>[
              for (final SrsStatReviewKind k in SrsStatReviewKind.values)
                b.durations[k] ?? 0,
            ],
          ],
      ],
    },
    'matureAt': d.matureCountsAt(spans),
    'added': <Object?>[
      for (final SrsDayBucket b in addedSpans) <int>[b.firstDay, b.lastDay],
      d.addedCounts(addedSpans),
    ],
    'cardCounts': <int>[
      cc.newCards,
      cc.learning,
      cc.relearning,
      cc.young,
      cc.mature,
      cc.suspended,
      cc.buried,
    ],
    'hist': <String, Object?>{
      'interval': _hist(d.intervalHistogram()),
      'stability': _hist(d.stabilityHistogram()),
      'difficulty': _hist(d.difficultyHistogram()),
      'retrievability': _hist(d.retrievabilityHistogram()),
    },
    'hourly': <Object?>[hourly.counts, hourly.correct],
    'buttons': <Object?>[
      buttons.learning.ratings,
      buttons.young.ratings,
      buttons.mature.ratings,
    ],
    'windows': <String, Object?>{
      'today': _window(d, today, today),
      'yesterday': _window(d, today - 1, today - 1),
      'week': _window(d, today - 6, today),
      'fortnight': _window(d, today - 13, today),
      'month': _window(d, today - 29, today),
      'year': _window(d, today - 364, today),
      'all': _window(d, d.earliestDay, today),
      'range': _window(d, first, today),
    },
    'desiredRetention': d.desiredRetention(),
    'sources': <Object?>[
      for (final SrsSourceShare s in d.sourceShares())
        <Object?>[s.kind, s.title, s.notes],
    ],
    'todayByDeck': <String, Object?>{
      for (final String k in todayByDeck.keys.toList()..sort())
        k: todayByDeck[k],
    },
    'learningDueAts': learningDueAts..sort(),
    'reviewsNextDay': reviewsNextDay,
  };
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final bool write = Platform.environment['SRS_STATS_REPORT_WRITE'] == '1';
  final File vectors = File('$_fixtures/srs_stats_report_vectors.json.gz');
  final Map<String, Object?> produced = <String, Object?>{};
  final Map<String, Object?> expected = write
      ? const <String, Object?>{}
      : (jsonDecode(utf8.decode(gzip.decode(vectors.readAsBytesSync()))) as Map)
            .cast<String, Object?>();

  tearDownAll(() {
    if (write) {
      vectors.writeAsBytesSync(
        gzip.encode(utf8.encode('${jsonEncode(produced)}\n')),
      );
    }
  });

  Future<void> scenario(String name, {required bool rwkv}) async {
    final FsrsEngine? engine = FfiFsrsEngine.tryCreate();
    expect(engine, isNotNull, reason: 'native fushi_fsrs (FUSHI_FSRS_LIB)');
    int t = _nows.first;
    final Directory dir = Directory.systemTemp.createTempSync('srs_rep_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final String path = p.join(dir.path, 'srs.db');
    File(path).writeAsBytesSync(
      gzip.decode(File('$_fixtures/srs_stats_vectors.db.gz').readAsBytesSync()),
    );
    final TestSrs srs = await openTestSrsAt(path);
    final SrsDbStore s = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: _profile,
      deviceId: 'v',
      engine: engine,
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot-v',
      ),
      fallbackRolloverHour: () => 4,
      localOffsetMin: () => 540,
    );
    if (rwkv) s.rwkv = _FakeRwkv();
    final Map<String, Object?> out = <String, Object?>{};
    for (final int now in _nows) {
      t = now;
      for (final (int off, int roll) in _days) {
        final SrsStatsBundle b = await loadSrsStats(
          s,
          nowMs: now,
          day: SrsDayContext(utcOffsetMin: off, rolloverHour: roll),
        );
        final List<(String, String)> decks = <(String, String)>[
          ('', '*'),
          ...b.index.decks,
        ];
        for (final (String deckId, String deckName) in decks) {
          final SrsStatsData d = deckId.isEmpty
              ? b.data
              : b.data.subset(b.index.cardIdsInDeck(deckId));
          for (final SrsStatsRange range in SrsStatsRange.values) {
            out['$now|$off|$roll|$deckName|${range.name}'] = _report(d, range);
          }
        }
      }
    }
    produced[name] = out;
    if (!write) {
      final Map<String, Object?> want = (expected[name]! as Map)
          .cast<String, Object?>();
      final Map<String, Object?> got = (jsonDecode(jsonEncode(out)) as Map)
          .cast<String, Object?>();
      expect(got.keys.toSet(), want.keys.toSet(), reason: name);
      for (final String k in want.keys) {
        expect(got[k], want[k], reason: '$name $k');
      }
    }
  }

  test('FSRS 牌组', () => scenario('fsrs', rwkv: false));
  test('RWKV-Instant 打分器在', () => scenario('rwkv', rwkv: true));
}
