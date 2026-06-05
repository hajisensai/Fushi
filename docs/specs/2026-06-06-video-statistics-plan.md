# 视频统计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在视频区域提供与书籍统计位置对等、形态一致的统计功能（观看时长 + 字幕字数 + 完成视频数），入口在视频页。

**Architecture:** 数据与阅读统计完全隔离（新表 `VideoWatchStatistics` / `VideoHourlyLogs` + `VideoBooks.completedAt` 列，schema v21→v22）。采集经新 `VideoWatchTracker`（依赖可测接口 `VideoPlaybackSource`，`VideoPlayerController` 实现之）在 `VideoHibikiPage` 挂载。统计页 `VideoStatisticsPage` 复用从 `reading_statistics_page.dart` 提取的共享图表 `stat_charts.dart` 与可测聚合 `video_stat_aggregates.dart`。

**Tech Stack:** Flutter / Dart 3.12、Drift 2.23、Riverpod、Slang i18n、flutter_test。

参照设计：`docs/specs/2026-06-06-video-statistics-design.md`。

---

## 关键约定

- 所有手动命令在 worktree 路径 `D:\APP\vs_claude_code\hibiki\.claude\worktrees\video-statistics` 下执行（禁止 cd 主仓库）。
- Flutter 测试在 `hibiki/` 下：`flutter test <path> --no-pub`。
- 改 `tables.dart` / `database.dart` 后必须重新生成：在 `packages/hibiki_core/` 下 `dart run build_runner build --delete-conflicting-outputs`。
- 每个 Task 末尾 commit；只 stage 本 Task 文件（禁止 `git add -A`）。

---

## Task 1: 数据库表 + 迁移 + CRUD（hibiki_core）

**Files:**
- Modify: `packages/hibiki_core/lib/src/database/tables.dart`（在 `ReadingHourlyLogs` 后、`Preferences` 前加两表；`VideoBooks` 加列）
- Modify: `packages/hibiki_core/lib/src/database/database.dart`（`@DriftDatabase` tables 列表、`schemaVersion`、`from < 22` 迁移、CRUD）
- Regenerate: `packages/hibiki_core/lib/src/database/database.g.dart`
- Test: `hibiki/test/database/video_statistics_test.dart`

- [ ] **Step 1: 在 `tables.dart` 加两表**（紧跟 `ReadingHourlyLogs` 定义，第 156 行后）

```dart
// ── video_watch_statistics ──────────────────────────────────────────
@DataClassName('VideoWatchStatisticRow')
class VideoWatchStatistics extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get dateKey => text()();
  IntColumn get subtitleChars => integer()();
  IntColumn get watchTimeMs => integer()();
  IntColumn get lastModified => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {title, dateKey},
      ];
}

// ── video_hourly_logs ───────────────────────────────────────────────
@DataClassName('VideoHourlyLogRow')
class VideoHourlyLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get dateKey => text()();
  IntColumn get hour => integer()();
  IntColumn get watchTimeMs => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {dateKey, hour},
      ];
}
```

- [ ] **Step 2: 在 `VideoBooks` 表加列**（`tables.dart`，`delayMs` 列后、`primaryKey` 前，约第 342 行后）

```dart
  /// 视频首次播放进度 ≥ 90% 的时间戳（完成标记）；null = 未完成。统计用，去重计数。
  DateTimeColumn get completedAt => dateTime().nullable()();
```

- [ ] **Step 3: 注册表 + 升 schemaVersion + 迁移**（`database.dart`）

在 `@DriftDatabase(tables: [...])` 列表末尾（`VideoBookTagMappings,` 后）加：
```dart
  VideoWatchStatistics,
  VideoHourlyLogs,
```

`schemaVersion` 21 → 22：
```dart
  int get schemaVersion => 22;
```

在 `if (from < 21) { ... }` 块后、`onUpgrade` 闭合 `}` 前加：
```dart
          if (from < 22) {
            // 视频统计：两张独立表 + video_books.completed_at 列。与阅读统计完全
            // 隔离，不碰 reading_statistics。fresh DB 已由 onCreate 的 createAll
            // 建好，故用 _tableExists / _columnExists 守卫避免重复创建。
            if (!await _tableExists('video_watch_statistics')) {
              await m.createTable(videoWatchStatistics);
            }
            if (!await _tableExists('video_hourly_logs')) {
              await m.createTable(videoHourlyLogs);
            }
            if (!await _columnExists('video_books', 'completed_at')) {
              await m.addColumn(videoBooks, videoBooks.completedAt);
            }
          }
```

- [ ] **Step 4: 加 CRUD**（`database.dart`，在 `// ── reading hourly logs ──` 块之后，约第 950 行附近 reading 区块尾部加新区块）

