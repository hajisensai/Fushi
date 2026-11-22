import 'package:drift/drift.dart' show Batch, InsertMode, Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

/// BUG-4960 对拍：统计事实面迁到 Rust（`ffc_stats_derive`）前后，同一份库读出的
/// 日面 / 小时面 / 会话流 / 按日合计 / 活动流必须逐条相同。
///
/// [seedStatParityDb] 往库里写一份确定性的「大杂烩」：legacy 四表（唯一同名反查、同名
/// 歧义、已删的书、无 uid 的视频行）、legacy 游戏活动行（零字数 / null 字数 / 库事件）、
/// 游玩会话骨架（含已移除游戏的快照名）、几百条段（多设备、多身份、gap 边界两侧、写零段、
/// 起止时刻并列、骨架窗口前后的游戏字数段、UTF-16 排序敏感的身份）。数据只由固定种子的
/// 线性同余序列决定，[kStatParityFixture] 是迁移前的 Dart 实现在这份库上的输出。
const String kStatParityFixture = 'test/stats/fixtures/stat_facts_parity.json';

/// 固定种子的线性同余序列（与平台 / Random 实现无关）。
final class _Lcg {
  _Lcg(this._state);
  int _state;

  int next(int bound) {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state % bound;
  }

  T pick<T>(List<T> items) => items[next(items.length)];
}

const int _day = 86400000;
const int _base = 1767225600000; // 2026-01-01T00:00:00Z

