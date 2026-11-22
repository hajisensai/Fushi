import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

/// 学习统计事实面的派生：原始行打包 → Rust（`ffc_stats_derive`，
/// `native/fushi_compute/src/stats.rs`）→ 快照解成 [StatFact] / [StudySession]。
///
/// BUG-4960：日面 / 小时面的构造、会话归并、按日合计原先是 Dart，在 UI isolate 上跑；
/// 现在派生只有 Rust 这一份（没有 Dart 回退），本文件只做格式搬运，且只在
/// [loadStatFacts] 的后台 isolate 里被调用（[deriveStudySessions] 是给编辑预览 / 测试的
/// 小输入入口）。打包顺序必须与 `stats.rs` 文件头的表顺序逐字段一致。

/// 一个统计日的合计（总览的范围图 / 所选范围卡 / 学习日历 / 阅读速度）。
final class StatDayTotal {
  const StatDayTotal({
    required this.dateKey,
    required this.chars,
    required this.ms,
  });

  final String dateKey;
  final int chars;
  final int ms;
}

/// SRS 复习时长的 (统计日, 本地小时) 格子（srs.db 的 `review_grid` 读出的四列；
/// [day] 是自 1970-01-01 的天数，Rust 侧转成统计日 key）。
final class StatReviewGrid {
  StatReviewGrid({
    required this.day,
    required this.hour,
    required this.ms,
    required this.last,
  }) : assert(
         day.length == hour.length &&
             hour.length == ms.length &&
             ms.length == last.length,
       );

  static final StatReviewGrid empty = StatReviewGrid(
    day: Int64List(0),
    hour: Int64List(0),
    ms: Int64List(0),
    last: Int64List(0),
  );

  final Int64List day;
  final Int64List hour;
  final Int64List ms;
  final Int64List last;

  int get length => day.length;
}

/// 一次派生的全部产物。
final class StatDerived {
  const StatDerived({
    required this.daily,
    required this.hourly,
    required this.sessions,
    required this.dayTotals,
    required this.bookDayTotals,
  });

  final List<StatFact> daily;
  final List<StatFact> hourly;
  final List<StudySession> sessions;
  final List<StatDayTotal> dayTotals;
  final List<StatDayTotal> bookDayTotals;
}

/// 输入格式版本（`stats.rs` 的 `INPUT_VERSION`）。
const int _kInputVersion = 1;

/// 整份派生（见 `stats.rs` 文件头）。大库上是几十毫秒的同步调用，只在后台 isolate 调。
StatDerived deriveStatFacts({
  List<EpubBookMeta> epubs = const <EpubBookMeta>[],
  List<ReadingStatisticRow> reading = const <ReadingStatisticRow>[],
  List<VideoWatchStatisticRow> watch = const <VideoWatchStatisticRow>[],
  List<ReadingHourlyLogRow> readingHourly = const <ReadingHourlyLogRow>[],
  List<VideoHourlyLogRow> videoHourly = const <VideoHourlyLogRow>[],
  Map<String, String> gameTitles = const <String, String>{},
  List<(String, String, int)> gameDaily = const <(String, String, int)>[],
  List<ActivityEventRow> gameActivity = const <ActivityEventRow>[],
  List<StudySegmentRow> segments = const <StudySegmentRow>[],
  StatReviewGrid? reviews,
  List<GalgameSessionRow> gameSessions = const <GalgameSessionRow>[],
  Map<String, String> gameNames = const <String, String>{},
  Duration gap = kStudySessionGap,
}) {
  final FfcStatInput p = FfcStatInput()
    ..int64(_kInputVersion)
    ..int64(gap.inMilliseconds);
  p.int64(epubs.length);
  for (final EpubBookMeta e in epubs) {
    p
      ..string(e.title)
      ..string(e.bookKey)
      ..string(e.format);
  }
  p.int64(reading.length);
  for (final ReadingStatisticRow r in reading) {
    p
      ..string(r.title)
      ..string(r.dateKey)
      ..int64(r.readingTimeMs)
      ..int64(r.charactersRead)
      ..int64(r.pagesRead)
      ..int64(r.lastStatisticModified);
  }
  p.int64(watch.length);
  for (final VideoWatchStatisticRow w in watch) {
    p
      ..string(w.bookUid ?? '')
      ..string(w.title)
      ..string(w.dateKey)
      ..int64(w.watchTimeMs)
      ..int64(w.subtitleChars)
      ..int64(w.lastModified);
  }
  p.int64(readingHourly.length);
  for (final ReadingHourlyLogRow h in readingHourly) {
    p
      ..string(h.format)
      ..string(h.dateKey)
      ..int64(h.hour)
      ..int64(h.readingTimeMs);
  }
  p.int64(videoHourly.length);
  for (final VideoHourlyLogRow h in videoHourly) {
    p
      ..string(h.dateKey)
      ..int64(h.hour)
      ..int64(h.watchTimeMs);
  }
  p.int64(gameTitles.length);
  gameTitles.forEach((String id, String title) {
    p
      ..string(id)
      ..string(title);
  });
  p.int64(gameDaily.length);
  for (final (String id, String dateKey, int seconds) in gameDaily) {
    p
      ..string(id)
      ..string(dateKey)
      ..int64(seconds);
  }
  p.int64(gameActivity.length);
  for (final ActivityEventRow e in gameActivity) {
    p
      ..string(e.mediaKey ?? '')
      ..string(e.title)
      ..string(e.dateKey)
      ..int64(e.charsDelta ?? 0)
      ..int64(e.timestampMs);
  }
  p.int64(segments.length);
  for (final StudySegmentRow s in segments) {
    p
      ..string(s.uid)
      ..string(s.deviceId)
      ..string(s.mediaKind)
      ..string(s.mediaKey)
      ..string(s.title)
      ..string(s.format)
      ..string(s.dateKey)
      ..int64(s.startAt)
      ..int64(s.endAt)
      ..int64(s.hour)
      ..int64(s.durationMs)
      ..int64(s.chars)
      ..int64(s.pages);
  }
  final StatReviewGrid grid = reviews ?? StatReviewGrid.empty;
  p.int64(grid.length);
  for (int i = 0; i < grid.length; i++) {
    p
      ..int64(grid.day[i])
      ..int64(grid.hour[i])
      ..int64(grid.ms[i])
      ..int64(grid.last[i]);
  }
  p.int64(gameSessions.length);
  for (final GalgameSessionRow g in gameSessions) {
    p
      ..string(g.gameId)
      ..int64(g.id)
      ..int64(g.startMs)
      ..int64(g.endMs)
      ..int64(g.durationSeconds);
  }
  p.int64(gameNames.length);
  gameNames.forEach((String id, String name) {
    p
      ..string(id)
      ..string(name);
  });
  return _decode(FushiComputeStats.instance.derive(p));
}