```dart
  // ── video watch statistics ──────────────────────────────────────
  /// ACCUMULATE：把 [subtitleChars]/[watchTimeMs] 累加到 (title, dateKey) 现有
  /// 总量。对照 [addReadingStatistic]，但视频专用、与阅读统计隔离。
  Future<void> addVideoWatchStatistic({
    required String title,
    required String dateKey,
    required int subtitleChars,
    required int watchTimeMs,
  }) =>
      transaction(() async {
        final existing = await (select(videoWatchStatistics)
              ..where((t) => t.title.equals(title) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(videoWatchStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(VideoWatchStatisticsCompanion(
            subtitleChars: Value(existing.subtitleChars + subtitleChars),
            watchTimeMs: Value(existing.watchTimeMs + watchTimeMs),
            lastModified: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        } else {
          await into(videoWatchStatistics).insert(
            VideoWatchStatisticsCompanion.insert(
              title: title,
              dateKey: dateKey,
              subtitleChars: subtitleChars,
              watchTimeMs: watchTimeMs,
              lastModified: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
      });

  Future<List<VideoWatchStatisticRow>> getAllVideoWatchStatistics() =>
      select(videoWatchStatistics).get();

  // ── video hourly logs ───────────────────────────────────────────
  Future<void> addVideoHourlyWatchTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
  }) =>
      transaction(() async {
        final existing = await (select(videoHourlyLogs)
              ..where((t) => t.dateKey.equals(dateKey) & t.hour.equals(hour)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(videoHourlyLogs)..where((t) => t.id.equals(existing.id)))
              .write(VideoHourlyLogsCompanion(
            watchTimeMs: Value(existing.watchTimeMs + deltaMs),
          ));
        } else {
          await into(videoHourlyLogs).insert(
            VideoHourlyLogsCompanion.insert(
              dateKey: dateKey,
              hour: hour,
              watchTimeMs: deltaMs,
            ),
          );
        }
      });

  Future<List<VideoHourlyLogRow>> getVideoHourlyLogsForDate(String dateKey) =>
      (select(videoHourlyLogs)..where((t) => t.dateKey.equals(dateKey))).get();

  /// 仅当当前 completed_at 为 null 时写入（幂等首次完成；重看不覆盖）。
  Future<void> markVideoCompleted(String bookUid, DateTime completedAt) =>
      (update(videoBooks)
            ..where((t) =>
                t.bookUid.equals(bookUid) & t.completedAt.isNull()))
          .write(VideoBooksCompanion(completedAt: Value(completedAt)));
```

- [ ] **Step 5: 重新生成 drift**

Run（在 `packages/hibiki_core/`）：
```bash
dart run build_runner build --delete-conflicting-outputs
```
Expected: 生成成功，`database.g.dart` 含 `VideoWatchStatisticRow` / `VideoHourlyLogRow` / `VideoBooks.completedAt`。

- [ ] **Step 6: 写失败测试** `hibiki/test/database/video_statistics_test.dart`

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase db;
  setUp(() => db = HibikiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('addVideoWatchStatistic accumulates by (title, dateKey)', () async {
    await db.addVideoWatchStatistic(
        title: 'A', dateKey: '2026-06-06', subtitleChars: 10, watchTimeMs: 1000);
    await db.addVideoWatchStatistic(
        title: 'A', dateKey: '2026-06-06', subtitleChars: 5, watchTimeMs: 500);
    final rows = await db.getAllVideoWatchStatistics();
    expect(rows.length, 1);
    expect(rows.first.subtitleChars, 15);
    expect(rows.first.watchTimeMs, 1500);
  });

  test('addVideoHourlyWatchTime accumulates by (dateKey, hour)', () async {
    await db.addVideoHourlyWatchTime(dateKey: '2026-06-06', hour: 9, deltaMs: 100);
    await db.addVideoHourlyWatchTime(dateKey: '2026-06-06', hour: 9, deltaMs: 200);
    final rows = await db.getVideoHourlyLogsForDate('2026-06-06');
    expect(rows.length, 1);
    expect(rows.first.watchTimeMs, 300);
  });

  test('markVideoCompleted is idempotent first-write', () async {
    await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'u1', title: 'A', videoPath: '/v.mp4'));
    final t1 = DateTime(2026, 6, 6, 10);
    final t2 = DateTime(2026, 6, 6, 12);
    await db.markVideoCompleted('u1', t1);
    await db.markVideoCompleted('u1', t2); // 不覆盖
    final row = await db.getVideoBookByBookUid('u1');
    expect(row!.completedAt, t1);
  });
}
```

- [ ] **Step 7: 跑测试**

Run（在 `hibiki/`）：`flutter test test/database/video_statistics_test.dart --no-pub`
Expected: 3 passed。

- [ ] **Step 8: 迁移测试** —— 在 `hibiki/test/database/migration_test.dart` 末尾加 v21→v22 用例（参照该文件已有迁移用例风格：用旧 schema 建库写一行 video_books，升级后断言数据保留 + 新表可用）。若文件用 `SchemaVerifier` / drift 测试工具，照既有范式；否则用 `customStatement` 建 v21 库后构造 v22 `HibikiDatabase` 触发迁移，断言旧 video_books 行 `completed_at` 为 null 且未丢失。

Run: `flutter test test/database/migration_test.dart --no-pub`
Expected: PASS（含新用例）。

- [ ] **Step 9: Commit**

```bash
git add packages/hibiki_core/lib/src/database/tables.dart packages/hibiki_core/lib/src/database/database.dart packages/hibiki_core/lib/src/database/database.g.dart hibiki/test/database/video_statistics_test.dart hibiki/test/database/migration_test.dart
git commit -m "feat(video): video statistics tables + CRUD + v22 migration"
```

---

## Task 2: `VideoPlaybackSource` 接口 + controller `durationMs` getter

**Files:**
- Create: `hibiki/lib/src/media/video/video_playback_source.dart`
- Modify: `hibiki/lib/src/media/video/video_player_controller.dart`（implements 接口 + `durationMs` getter）

- [ ] **Step 1: 定义可测接口** `video_playback_source.dart`

```dart
import 'package:flutter/foundation.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 视频播放只读视图，供 [VideoWatchTracker] 采集统计用。抽成接口让 tracker
/// 不直接依赖 media_kit 的 [VideoPlayerController]（其状态读 libmpv player，
/// 测试宿主无法实例化），从而可用 fake 纯单测采集逻辑。
abstract interface class VideoPlaybackSource implements Listenable {
  /// 是否正在播放（暂停 / 未 load 为 false）。观看时长仅在播放时累加。
  bool get isPlaying;

