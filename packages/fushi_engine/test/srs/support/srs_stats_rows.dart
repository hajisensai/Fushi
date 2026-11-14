// 测试用：读内核 `stats_rows`（统计原料归一化之后的逐卡 / 逐条视图），换成带类型的行。
//
// 统计聚合在内核（native/fushi_fsrs/src/store/stats.rs）；这些行只给测试核对归一化本身（状态、搁置、
// 有效复习的日 / 小时 / 种类、成熟事件、出处分组）。
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 一条有效复习（归属到的卡、时刻、SRS 日、本地小时、评分、种类、用时、是否提前）。
final class StatReviewRow {
  const StatReviewRow({
    required this.cardId,
    required this.at,
    required this.day,
    required this.hour,
    required this.rating,
    required this.kind,
    required this.durationMs,
    required this.early,
  });

  factory StatReviewRow.fromJson(List<Object?> r) => StatReviewRow(
    cardId: r[0]! as String,
    at: r[1]! as int,
    day: r[2]! as int,
    hour: r[3]! as int,
    rating: r[4]! as int,
    kind: SrsStatReviewKind.values[r[5]! as int],
    durationMs: r[6]! as int,
    early: r[7]! as bool,
  );

  final String cardId;
  final int at;
  final int day;
  final int hour;
  final int rating;
  final SrsStatReviewKind kind;
  final int durationMs;
  final bool early;
}

/// 一次成熟 / 退出成熟（卡、SRS 日、+1 / -1）。
final class StatMaturityRow {
  const StatMaturityRow(this.cardId, this.day, this.delta);

  final String cardId;
  final int day;
  final int delta;
}

/// 一张可见卡的统计视图（与 `stats_rows` 的列同序）。
final class StatCardRow {
  const StatCardRow(this.raw);

  /// `[id, note, deck, state, suspended, buried, fushi, days, dueDay, dueAt, stability, difficulty, r,
  /// lapses, reps, addedDay, desired, byRecall]`。
  final List<Object?> raw;

  String get id => raw[0]! as String;
  String get noteId => raw[1]! as String;
  String get deckId => raw[2]! as String;
  String get state => raw[3]! as String;
  bool get suspended => raw[4]! as bool;
  bool get buried => raw[5]! as bool;
  int get intervalDays => raw[7]! as int;
  double? get retrievability => (raw[12] as num?)?.toDouble();
  bool get byRecall => raw[17]! as bool;
}

/// `stats_rows` 的全部内容。
final class StatsRows {
  StatsRows(Map<String, Object?> j)
    : today = j['today']! as int,
      cards = <StatCardRow>[
        for (final Object? c in j['cards']! as List<Object?>)
          StatCardRow(c! as List<Object?>),
      ],
      reviews = <StatReviewRow>[
        for (final Object? r in j['reviews']! as List<Object?>)
          StatReviewRow.fromJson(r! as List<Object?>),
      ],
      maturity = <StatMaturityRow>[
        for (final Object? m in j['maturity']! as List<Object?>)
          StatMaturityRow(
            (m as List<Object?>)[0]! as String,
            m[1]! as int,
            m[2]! as int,
          ),
      ],
      sources = <SrsSourceShare>[
        for (final Object? s in j['sources']! as List<Object?>)
          SrsSourceShare(
            kind: (s as List<Object?>)[0]! as String,
            title: s[1]! as String,
            notes: s[2]! as int,
          ),
      ],
      retrievabilityAvailable = j['retrievabilityAvailable']! as bool;

  final int today;
  final List<StatCardRow> cards;
  final List<StatReviewRow> reviews;
  final List<StatMaturityRow> maturity;
  final List<SrsSourceShare> sources;
  final bool retrievabilityAvailable;
}

/// 按 [loadSrsStats] 的口径读一次 `stats_rows`。
Future<StatsRows> statsRowsOf(
  SrsDbStore store, {
  SrsDayContext? day,
  int? nowMs,
}) async {
  final SrsStatsLoad load = await loadSrsStats(store, day: day, nowMs: nowMs);
  return StatsRows(await load.rows());
}
