/// `fushi_server stats show`：离线读学习统计（唯一事实面 `loadStatFacts`）。
///
/// 口径与 app 统计中心一致（docs/agent/statistics.md）：
/// - 只读 `StatFacts.daily`（日面），**不**把小时面并进来求和（两面共享同一批
///   `StatFact` 实例，混加即双计）；
/// - 会话只取 `StatFacts.sessions`（`deriveStudySessions` 派生视图）；
/// - 只看当前激活 Profile（`loadStatFacts` 的 `profileId: null`）；
/// - 「今日」边界 = 偏好 `stats_day_reset_hour`，窗口按 dateKey 做 key 算术
///   （近 N 天 = 含今日恰 N 个统计日，与 app `StatWindow` 同一套算术）。
///
/// app 的窗口定义 `StatWindow` 住在 `fushi/lib/src/stats/stat_window.dart`（Flutter
/// 包内，无头服务端 import 不到），这里用同一组 `FushiDatabase.statDateKey*` 原语
/// 复刻「含今日恰 N 天」的判据，见 [statShowWindowFromKey]。后续该类挪进引擎后应
/// 改为直接复用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/server_runtime.dart';

const int _exitOk = 0;
const int _exitUsage = 64;

/// 统计窗口：含今日在内的恰 [days] 个统计日；[days] 为 null = 全部历史。
enum StatShowWindow {
  today('today', 1),
  week('7d', 7),
  month('30d', 30),
  all('all', null);

  const StatShowWindow(this.arg, this.days);

  final String arg;
  final int? days;

  static StatShowWindow? parse(String raw) {
    for (final StatShowWindow w in values) {
      if (w.arg == raw) return w;
    }
    return null;
  }
}

/// `--kind` 的取值 → 事实表 `media_kind`。
///
/// 有声书收听在写入面就记成 `book`（`audiobook_session.dart` 的 StudyClock），
/// 事实表里与阅读不可区分，所以没有 `listen` 档——硬给一个只会是阅读的别名。
enum StatShowKind {
  read('read', kActivityMediaBook),
  watch('watch', kActivityMediaVideo),
  play('play', kActivityMediaGame);

  const StatShowKind(this.arg, this.mediaKind);

  final String arg;
  final String mediaKind;

  static StatShowKind? parse(String raw) {
    for (final StatShowKind k in values) {
      if (k.arg == raw) return k;
    }
    return null;
  }
}

/// 窗口起点 dateKey（含）；全部历史返回 null。与 app `StatWindow` 同一判据：
/// `statDateKeyPlusDays(statDateKeyOf(now), -(n - 1))`。
String? statShowWindowFromKey(DateTime now, StatShowWindow window) {
  final int? days = window.days;
  if (days == null) return null;
  return FushiDatabase.statDateKeyPlusDays(FushiDatabase.statDateKeyOf(now), -(days - 1));
}

/// 从偏好表镜像统计日界（app 由 `AppModel._applyStatDayResetHour` 做同一件事）。
void applyStatDayResetHourFromPrefs(PrefStore prefs) {
  final Object? raw = prefs.getPref(kStatDayResetHourPrefKey, defaultValue: 0);
  FushiDatabase.statDayResetHour = raw is int ? raw : 0;
}

class _Bucket {
  int ms = 0;
  int chars = 0;
  int pages = 0;

  void add(int ms, int chars, int pages) {
    this.ms += ms;
    this.chars += chars;
    this.pages += pages;
  }

  Map<String, Object?> toJson() => <String, Object?>{'ms': ms, 'chars': chars, 'pages': pages};
}

class _MediaBucket extends _Bucket {
  _MediaBucket({required this.kind, required this.key, required this.title, required this.format});

  final String kind;
  final String key;
  String title;
  final String format;
  int lastActiveAt = 0;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'key': key,
    'title': title,
    'format': format,
    ...super.toJson(),
    'lastActiveAt': lastActiveAt,
  };
}