  /// 当前字幕 cue 下标（-1 = 无 / gap）。
  int get currentCueIndex;

  /// 当前字幕 cue（null = 无）。
  AudioCue? get currentCue;

  /// 当前播放位置（毫秒）；未 load 为 null。
  int? get positionMs;

  /// 媒体总时长（毫秒）；未 load / 未解析为 null 或 0。
  int? get durationMs;
}
```

- [ ] **Step 2: controller 实现接口 + 加 `durationMs`**（`video_player_controller.dart`）

类声明改为：
```dart
class VideoPlayerController extends ChangeNotifier
    implements VideoPlaybackSource {
```
加 import：
```dart
import 'package:hibiki/src/media/video/video_playback_source.dart';
```
在 `positionMs` getter（第 82 行）后加：
```dart
  /// 媒体总时长（毫秒）；未 [load] / 未解析媒体头时为 null。
  @override
  int? get durationMs => _player?.state.duration.inMilliseconds;
```
（`isPlaying` / `currentCueIndex` / `currentCue` / `positionMs` 已存在，签名匹配；为 `currentCueIndex` / `currentCue` / `isPlaying` / `positionMs` 加 `@override` 注解。）

- [ ] **Step 3: 编译验证**

Run（在 `hibiki/`）：`flutter analyze lib/src/media/video/ --no-pub`
Expected: No issues（接口契约满足）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/media/video/video_playback_source.dart hibiki/lib/src/media/video/video_player_controller.dart
git commit -m "feat(video): VideoPlaybackSource interface + durationMs getter"
```

---

## Task 3: `VideoWatchTracker`（采集逻辑，可测）

**Files:**
- Create: `hibiki/lib/src/media/video/video_watch_tracker.dart`
- Test: `hibiki/test/media/video/video_watch_tracker_test.dart`

设计：tracker 持有 db + bookUid + title + `VideoPlaybackSource`。
- 观看时长：60s 定时器，`_flush()` 仅当 `source.isPlaying` 时按 `_tickStart..now` 累加（纯函数 `splitWatchTime` 处理跨小时/跨天）。
- 字幕字数：`source.addListener` → cue 变化时若 `currentCueIndex` 是当前集未计过的新下标，累加 `currentCue.text` 字符；用 `Set<int> _countedIndices` 去重；`onEpisodeChanged()` 清空（换集重新计）。
- 完成判定：每次 `_flush` 检查 `shouldMarkCompleted(positionMs, durationMs, _completed)`（纯函数，阈值 0.9）；满足则 `markVideoCompleted` 并置 `_completed=true`。

- [ ] **Step 1: 写失败测试** `hibiki/test/media/video/video_watch_tracker_test.dart`

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_playback_source.dart';
import 'package:hibiki/src/media/video/video_watch_tracker.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

class _FakeSource extends ChangeNotifier implements VideoPlaybackSource {
  @override
  bool isPlaying = false;
  @override
  int currentCueIndex = -1;
  @override
  AudioCue? currentCue;
  @override
  int? positionMs;
  @override
  int? durationMs;
  void emit() => notifyListeners();
}

AudioCue _cue(String text) => AudioCue(
      bookKey: 'b',
      chapterHref: '',
      sentenceIndex: 0,
      textFragmentId: '',
      text: text,
      startMs: 0,
      endMs: 0,
      audioFileIndex: 0,
    );

void main() {
  group('shouldMarkCompleted', () {
    test('true when >=90% and not yet completed', () {
      expect(shouldMarkCompleted(90, 100, false), isTrue);
      expect(shouldMarkCompleted(95, 100, false), isTrue);
    });
    test('false below 90%', () {
      expect(shouldMarkCompleted(89, 100, false), isFalse);
    });
    test('false when already completed', () {
      expect(shouldMarkCompleted(99, 100, true), isFalse);
    });
    test('false when duration unknown', () {
      expect(shouldMarkCompleted(50, 0, false), isFalse);
      expect(shouldMarkCompleted(50, null, false), isFalse);
      expect(shouldMarkCompleted(null, 100, false), isFalse);
    });
  });

  group('splitWatchTime', () {
    test('same hour single bucket', () {
      final r = splitWatchTime(
          DateTime(2026, 6, 6, 9, 0, 0), DateTime(2026, 6, 6, 9, 0, 30));
      expect(r, [('2026-06-06', 9, 30000)]);
    });
    test('crossing hour splits into two buckets', () {
      final r = splitWatchTime(
          DateTime(2026, 6, 6, 9, 59, 50), DateTime(2026, 6, 6, 10, 0, 10));
      expect(r.length, 2);
      expect(r[0].$1, '2026-06-06');
      expect(r[0].$2, 9);
      expect(r[1].$2, 10);
    });
  });

  group('subtitle char counting (monotonic, dedup per episode)', () {
    late _FakeSource src;
    late VideoWatchTracker tracker;
    setUp(() {
      src = _FakeSource();
      tracker = VideoWatchTracker(
        addStat: (title, chars, ms) => _recorded.add((title, chars, ms)),
        markCompleted: (_) async {},
        title: 'A',
        bookUid: 'u1',
      )..attach(src);
    });
    tearDown(() => tracker.dispose());

    test('counts a new cue once; re-seek to same cue does not double-count', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいう'); // 3
      src.emit();
      src.currentCueIndex = 1;
      src.currentCue = _cue('かきくけ'); // 4
      src.emit();
      src.currentCueIndex = 0; // 回看第一句
      src.currentCue = _cue('あいう');
      src.emit();
      expect(tracker.debugSubtitleChars, 7);
    });

    test('onEpisodeChanged resets dedup set', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あい'); // 2
      src.emit();
      tracker.onEpisodeChanged();
      src.currentCueIndex = 0; // 新集第 0 句
      src.currentCue = _cue('うえお'); // 3
      src.emit();
      expect(tracker.debugSubtitleChars, 5);
    });
  });
}

