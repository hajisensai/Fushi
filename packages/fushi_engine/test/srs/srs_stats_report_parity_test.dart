// 复习统计「聚合结果」的对拍向量：统计页 / 首页 / 桌面小组件 / 操作目录读到的每一项聚合值。
//
// 输入是 srs_stats_vectors_test 的冻结库（fixtures/srs_stats_vectors.db.gz），可提取度用真排程内核
// （[FfiFsrsEngine]，与生产同一个函数）。条件矩阵：两种装载（FSRS / 挂上 RWKV-Instant 假打分器）× 三个「此刻」
// （最后一天评分刚答完——今天有复习、学习卡稍后到期、明天有到期；数据所在的那天；一年多以后——「全部」范围超过 400 天、按自然月分桶，到期全变逾期）× 两种日界（profile 的
// 4 点 + UTC+9；0 点 + UTC−5）× 四个范围 × 全部牌组与每个牌组子树。
//
// 期望值 fixtures/srs_stats_report_vectors.json.gz 由**聚合搬进内核之前的 Dart 实现**（`SrsStatsData` 的各个方法，
// 2026-11-10；生成它的测试版本见引入夹具的提交）算出；现在由内核 `stats_report`（store/stats.rs）给出，必须在同一份
// 库、同一组条件下逐值相同。
//
// 重新生成（只在有意改变统计语义时）：SRS_STATS_REPORT_WRITE=1 跑本文件（之后的期望值就是内核的结果）。
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

/// 每次请求的时间窗（统计页的保留率表 + 首页的两周；范围窗由 [SrsStatsLoad.report] 恒带）。
const Map<String, SrsStatsWindow> _windows = <String, SrsStatsWindow>{
  'today': SrsStatsWindow(0, 0),
  'yesterday': SrsStatsWindow(1, 1),
  'week': SrsStatsWindow.last(7),
  'fortnight': SrsStatsWindow.last(14),
  'month': SrsStatsWindow.last(30),
  'year': SrsStatsWindow.last(365),
  'all': SrsStatsWindow.all(),
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

/// 一个时间窗的保留率与复习合计。
List<Object?> _window(SrsStatsWindowResult w) => <Object?>[
  w.retention.youngCorrect,
  w.retention.youngTotal,
  w.retention.matureCorrect,
  w.retention.matureTotal,
  w.totals.count,
  w.totals.durationMs,
  w.totals.daysStudied,
  w.totals.days,
];

/// 内核的一份聚合结果写成规范形（与实现无关，只有数；与冻结向量同一结构）。
Map<String, Object?> _report(SrsStatsReport d) {
  final SrsTodayStats ts = d.todayStats;
  final SrsFutureDue f = d.future;
  final SrsRwkvNow? now = d.rwkvNow;
  final List<SrsDayBucket> spans = <SrsDayBucket>[
    for (final SrsReviewBucket b in d.reviewBuckets) b.bucket,
  ];
  return <String, Object?>{
    'today': d.today,
    'empty': d.isEmpty,
    'earliestDay': d.earliestDay,
    'firstDay': d.firstDay,
    'retrievabilityAvailable': d.retrievabilityAvailable,
    'todayStats': <Object?>[
      ts.count,
      ts.durationMs,
      ts.ratings,
      <int>[
        for (final SrsStatReviewKind k in SrsStatReviewKind.values)
          ts.byKind[k] ?? 0,
      ],
      ts.early,
      ts.matureCorrect,
      ts.matureTotal,
    ],
    'streak': <int>[d.streak.current, d.streak.longest],
    'countsByDay': <Object?>[
      for (final int day in d.countsByDay.keys.toList()..sort())
        <int>[day, d.countsByDay[day]!],
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
      'unit': f.unit.name,
      'buckets': <Object?>[
        for (final SrsFutureBucket b in f.buckets)
          <int>[b.bucket.firstDay, b.bucket.lastDay, b.all, b.young],
      ],
    },
    'furthestDue': d.furthestDueOffset,
    'rwkvNow': now == null
        ? null
        : <Object?>[now.total, now.due, now.near, now.dailyAverage],
    'hasDueDateCards': d.hasDueDateCards,
    'reviews': <String, Object?>{
      'unit': d.reviewUnit.name,
      'buckets': <Object?>[
        for (final SrsReviewBucket b in d.reviewBuckets)
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
    'matureAt': d.matureCounts,
    'added': <Object?>[
      for (final SrsDayBucket b in spans) <int>[b.firstDay, b.lastDay],
      d.addedCounts,
    ],
    'cardCounts': <int>[
      d.cardCounts.newCards,
      d.cardCounts.learning,
      d.cardCounts.relearning,
      d.cardCounts.young,
      d.cardCounts.mature,
      d.cardCounts.suspended,
      d.cardCounts.buried,
    ],
    'hist': <String, Object?>{
      'interval': _hist(d.intervalHistogram),
      'stability': _hist(d.stabilityHistogram),
      'difficulty': _hist(d.difficultyHistogram),
      'retrievability': _hist(d.retrievabilityHistogram),
    },
    'hourly': <Object?>[d.hourly.counts, d.hourly.correct],
    'buttons': <Object?>[
      d.buttons.learning.ratings,
      d.buttons.young.ratings,
      d.buttons.mature.ratings,
    ],
    'windows': <String, Object?>{
      for (final String k in <String>[..._windows.keys, kSrsStatsRangeWindow])
        k: _window(d.windows[k]!),
    },
    'desiredRetention': d.desiredRetention,
    'sources': <Object?>[
      for (final SrsSourceShare s in d.sources)
        <Object?>[s.kind, s.title, s.notes],
    ],
    'todayByDeck': <String, Object?>{
      for (final String k in d.todayByDeck.keys.toList()..sort())
        k: d.todayByDeck[k],
    },
    'learningDueAts': List<int>.of(d.learningDueAts)..sort(),
    'reviewsNextDay': d.reviewsNextDay,
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
        final SrsStatsLoad b = await loadSrsStats(
          s,
          nowMs: now,
          day: SrsDayContext(utcOffsetMin: off, rolloverHour: roll),
        );
        final List<(String, String)> decks = <(String, String)>[
          ('', '*'),
          ...b.decks,
        ];
        for (final (String deckId, String deckName) in decks) {
          for (final SrsStatsRange range in SrsStatsRange.values) {
            out['$now|$off|$roll|$deckName|${range.name}'] = _report(
              await b.report(
                range: range,
                decks: deckId.isEmpty ? null : b.subtree(deckId),
                windows: _windows,
              ),
            );
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