/// 纯函数：把事实面按窗口 / 种类聚合成 `stats show` 的报告（`--json` 即原样输出）。
Map<String, Object?> buildStatShowReport(
  StatFacts facts, {
  required DateTime now,
  required StatShowWindow window,
  StatShowKind? kind,
  int sessionLimit = 10,
  int mediaLimit = 20,
}) {
  final String todayKey = FushiDatabase.statDateKeyOf(now);
  final String? fromKey = statShowWindowFromKey(now, window);
  bool inWindow(String dateKey) =>
      (fromKey == null || dateKey.compareTo(fromKey) >= 0) && dateKey.compareTo(todayKey) <= 0;
  bool kindMatches(String mediaKind) => kind == null || kind.mediaKind == mediaKind;

  final _Bucket total = _Bucket();
  final Map<String, _Bucket> byKind = <String, _Bucket>{};
  final Map<String, _Bucket> byDay = <String, _Bucket>{};
  final Map<String, _MediaBucket> byMedia = <String, _MediaBucket>{};
  for (final StatFact f in facts.daily) {
    if (!kindMatches(f.mediaKind) || !inWindow(f.dateKey)) continue;
    total.add(f.ms, f.chars, f.pages);
    byKind.putIfAbsent(f.mediaKind, _Bucket.new).add(f.ms, f.chars, f.pages);
    byDay.putIfAbsent(f.dateKey, _Bucket.new).add(f.ms, f.chars, f.pages);
    final _MediaBucket m = byMedia.putIfAbsent(
      '${f.mediaKind}\u0000${f.identityKey}',
      () => _MediaBucket(kind: f.mediaKind, key: f.mediaKey, title: f.title, format: f.format),
    );
    m.add(f.ms, f.chars, f.pages);
    if (f.lastActiveMs >= m.lastActiveAt) {
      m.lastActiveAt = f.lastActiveMs;
      // 展示快照取最近一条（书改名后跟最新）。
      if (f.title.isNotEmpty) m.title = f.title;
    }
  }

  final List<String> days = byDay.keys.toList()..sort();
  final List<_MediaBucket> media = byMedia.values.toList()
    ..sort((_MediaBucket a, _MediaBucket b) {
      final int byMs = b.ms.compareTo(a.ms);
      return byMs != 0 ? byMs : b.chars.compareTo(a.chars);
    });
  final List<StudySession> sessions = facts.sessions
      .where(
        (StudySession s) =>
            kindMatches(s.mediaKind) &&
            inWindow(FushiDatabase.statDateKeyOf(DateTime.fromMillisecondsSinceEpoch(s.startAt))),
      )
      .toList();

  return <String, Object?>{
    'window': window.arg,
    'from': fromKey,
    'to': todayKey,
    'kind': kind?.arg ?? 'all',
    'dayResetHour': FushiDatabase.statDayResetHour,
    'totals': <String, Object?>{...total.toJson(), 'activeDays': days.length, 'sessions': sessions.length},
    'byKind': <String, Object?>{for (final String k in byKind.keys.toList()..sort()) k: byKind[k]!.toJson()},
    'byDay': <Object?>[
      for (final String d in days) <String, Object?>{'date': d, ...byDay[d]!.toJson()},
    ],
    'media': <Object?>[for (final _MediaBucket m in media.take(mediaLimit)) m.toJson()],
    'sessions': <Object?>[
      for (final StudySession s in sessions.take(sessionLimit))
        <String, Object?>{
          'kind': s.mediaKind,
          'key': s.mediaKey,
          'title': s.title,
          'format': s.format,
          'deviceId': s.deviceId,
          'startAt': s.startAt,
          'endAt': s.endAt,
          'ms': s.durationMs,
          'chars': s.chars,
          'pages': s.pages,
        },
    ],
  };
}

String _duration(int ms) {
  final int minutes = ms ~/ 60000;
  return minutes >= 60 ? '${minutes ~/ 60}h${(minutes % 60).toString().padLeft(2, '0')}m' : '${minutes}m';
}