Future<void> seedStatParityDb(FushiDatabase db) async {
  final _Lcg r = _Lcg(4960);
  final int profile = await db.resolveActiveProfileId();
  final List<(String, String, String)> books = <(String, String, String)>[
    ('bk1', '唯一の本', 'epub'),
    ('bk2', '双子', 'pdf'),
    ('bk3', '双子', 'manga'),
    ('bk4', 'Book Four', 'epub'),
    ('bk5', '漫画本', 'manga'),
    ('bk6', '\u{1F600}絵文字', 'epub'),
  ];
  for (final (String key, String title, String format) in books) {
    await db
        .into(db.epubBooks)
        .insert(
          EpubBooksCompanion.insert(
            bookKey: key,
            title: title,
            epubPath: '$key.epub',
            extractDir: key,
            chapterCount: 1,
            chaptersJson: '[]',
            importedAt: r.next(1000),
            format: Value(format),
          ),
        );
  }
  String dateKey(int dayIndex) => FushiDatabase.statCalendarDayKeyOf(
    DateTime.utc(2026).add(Duration(days: dayIndex)),
  );

  // legacy 阅读日行（title, dateKey 唯一）。
  final List<String> readTitles = <String>[
    '唯一の本',
    '双子',
    'Book Four',
    '已删的书',
    '',
    '\u{1F600}絵文字',
  ];
  for (final String title in readTitles) {
    for (int d = 0; d < 12; d++) {
      if (r.next(3) == 0) continue;
      await db
          .into(db.readingStatistics)
          .insert(
            ReadingStatisticsCompanion.insert(
              title: title,
              dateKey: dateKey(d * 3 + r.next(3)),
              charactersRead: r.next(5000),
              readingTimeMs: r.next(3600000),
              pagesRead: Value(r.next(40)),
              lastStatisticModified: _base + r.next(1000000),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }
  // legacy 观看日行：有 uid / NULL uid / 空串 uid。
  final List<(String, String?)> videos = <(String, String?)>[
    ('番剧', 'v1'),
    ('番剧', null),
    ('番剧', ''),
    ('別の番組', 'v2'),
  ];
  for (final (String title, String? uid) in videos) {
    for (int d = 0; d < 10; d++) {
      if (r.next(2) == 0) continue;
      await db
          .into(db.videoWatchStatistics)
          .insert(
            VideoWatchStatisticsCompanion.insert(
              title: title,
              bookUid: Value(uid),
              dateKey: dateKey(d * 2),
              subtitleChars: r.next(3000),
              watchTimeMs: r.next(5400000),
              lastModified: _base + r.next(1000000),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }
  // legacy 小时行。
  for (int i = 0; i < 40; i++) {
    await db
        .into(db.readingHourlyLogs)
        .insert(
          ReadingHourlyLogsCompanion.insert(
            dateKey: dateKey(r.next(30)),
            hour: r.next(24),
            readingTimeMs: r.next(3600000),
            format: Value(r.pick(<String>['epub', 'pdf', 'manga', ''])),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await db
        .into(db.videoHourlyLogs)
        .insert(
          VideoHourlyLogsCompanion.insert(
            dateKey: dateKey(r.next(30)),
            hour: r.next(24),
            watchTimeMs: r.next(3600000),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }
  // 游戏库：g1 / g2 在库，g9 已移除（只剩会话快照名）。
  for (final (String id, String name) in <(String, String)>[
    ('g1', 'ゲーム一'),
    ('g2', 'Game Two'),
  ]) {
    await db
        .into(db.galgames)
        .insert(
          GalgamesCompanion.insert(
            id: id,
            name: name,
            exePath: '$id.exe',
            workdir: id,
            addedAt: 0,
          ),
        );
  }
  final List<(int, int, String)> gameWindows = <(int, int, String)>[];
  for (int i = 0; i < 24; i++) {
    final String game = r.pick(<String>['g1', 'g2', 'g9']);
    final int start = _base + (10 + i) * _day + r.next(_day ~/ 2);
    final int seconds = 60 + r.next(7200);
    // 第 0 / 1 条与第 2 条结束时刻相同（按 endMs 排序并列）。
    final int end = i == 1 ? gameWindows.first.$2 : start + seconds * 1000;
    gameWindows.add((start, end, game));
    await db
        .into(db.galgameSessions)
        .insert(
          GalgameSessionsCompanion.insert(
            gameId: game,
            startMs: start,
            endMs: end,
            durationSeconds: seconds,
            dateKey: FushiDatabase.statCalendarDayKeyOf(
              DateTime.fromMillisecondsSinceEpoch(end, isUtc: true),
            ),
            profileId: Value(profile),
            gameTitle: Value(game == 'g9' ? '消えたゲーム' : ''),
          ),
        );
  }
  // legacy 活动行：游戏 hook 字数（正 / 零 / null）+ 读 / 看 + 库导入事件。
  for (int i = 0; i < 30; i++) {
    final String type = r.pick(<String>[
      kActivityGame,
      kActivityGame,
      kActivityRead,
      kActivityWatch,
      'added',
    ]);
    final int roll = r.next(3);
    await db
        .into(db.activityEvents)
        .insert(
          ActivityEventsCompanion.insert(
            eventType: type,
            mediaType: type == kActivityGame
                ? kActivityMediaGame
                : type == kActivityWatch
                ? kActivityMediaVideo
                : kActivityMediaBook,
            title: 'act$i',
            mediaKey: Value(roll == 0 ? null : 'g${r.next(3)}'),
            dateKey: dateKey(r.next(30)),
            timestampMs: _base + r.next(30) * _day + i,
            durationMs: Value(roll == 1 ? null : r.next(100000)),
            charsDelta: Value(roll == 2 ? null : r.next(4) * 100),
          ),
        );
  }
  // 段：多设备 / 身份 / 域；起点按 gap（30 分钟）边界两侧抖动。
  final List<(String, String, String, String)> media =
      <(String, String, String, String)>[
        (kActivityMediaBook, 'bk1', '唯一の本', 'epub'),
        (kActivityMediaBook, 'bk2', '双子', 'pdf'),
        (kActivityMediaBook, 'bk5', '漫画本', 'manga'),
        (kActivityMediaBook, '', '双子', ''),
        (kActivityMediaBook, 'bk6', '\u{1F600}絵文字', 'epub'),
        (kActivityMediaBook, 'bk\u{FF21}', '全角', 'epub'),
        (kActivityMediaVideo, 'v1', '番剧', ''),
        (kActivityMediaVideo, '', '番剧', ''),
        (kActivityMediaGame, 'g1', 'ゲーム一', ''),
        (kActivityMediaGame, 'g2', '', ''),
        (kActivityMediaGame, 'g9', '消えたゲーム', ''),
      ];
  final List<String> devices = <String>['devA', 'devB', '\u{1F600}dev', ''];
  final Map<String, int> cursor = <String, int>{};
  final List<StudySegmentsCompanion> rows = <StudySegmentsCompanion>[];
  for (int i = 0; i < 360; i++) {
    final (String kind, String key, String title, String format) = r.pick(
      media,
    );
    final String device = r.pick(devices);
    final String stream = '$device|$kind|$key';
    final int gapRoll = r.next(6);
    final int gapMs = switch (gapRoll) {
      0 => 30 * 60000, // 恰在 gap：并
      1 => 30 * 60000 + 1, // 刚过 gap：断
      2 => 0, // 首尾相接
      3 => -60000, // 与上一段重叠
      _ => r.next(6) * 3600000,
    };
    final int previousEnd = cursor[stream] ?? (_base + r.next(40) * _day);
    final int start = previousEnd + gapMs;
    final int length = r.next(5) == 0 ? 0 : 1000 + r.next(1800000);
    final int end = start + length;
    cursor[stream] = end;
    final bool zero = r.next(12) == 0;
    final bool gameChars = kind == kActivityMediaGame;
    final DateTime local = DateTime.fromMillisecondsSinceEpoch(
      start,
      isUtc: true,
    );
    rows.add(
      StudySegmentsCompanion.insert(
        uid: 'u${i.toString().padLeft(4, '0')}',
        deviceId: device,
        mediaKind: kind,
        mediaKey: key,
        title: r.next(4) == 0 ? '' : title,
        format: Value(format),
        startAt: start,
        endAt: end,
        dateKey: FushiDatabase.statCalendarDayKeyOf(local),
        hour: local.hour,
        durationMs: Value(zero || gameChars ? 0 : length),
        chars: Value(zero ? 0 : r.next(2000)),
        pages: Value(zero || kind != kActivityMediaBook ? 0 : r.next(20)),
        updatedAt: start,
        profileId: Value(profile),
      ),
    );
  }
  // 骨架窗口里的游戏字数段：与某次游玩区间相交。
  for (int i = 0; i < gameWindows.length; i += 2) {
    final (int start, int end, String game) = gameWindows[i];
    final DateTime local = DateTime.fromMillisecondsSinceEpoch(
      start,
      isUtc: true,
    );
    rows.add(
      StudySegmentsCompanion.insert(
        uid: 'gw$i',
        deviceId: 'devA',
        mediaKind: kActivityMediaGame,
        mediaKey: game,
        title: game == 'g9' ? '消えたゲーム' : '',
        startAt: start + 1000,
        endAt: end - 1000,
        dateKey: FushiDatabase.statCalendarDayKeyOf(local),
        hour: local.hour,
        chars: Value(100 + i),
        updatedAt: start,
        profileId: Value(profile),
      ),
    );
  }
  await db.batch((Batch b) => b.insertAll(db.studySegments, rows));
}

/// 一条事实的可比较形状。
List<Object?> statFactJson(StatFact f) => <Object?>[
  f.mediaKind,
  f.mediaKey,
  f.title,
  f.format,
  f.dateKey,
  f.hour,
  f.ms,
  f.chars,
  f.pages,
  f.lastActiveMs,
];

/// 一次会话的可比较形状。
List<Object?> studySessionJson(StudySession s) => <Object?>[
  s.mediaKind,
  s.mediaKey,
  s.title,
  s.format,
  s.deviceId,
  s.startAt,
  s.endAt,
  s.durationMs,
  s.chars,
  s.pages,
  s.gameSessionId,
  s.segmentUids,
];

/// 一条活动流行的可比较形状。
List<Object?> activityRowJson(ActivityEventRow e) => <Object?>[
  e.eventType,
  e.mediaType,
  e.title,
  e.mediaKey,
  e.dateKey,
  e.timestampMs,
  e.durationMs,
  e.charsDelta,
];

/// 对拍覆盖的四种读口：统计中心总览（全域、不要活动行、带计数面）、首页（全域、
/// 活动行 200 条）、游戏域页签、单书侧栏。
final List<(String, Future<StatFacts> Function(FushiDatabase))>
kStatParityScopes = <(String, Future<StatFacts> Function(FushiDatabase))>[
  (
    'overview',
    (FushiDatabase db) =>
        loadStatFacts(db, activityLimit: 0, includeCounters: true),
  ),
  ('home', (FushiDatabase db) => loadStatFacts(db)),
  (
    'game',
    (FushiDatabase db) => loadStatFacts(
      db,
      activityLimit: 0,
      scope: const StatFactsScope.domain(kActivityMediaGame),
    ),
  ),
  (
    'book',
    (FushiDatabase db) => loadStatFacts(
      db,
      activityLimit: 0,
      scope: const StatFactsScope.media(
        mediaKind: kActivityMediaBook,
        mediaKey: 'bk2',
        title: '双子',
      ),
    ),
  ),
];

/// 迁移前总览按日求和的口径（`sumStatDaysByKey`：首次出现顺序）；[bookOnly] 是
/// 「所选范围」卡阅读速度用的阅读域切片。
List<List<Object?>> statDayTotalsJson(
  Iterable<StatFact> daily, {
  bool bookOnly = false,
}) {
  final Map<String, List<int>> byDay = <String, List<int>>{};
  for (final StatFact f in daily) {
    if (bookOnly && !f.isBook) continue;
    final List<int> t = byDay.putIfAbsent(f.dateKey, () => <int>[0, 0]);
    t[0] += f.chars;
    t[1] += f.ms;
  }
  return <List<Object?>>[
    for (final MapEntry<String, List<int>> e in byDay.entries)
      <Object?>[e.key, e.value[0], e.value[1]],
  ];
}