final List<(String, int, int)> _recorded = <(String, int, int)>[];
```
> 注：`AudioCue` 构造参数名以 `hibiki_audio` 实际定义为准（实现时核对 `audio_cue.dart`，调整 `_cue` 工厂）。`debugSubtitleChars` 为 `@visibleForTesting` 累计器。

- [ ] **Step 2: 跑测试看失败**

Run: `flutter test test/media/video/video_watch_tracker_test.dart --no-pub`
Expected: FAIL（`video_watch_tracker.dart` 不存在）。

- [ ] **Step 3: 实现** `hibiki/lib/src/media/video/video_watch_tracker.dart`

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/media/video/video_playback_source.dart';

/// 完成判定纯函数：进度 ≥ 90% 且尚未完成、且时长已知。
bool shouldMarkCompleted(int? positionMs, int? durationMs, bool already) {
  if (already) return false;
  if (positionMs == null || durationMs == null || durationMs <= 0) return false;
  return positionMs / durationMs >= 0.9;
}

/// 把 [start]..[now] 的观看时长按小时/天边界拆成 (dateKey, hour, ms) 桶。
/// 对照 ReadingTimeTracker._flush，但抽成纯函数便于单测。
List<(String, int, int)> splitWatchTime(DateTime start, DateTime now) {
  final int elapsed = now.difference(start).inMilliseconds;
  if (elapsed <= 0) return const <(String, int, int)>[];
  if (start.hour != now.hour || start.day != now.day) {
    final DateTime boundary =
        DateTime(start.year, start.month, start.day, start.hour + 1);
    final int firstMs = boundary.difference(start).inMilliseconds;
    final int secondMs = now.difference(boundary).inMilliseconds;
    return <(String, int, int)>[
      if (firstMs > 0) (_dateKey(start), start.hour, firstMs),
      if (secondMs > 0) (_dateKey(now), now.hour, secondMs),
    ];
  }
  return <(String, int, int)>[(_dateKey(start), start.hour, elapsed)];
}

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 视频观看统计采集器：观看时长（仅播放时累加）+ 字幕字数（单调去重）+ 完成标记。
/// 不直接依赖 [VideoPlayerController]，通过 [VideoPlaybackSource] 接口，便于单测。
class VideoWatchTracker {
  VideoWatchTracker({
    required this.title,
    required this.bookUid,
    required Future<void> Function(
            String dateKey, int hour, int deltaMs)?
        addHourly,
    required void Function(String title, int subtitleChars, int watchTimeMs)
        addStat,
    required Future<void> Function(String bookUid) markCompleted,
  })  : _addHourly = addHourly,
        _addStat = addStat,
        _markCompleted = markCompleted;

  final String title;
  final String bookUid;
  final Future<void> Function(String dateKey, int hour, int deltaMs)? _addHourly;
  final void Function(String title, int subtitleChars, int watchTimeMs) _addStat;
  final Future<void> Function(String bookUid) _markCompleted;

  static const Duration _interval = Duration(seconds: 60);

  VideoPlaybackSource? _source;
  Timer? _timer;
  DateTime? _tickStart;
  final Set<int> _countedIndices = <int>{};
  bool _completed = false;

  @visibleForTesting
  int debugSubtitleChars = 0;

  void attach(VideoPlaybackSource source) {
    _source = source;
    source.addListener(_onSourceChanged);
  }

  void start() {
    if (_timer != null) return;
    _tickStart = DateTime.now();
    _timer = Timer.periodic(_interval, (_) => _flush());
  }

  void stop() {
    _flush();
    _timer?.cancel();
    _timer = null;
    _tickStart = null;
  }

  /// 换集：清空字幕去重集（新集字幕从头计），完成标记不变（按整本书）。
  void onEpisodeChanged() {
    _countedIndices.clear();
  }

  void dispose() {
    stop();
    _source?.removeListener(_onSourceChanged);
    _source = null;
  }

  void _onSourceChanged() {
    final VideoPlaybackSource? s = _source;
    if (s == null) return;
    final int idx = s.currentCueIndex;
    final text = s.currentCue?.text;
    if (idx >= 0 && text != null && _countedIndices.add(idx)) {
      final int chars = text.characters.length;
      debugSubtitleChars += chars;
      _addStat(title, chars, 0);
    }
  }

  void _flush() {
    final VideoPlaybackSource? s = _source;
    final DateTime? start = _tickStart;
    final DateTime now = DateTime.now();
    _tickStart = now;
    if (s == null || start == null) return;

    if (s.isPlaying) {
      final buckets = splitWatchTime(start, now);
      int totalMs = 0;
      for (final b in buckets) {
        totalMs += b.$3;
        _addHourly?.call(b.$1, b.$2, b.$3);
      }
      if (totalMs > 0) _addStat(title, 0, totalMs);
    }

    if (shouldMarkCompleted(s.positionMs, s.durationMs, _completed)) {
      _completed = true;
      unawaited(_markCompleted(bookUid));
    }
  }
}
```
> 加 import `package:characters/characters.dart`（`text.characters.length` 按字素计数；若 pubspec 未直接依赖 characters，用 `text.runes.length` 替代）。`_addStat` 同时承载字幕字数（ms=0）与观看时长（chars=0），由调用方累加进同一行。