/// 人读渲染。
void renderStatShowReport(Map<String, Object?> report, StringSink out) {
  final Map<String, Object?> totals = report['totals']! as Map<String, Object?>;
  final Object? from = report['from'];
  out.writeln('窗口: ${report['window']}（${from ?? '最早'} ~ ${report['to']}）  种类: ${report['kind']}');
  out.writeln(
    '合计: ${_duration(totals['ms']! as int)}  ${totals['chars']} 字  ${totals['pages']} 页  '
    '活跃 ${totals['activeDays']} 天  会话 ${totals['sessions']} 次',
  );
  final Map<String, Object?> byKind = report['byKind']! as Map<String, Object?>;
  for (final MapEntry<String, Object?> e in byKind.entries) {
    final Map<String, Object?> b = e.value! as Map<String, Object?>;
    out.writeln('  ${e.key.padRight(6)} ${_duration(b['ms']! as int)}  ${b['chars']} 字  ${b['pages']} 页');
  }
  final List<Object?> media = report['media']! as List<Object?>;
  if (media.isNotEmpty) {
    out.writeln('按媒体:');
    for (final Object? row in media) {
      final Map<String, Object?> m = row! as Map<String, Object?>;
      final String title = (m['title']! as String).isEmpty ? m['key']! as String : m['title']! as String;
      out.writeln('  [${m['kind']}] $title  ${_duration(m['ms']! as int)}  ${m['chars']} 字');
    }
  }
  final List<Object?> sessions = report['sessions']! as List<Object?>;
  if (sessions.isNotEmpty) {
    out.writeln('最近会话:');
    for (final Object? row in sessions) {
      final Map<String, Object?> s = row! as Map<String, Object?>;
      final String at = DateTime.fromMillisecondsSinceEpoch(s['startAt']! as int).toIso8601String();
      final String title = (s['title']! as String).isEmpty ? s['key']! as String : s['title']! as String;
      out.writeln('  $at [${s['kind']}] $title  ${_duration(s['ms']! as int)}  ${s['chars']} 字');
    }
  }
}

class StatsModule extends CliModule {
  const StatsModule({this.out, this.err, this.clock});

  /// 测试注入点：缺省 stdout / stderr / 系统时钟。
  final StringSink? out;
  final StringSink? err;
  final DateTime Function()? clock;

  @override
  List<String> get commands => const <String>['stats'];

  @override
  void register(ArgParser parser) {
    parser.addCommand('stats').addCommand('show')
      ..addOption('window', abbr: 'w', help: '统计窗口：today | 7d | 30d | all', defaultsTo: '7d')
      ..addOption('kind', abbr: 'k', help: '只看某一域：read（书 / 漫画 / PDF / 有声书）| watch | play')
      ..addOption('sessions', help: '最多列出几次会话', defaultsTo: '10')
      ..addOption('media', help: '按媒体最多列出几条', defaultsTo: '20')
      ..addFlag('json', negatable: false, help: '输出 JSON');
  }

  @override
  String get usage => '''
stats show [--window today|7d|30d|all] [--kind read|watch|play] [--json]
    离线读学习统计（当前 Profile，口径同 app 统计中心）。有声书收听在事实表里与阅读
    同记为 book，归入 --kind read，没有单独的 listen 档。''';

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final StringSink o = out ?? stdout;
    final StringSink e = err ?? stderr;
    final ArgResults? sub = command.command;
    if (sub == null || sub.name != 'show') {
      e.writeln('用法: stats show [--window 7d] [--kind read|watch|play] [--json]');
      return _exitUsage;
    }
    final StatShowWindow? window = StatShowWindow.parse(sub['window'] as String);
    if (window == null) {
      e.writeln('--window 只接受 today / 7d / 30d / all');
      return _exitUsage;
    }
    StatShowKind? kind;
    final String? rawKind = sub['kind'] as String?;
    if (rawKind != null) {
      if (rawKind == 'listen') {
        e.writeln('有声书收听在统计事实表里记为 book，与阅读不可区分；用 --kind read');
        return _exitUsage;
      }
      kind = StatShowKind.parse(rawKind);
      if (kind == null) {
        e.writeln('--kind 只接受 read / watch / play');
        return _exitUsage;
      }
    }
    final int? sessionLimit = int.tryParse(sub['sessions'] as String);
    final int? mediaLimit = int.tryParse(sub['media'] as String);
    if (sessionLimit == null || sessionLimit < 0 || mediaLimit == null || mediaLimit < 0) {
      e.writeln('--sessions / --media 需要非负整数');
      return _exitUsage;
    }
    final bool json = sub['json'] as bool;
    return ctx.withRuntime((ServerRuntime rt) async {
      applyStatDayResetHourFromPrefs(rt.prefs);
      final StatFacts facts = await loadStatFacts(rt.db, activityLimit: 0);
      final Map<String, Object?> report = buildStatShowReport(
        facts,
        now: (clock ?? DateTime.now)(),
        window: window,
        kind: kind,
        sessionLimit: sessionLimit,
        mediaLimit: mediaLimit,
      );
      if (json) {
        o.writeln(const JsonEncoder.withIndent('  ').convert(report));
      } else {
        renderStatShowReport(report, o);
      }
      return _exitOk;
    });
  }
}