StatDerived _decode(FfcStatSnapshot snap) {
  final Int64List v = snap.ints;
  final List<String> s = snap.strings;
  int i = 0;
  StatFact fact() {
    final StatFact f = StatFact(
      mediaKind: s[v[i]],
      mediaKey: s[v[i + 1]],
      title: s[v[i + 2]],
      format: s[v[i + 3]],
      dateKey: s[v[i + 4]],
      hour: v[i + 5],
      ms: v[i + 6],
      chars: v[i + 7],
      pages: v[i + 8],
      lastActiveMs: v[i + 9],
    );
    i += 10;
    return f;
  }

  List<StatDayTotal> totals() {
    final int n = v[i++];
    return List<StatDayTotal>.generate(n, (_) {
      final StatDayTotal t = StatDayTotal(
        dateKey: s[v[i]],
        chars: v[i + 1],
        ms: v[i + 2],
      );
      i += 3;
      return t;
    }, growable: false);
  }

  final int nDaily = v[i++];
  final List<StatFact> daily = List<StatFact>.generate(
    nDaily,
    (_) => fact(),
    growable: false,
  );
  final int nHourly = v[i++];
  final List<StatFact> hourly = List<StatFact>.generate(nHourly, (_) {
    final int shared = v[i++];
    // ≥0：与日面那一行是同一条事实（段 / 复习两面各一份，同一个对象）。
    return shared >= 0 ? daily[shared] : fact();
  }, growable: false);
  final int nSessions = v[i++];
  final List<StudySession> sessions = List<StudySession>.generate(nSessions, (
    _,
  ) {
    final String kind = s[v[i]];
    final String key = s[v[i + 1]];
    final String title = s[v[i + 2]];
    final String format = s[v[i + 3]];
    final String deviceId = s[v[i + 4]];
    final int startAt = v[i + 5];
    final int endAt = v[i + 6];
    final int durationMs = v[i + 7];
    final int chars = v[i + 8];
    final int pages = v[i + 9];
    i += 10;
    final int? gameSessionId = v[i++] >= 0 ? v[i++] : null;
    final int nUids = v[i++];
    final List<String> uids = List<String>.generate(
      nUids,
      (int k) => s[v[i + k]],
      growable: false,
    );
    i += nUids;
    return StudySession(
      mediaKind: kind,
      mediaKey: key,
      title: title,
      format: format,
      deviceId: deviceId,
      startAt: startAt,
      endAt: endAt,
      durationMs: durationMs,
      chars: chars,
      pages: pages,
      segmentUids: uids,
      gameSessionId: gameSessionId,
    );
  }, growable: false);
  final List<StatDayTotal> dayTotals = totals();
  final List<StatDayTotal> bookDayTotals = totals();
  if (i != v.length) {
    throw StateError('ffc_stats_derive: trailing snapshot data');
  }
  return StatDerived(
    daily: daily,
    hourly: hourly,
    sessions: sessions,
    dayTotals: dayTotals,
    bookDayTotals: bookDayTotals,
  );
}