- [ ] **Step 4: 跑测试至通过**

Run: `flutter test test/media/video/video_watch_tracker_test.dart --no-pub`
Expected: PASS。修正测试里 `AudioCue` 构造与 `_addStat`/`addHourly` 命名匹配实现。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/media/video/video_watch_tracker.dart hibiki/test/media/video/video_watch_tracker_test.dart
git commit -m "feat(video): VideoWatchTracker watch-time/subtitle-chars/completion collection"
```

---

## Task 4: 在 `VideoHibikiPage` 接入采集

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`

- [ ] **Step 1: 加字段 + import**

import：
```dart
import 'package:hibiki/src/media/video/video_watch_tracker.dart';
```
State 字段（`_controller` 附近）：
```dart
  VideoWatchTracker? _watchTracker;
```

- [ ] **Step 2: 在 `_applyLoad` setState 后创建/绑定 tracker**

在 `_applyLoad`（第 410 `setState` 块）之后、`_restoreAudioTrack` 之前加：
```dart
    // 首次 load 建采集器；换片复用同一 controller 实例时只需保证已 attach。
    if (_watchTracker == null) {
      final HibikiDatabase db = appModel.database;
      _watchTracker = VideoWatchTracker(
        title: title,
        bookUid: widget.bookUid,
        addHourly: (dateKey, hour, deltaMs) =>
            db.addVideoHourlyWatchTime(
                dateKey: dateKey, hour: hour, deltaMs: deltaMs),
        addStat: (t, chars, ms) => unawaited(db.addVideoWatchStatistic(
            title: t, dateKey: _todayKey(), subtitleChars: chars, watchTimeMs: ms)),
        markCompleted: (uid) => db.markVideoCompleted(uid, DateTime.now()),
      )
        ..attach(controller)
        ..start();
    }
```
加私有 helper（State 内）：
```dart
  String _todayKey() {
    final DateTime d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
```
> `HibikiDatabase` import 经 `hibiki_core`；`appModel.database` 已在本类可用。

- [ ] **Step 3: 换集时通知 tracker**

在 `_switchEpisode`（约第 480-500，切集逻辑里 `_applyLoad` 调用后或集索引更新处）加：
```dart
    _watchTracker?.onEpisodeChanged();
```

- [ ] **Step 4: dispose 释放 tracker**（`dispose`，第 553 `_controller?.dispose()` 前）

```dart
    _watchTracker?.dispose();
    _watchTracker = null;
```

- [ ] **Step 5: 编译验证**

Run（在 `hibiki/`）：`flutter analyze lib/src/pages/implementations/video_hibiki_page.dart --no-pub`
Expected: No issues。

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/pages/implementations/video_hibiki_page.dart
git commit -m "feat(video): wire VideoWatchTracker into VideoHibikiPage"
```

---

## Task 5: 提取共享图表 `stat_charts.dart`（重构，等价）

**Files:**
- Create: `hibiki/lib/src/pages/implementations/stat_charts.dart`
- Modify: `hibiki/lib/src/pages/implementations/reading_statistics_page.dart`
- Test: `hibiki/test/pages/reading_statistics_page_test.dart`（若已存在则跑回归；否则加最小渲染冒烟）

- [ ] **Step 1: 新建 `stat_charts.dart`**，把 `reading_statistics_page.dart` 第 395-621 行的 `_DayData` / `_HourlyChartPainter` / `_BarChartPainter` 原样移入并改为公共名：
  - `_DayData` → `StatDayData`（公开）。
  - `_HourlyChartPainter` → `StatHourlyChartPainter`（公开，构造参数不变）。
  - `_BarChartPainter` → `StatBarChartPainter`（公开，`data` 类型 `List<StatDayData>`）。
  - 顶部 `import 'package:flutter/foundation.dart';` + `import 'package:flutter/material.dart';`。

- [ ] **Step 2: 改 `reading_statistics_page.dart` 引用共享类**
  - 删除文件内 `_DayData` / `_HourlyChartPainter` / `_BarChartPainter` 定义（第 395-621）。
  - 加 `import 'package:hibiki/src/pages/implementations/stat_charts.dart';`。
  - `_DayData` → `StatDayData`（字段 `_dailyData` 类型、`_computeAggregates` 内构造、`_BarChartPainter` data 类型）。
  - `_HourlyChartPainter(...)` → `StatHourlyChartPainter(...)`；`_BarChartPainter(...)` → `StatBarChartPainter(...)`。
  - `_BookData` 是阅读页私有、视频页不复用 → 保留在 `reading_statistics_page.dart`。

- [ ] **Step 3: 编译 + 回归**

Run（在 `hibiki/`）：
```bash
flutter analyze lib/src/pages/implementations/reading_statistics_page.dart lib/src/pages/implementations/stat_charts.dart --no-pub
flutter test test/pages/ --no-pub
```
Expected: analyze 0；阅读统计相关测试全绿（重构等价，行为不变）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/pages/implementations/stat_charts.dart hibiki/lib/src/pages/implementations/reading_statistics_page.dart
git commit -m "refactor(stats): extract shared stat chart painters to stat_charts.dart"
```

---

## Task 6: i18n keys

**Files:**
- Modify (via tool): `hibiki/lib/i18n/*.i18n.json`（17 文件，经 `tool/i18n_sync.dart`）
- Regenerate: `hibiki/lib/i18n/strings.g.dart`

- [ ] **Step 1: 加 key**（在 `hibiki/`，逐条 `--add <key> <en> <zh>`）

```bash
dart run tool/i18n_sync.dart --add video_statistics "Video Statistics" "视频统计"
dart run tool/i18n_sync.dart --add video_stat_by_video "By Video" "按视频"
dart run tool/i18n_sync.dart --add video_stat_subtitle_chars "Subtitle Characters" "字幕字数"
dart run tool/i18n_sync.dart --add video_stat_watch_time "Watch Time" "观看时长"
dart run tool/i18n_sync.dart --add video_stat_completed "Completed" "已完成"
dart run tool/i18n_sync.dart --add video_stat_no_data "No video statistics yet" "暂无视频统计数据"
```
> 复用现有 `stat_today` / `stat_this_week` / `stat_this_month` / `stat_all_time` / `stat_format_*` / `stat_refresh` / `stat_today_hourly` / `stat_last_30_days`，不重复添加。

- [ ] **Step 2: 重新生成 + 格式化**

Run（在 `hibiki/`）：
```bash
dart run slang
dart format lib/i18n/strings.g.dart
```

- [ ] **Step 3: i18n 完整性测试**

Run: `flutter test test/i18n/ --no-pub`
Expected: PASS（17 语言 key 齐全）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/i18n/
git commit -m "i18n(video): add video statistics keys (17 langs)"
```

---

## Task 7: 聚合纯函数 + `VideoStatisticsPage`

**Files:**
- Create: `hibiki/lib/src/pages/implementations/video_stat_aggregates.dart`
- Create: `hibiki/lib/src/pages/implementations/video_statistics_page.dart`
- Modify: `hibiki/lib/pages.dart`（barrel 导出新页，若 barrel 模式要求）
- Test: `hibiki/test/pages/video_stat_aggregates_test.dart`

- [ ] **Step 1: 写聚合失败测试** `hibiki/test/pages/video_stat_aggregates_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_stat_aggregates.dart';
import 'package:hibiki_core/hibiki_core.dart';

VideoWatchStatisticRow _row(String title, String dateKey, int chars, int ms) =>
    VideoWatchStatisticRow(
      id: 0,
      title: title,
      dateKey: dateKey,
      subtitleChars: chars,
      watchTimeMs: ms,
      lastModified: 0,
    );

void main() {
  final now = DateTime(2026, 6, 6, 12);
  test('today/week/month/all buckets accumulate', () {
    final stats = [
      _row('A', '2026-06-06', 100, 1000), // today
      _row('A', '2026-06-01', 50, 500), // within week & month
      _row('B', '2026-05-10', 30, 300), // within month only
      _row('B', '2026-01-01', 10, 100), // all only
    ];
    final agg = computeVideoStats(stats: stats, completed: const [], now: now);
    expect(agg.todayChars, 100);
    expect(agg.weekChars, 150);
    expect(agg.monthChars, 180);
    expect(agg.allChars, 190);
  });

  test('by-video sorted by chars desc', () {
    final stats = [
      _row('A', '2026-06-06', 10, 0),
      _row('B', '2026-06-06', 99, 0),
    ];
    final agg = computeVideoStats(stats: stats, completed: const [], now: now);
    expect(agg.byVideo.first.title, 'B');
  });

  test('completed counts by timestamp bucket', () {
    final agg = computeVideoStats(
      stats: const [],
      completed: [DateTime(2026, 6, 6, 9), DateTime(2026, 5, 1)],
      now: now,
    );
    expect(agg.todayCompleted, 1);
    expect(agg.monthCompleted, 2);
    expect(agg.allCompleted, 2);
  });
}
```

- [ ] **Step 2: 跑测试看失败**

Run: `flutter test test/pages/video_stat_aggregates_test.dart --no-pub`
Expected: FAIL（文件不存在）。

- [ ] **Step 3: 实现** `video_stat_aggregates.dart`

```dart
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki_core/hibiki_core.dart';

class VideoStatBookData {
  VideoStatBookData(this.title);
  final String title;
  int chars = 0;
  int ms = 0;
}

class VideoStatsAggregate {
  int todayChars = 0, todayMs = 0, todayCompleted = 0;
  int weekChars = 0, weekMs = 0, weekCompleted = 0;
  int monthChars = 0, monthMs = 0, monthCompleted = 0;
  int allChars = 0, allMs = 0, allCompleted = 0;
  List<StatDayData> daily = <StatDayData>[];
  List<VideoStatBookData> byVideo = <VideoStatBookData>[];
}

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

VideoStatsAggregate computeVideoStats({
  required List<VideoWatchStatisticRow> stats,
  required List<DateTime> completed,
  required DateTime now,
}) {
  final agg = VideoStatsAggregate();
  final todayKey = _dateKey(now);
  final weekAgoKey = _dateKey(now.subtract(const Duration(days: 7)));
  final monthAgoKey = _dateKey(now.subtract(const Duration(days: 30)));

  final dailyMap = <String, StatDayData>{};
  final bookMap = <String, VideoStatBookData>{};

  for (final s in stats) {
    agg.allChars += s.subtitleChars;
    agg.allMs += s.watchTimeMs;
    if (s.dateKey == todayKey) {
      agg.todayChars += s.subtitleChars;
      agg.todayMs += s.watchTimeMs;
    }
    if (s.dateKey.compareTo(weekAgoKey) >= 0) {
      agg.weekChars += s.subtitleChars;
      agg.weekMs += s.watchTimeMs;
    }
    if (s.dateKey.compareTo(monthAgoKey) >= 0) {
      agg.monthChars += s.subtitleChars;
      agg.monthMs += s.watchTimeMs;
    }
    final d = dailyMap.putIfAbsent(s.dateKey, () => StatDayData(dateKey: s.dateKey));
    d.chars += s.subtitleChars;
    d.ms += s.watchTimeMs;
    final b = bookMap.putIfAbsent(s.title, () => VideoStatBookData(s.title));
    b.chars += s.subtitleChars;
    b.ms += s.watchTimeMs;
  }

  final thirtyDaysAgo = now.subtract(const Duration(days: 29));
  for (int i = 0; i < 30; i++) {
    final key = _dateKey(thirtyDaysAgo.add(Duration(days: i)));
    agg.daily.add(dailyMap[key] ?? StatDayData(dateKey: key));
  }
  agg.byVideo = bookMap.values.toList()
    ..sort((a, b) => b.chars.compareTo(a.chars));

  for (final c in completed) {
    final key = _dateKey(c);
    agg.allCompleted++;
    if (key == todayKey) agg.todayCompleted++;
    if (key.compareTo(weekAgoKey) >= 0) agg.weekCompleted++;
    if (key.compareTo(monthAgoKey) >= 0) agg.monthCompleted++;
  }
  return agg;
}
```
> `StatDayData` 需有公开构造 `StatDayData({required this.dateKey})` 与 `chars`/`ms` 字段（Task 5 提取时确保）。

- [ ] **Step 4: 跑聚合测试至通过**

Run: `flutter test test/pages/video_stat_aggregates_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 5: 实现页面** `video_statistics_page.dart`

复制 `reading_statistics_page.dart` 结构改造（参照其 build/_buildSummaryCards/_buildHourlyChart/_buildDailyChart/_buildBookTile）：
- 类 `VideoStatisticsPage extends BasePage` / state `_VideoStatisticsPageState extends BasePageState`。
- `_loadFromDatabase`：`db.getAllVideoWatchStatistics()` + `db.getVideoHourlyLogsForDate(today)`（读 `watchTimeMs`）+ `VideoBookRepository(db).listAll()` 取非空 `completedAt` 列表 → `computeVideoStats(...)`。
- 标题 `t.video_statistics`；空态 `t.video_stat_no_data`；刷新按钮同款。
- 汇总卡 `_summaryStatPanel(label, chars, ms, completed)`：字幕字数（大）+ `t.video_stat_watch_time` 时长（小）+ `t.video_stat_completed` 完成数（小）。复用 `_formatTime` / `_formatChars`（同阅读页，复制进本文件，或后续抽公共——本计划内复制，YAGNI）。
- 小时图 `StatHourlyChartPainter(hourlyMs: _hourlyMs, ...)`（观看时长）。
- 30 天图 `StatBarChartPainter(data: agg.daily, ...)`（字幕字数）。
- 排行标题 `t.video_stat_by_video`，行渲染 `agg.byVideo`（标题 + 进度条 + `字幕字数 · 时长`）。

- [ ] **Step 6: barrel 导出**

若 `hibiki/lib/pages.dart` 显式导出各页，加：
```dart
export 'src/pages/implementations/video_statistics_page.dart';
```
（核对 `pages.dart` 是否用 `export ... show` 或目录导出；按既有风格。）

- [ ] **Step 7: 编译验证**

Run（在 `hibiki/`）：`flutter analyze lib/src/pages/implementations/video_statistics_page.dart lib/src/pages/implementations/video_stat_aggregates.dart --no-pub`
Expected: No issues。

- [ ] **Step 8: Commit**

```bash
git add hibiki/lib/src/pages/implementations/video_stat_aggregates.dart hibiki/lib/src/pages/implementations/video_statistics_page.dart hibiki/test/pages/video_stat_aggregates_test.dart hibiki/lib/pages.dart
git commit -m "feat(video): VideoStatisticsPage + aggregate pure functions"
```

---

## Task 8: 视频页统计入口 + widget 测试

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_video_page.dart`
- Test: `hibiki/test/pages/home_video_statistics_entry_test.dart`

- [ ] **Step 1: 加入口按钮**（`home_video_page.dart` AppBar `actions`，第 188-195，在导入 IconButton 后/前）

```dart
          IconButton(
            tooltip: t.video_statistics,
            icon: const Icon(Icons.bar_chart_outlined),
            onPressed: _openStatistics,
          ),
```
加 import：
```dart
import 'package:hibiki/src/pages/implementations/video_statistics_page.dart';
```
加方法：
```dart
  void _openStatistics() {
    Navigator.push(
      context,
      adaptivePageRoute<void>(builder: (_) => const VideoStatisticsPage()),
    );
  }
```

- [ ] **Step 2: 写 widget 测试** `hibiki/test/pages/home_video_statistics_entry_test.dart`

最小验证：渲染 `HomeVideoPage`（带 fake/in-memory repo），找到 tooltip 为 `t.video_statistics` 的 `IconButton` 存在。参照 `test/pages/` 既有视频/书架页 widget 测试搭脚手架（ProviderScope + 必要 override）。

- [ ] **Step 3: 跑测试**

Run: `flutter test test/pages/home_video_statistics_entry_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/pages/implementations/home_video_page.dart hibiki/test/pages/home_video_statistics_entry_test.dart
git commit -m "feat(video): video statistics entry in video page toolbar"
```

---

## Task 9: 全量验证 + 收尾

- [ ] **Step 1: format + analyze + 全量测试**

Run（在 `hibiki/`）：
```bash
dart format .
flutter analyze --no-pub
flutter test --no-pub
```
Expected: analyze 0；全量测试绿。记录绿色数量。

- [ ] **Step 2: 代码审查**（CLAUDE.md 强制步骤 3）

spawn code-reviewer subagent（`model: "opus"`），审查实现是否符合 spec、边界、向后兼容（迁移无损、阅读统计不受影响、采集不漏不重）。修复 Critical/High 后重审。

- [ ] **Step 3: 设备验证待用户**

阅读器/导入/播放类改动声明"修好"前需真机/模拟器复测原始路径（看视频→产生统计→打开视频统计页核对数据）。本计划交付后标注「真机待用户」。

---

## Self-Review 检查

- **Spec 覆盖**：观看时长(Task3/4)、字幕字数(Task3/4)、完成数(Task1/3/4/7)、存储(Task1)、统计页(Task7)、共享图表(Task5)、入口(Task8)、i18n(Task6)、测试(各 Task + Task9)。✅
- **类型一致**：`computeVideoStats` / `VideoStatsAggregate` / `StatDayData` / `VideoPlaybackSource`(durationMs/isPlaying/currentCueIndex/currentCue/positionMs) / `addVideoWatchStatistic`(subtitleChars,watchTimeMs) 在各 Task 间签名一致。✅
- **占位符**：tracker 测试里 `AudioCue` 构造、`pages.dart` 导出风格、migration_test 范式三处标注「实现时核对」，非 TODO 而是依赖既有代码的精确点，实现时按仓库现状对齐。
