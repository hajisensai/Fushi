import 'package:fushi_core/fushi_core.dart' show VideoDownloadJobLifecycle;
import 'package:fushi_engine/media/torrent/torrent_task_display.dart'
    show TorrentDisplayStatus, torrentDisplayStatusFor;

import 'package:fushi/src/platform/widget_links.dart';

// Pure helpers behind three Android widget features (docs/agent/android-widgets.md):
// "time to finish" on the Continue widget, the Downloads widget and the On deck widget.
// No IO, no providers: `WidgetSnapshotSource` feeds these and `buildWidgetSnapshot`
// embeds their JSON.

// ---------------------------------------------------------------------------
// Time to finish
// ---------------------------------------------------------------------------

/// A speed estimate needs at least this much reading time ...
const int kWidgetSpeedMinMs = 5 * 60 * 1000;

/// ... and at least this many characters, otherwise it is noise (a page flick
/// logged as "read 40 chars in 2 s" would promise a 10 minute novel).
const int kWidgetSpeedMinChars = 300;

/// Fallback window for the user's overall speed (stat days, including today).
const int kWidgetSpeedWindowDays = 30;

/// Sanity cap, characters per millisecond (0.1 = 6000 chars/min). Skimming
/// through a book logs chars without reading them; faster than this is not a
/// reading speed, so no estimate is shown rather than a fantasy one.
const double kWidgetSpeedMaxCharsPerMs = 0.1;

/// One daily stat row of a book (non-manga) that has both time and characters.
class WidgetSpeedSample {
  const WidgetSpeedSample({
    required this.mediaKey,
    required this.dateKey,
    required this.ms,
    required this.chars,
  });

  /// Book key (`StatFact.mediaKey`).
  final String mediaKey;

  /// Stat day key (`yyyy-MM-dd`).
  final String dateKey;
  final int ms;
  final int chars;
}

/// Characters per millisecond, or null when there is too little data to trust.
double? widgetCharsPerMs(int ms, int chars) {
  if (ms < kWidgetSpeedMinMs || chars < kWidgetSpeedMinChars) return null;
  final double speed = chars / ms;
  if (speed.isNaN || speed.isInfinite || speed <= 0) return null;
  if (speed > kWidgetSpeedMaxCharsPerMs) return null;
  return speed;
}

/// Reading speeds from daily stat rows: the speed for [bookKey] itself and the
/// user's overall speed, both over the days `>= sinceDateKey` (lexicographic
/// compare is correct for `yyyy-MM-dd`).
class WidgetReadingSpeeds {
  const WidgetReadingSpeeds({this.book, this.overall});

  final double? book;
  final double? overall;

  /// The book's own speed wins; the overall speed is the fallback.
  double? get best => book ?? overall;
}

WidgetReadingSpeeds computeWidgetReadingSpeeds(
  Iterable<WidgetSpeedSample> samples, {
  required String bookKey,
  required String sinceDateKey,
}) {
  int bookMs = 0;
  int bookChars = 0;
  int allMs = 0;
  int allChars = 0;
  for (final WidgetSpeedSample s in samples) {
    if (s.ms <= 0 || s.chars <= 0) continue;
    if (s.dateKey.compareTo(sinceDateKey) < 0) continue;
    allMs += s.ms;
    allChars += s.chars;
    if (s.mediaKey == bookKey) {
      bookMs += s.ms;
      bookChars += s.chars;
    }
  }
  return WidgetReadingSpeeds(
    book: widgetCharsPerMs(bookMs, bookChars),
    overall: widgetCharsPerMs(allMs, allChars),
  );
}

/// Remaining reading time in ms, or null when it cannot be estimated honestly:
/// no total length, no speed, or the book is already at the end. Never below one
/// minute (a started book is not "0m left").
int? widgetRemainingReadingMs({
  required int totalChars,
  required int positionChars,
  required double? charsPerMs,
}) {
  if (totalChars <= 0 || charsPerMs == null || charsPerMs <= 0) return null;
  final int remaining = totalChars - positionChars.clamp(0, totalChars);
  if (remaining <= 0) return null;
  final int ms = (remaining / charsPerMs).round();
  return ms < 60000 ? 60000 : ms;
}

/// Remaining playback time of a video / audio item, null when the duration is
/// unknown or the position is not before the end.
int? widgetRemainingPlaybackMs({
  required int? durationMs,
  required int positionMs,
}) {
  if (durationMs == null || durationMs <= 0) return null;
  final int remaining = durationMs - positionMs.clamp(0, durationMs);
  if (remaining <= 0) return null;
  return remaining < 60000 ? 60000 : remaining;
}

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

/// How many tasks the widget lists.
const int kWidgetDownloadsListLimit = 3;

/// While a task is running the snapshot is republished at most this often.
const Duration kWidgetDownloadsPublishInterval = Duration(seconds: 5);

/// Failed tasks older than this are not worth a place on the home screen.
const Duration kWidgetDownloadsFailureMaxAge = Duration(days: 3);

enum WidgetDownloadState {
  active,
  queued,
  paused,
  failed;

  String get wire => name;

  /// Lower sorts first: what is moving, then what waits, then what needs you.
  int get rank => switch (this) {
    active => 0,
    queued => 1,
    failed => 2,
    paused => 3,
  };
}

/// One download task as the widget sees it.
class WidgetDownloadTaskInput {
  const WidgetDownloadTaskInput({
    required this.id,
    required this.title,
    required this.state,
    this.progress,
    this.downRateBps = 0,
    this.createdAt = 0,
  });

  final String id;
  final String title;
  final WidgetDownloadState state;

  /// 0..1; null = unknown.
  final double? progress;

  /// Live download speed in bytes per second (only meaningful when active).
  final int downRateBps;
  final int createdAt;
}

/// Everything the Downloads widget shows. [enabled] false = the download center
/// is unavailable (module off / store policy): the widget shows its empty state.
class WidgetDownloadsInput {
  const WidgetDownloadsInput({
    this.enabled = true,
    this.tasks = const <WidgetDownloadTaskInput>[],
  });

  final bool enabled;
  final List<WidgetDownloadTaskInput> tasks;

  /// Something is moving or queued: the snapshot keeps being republished.
  bool get hasActive => enabled && tasks.any(_isRunning);
}

bool _isRunning(WidgetDownloadTaskInput t) =>
    t.state == WidgetDownloadState.active ||
    t.state == WidgetDownloadState.queued;

/// Maps a durable video/torrent job to the widget state. null = not a download
/// the widget should list (finished, or only seeding).
///
/// `cancelled` is the frozen DB value for "paused by the user" (see
/// `VideoDownloadPipelineService.cancelJob`). [backendState] is the torrent
/// backend state string when a live snapshot exists.
WidgetDownloadState? widgetDownloadStateForJob({
  required String lifecycle,
  String? backendState,
}) {
  switch (lifecycle) {
    case VideoDownloadJobLifecycle.completed:
      return null;
    case VideoDownloadJobLifecycle.cancelled:
      return WidgetDownloadState.paused;
    case VideoDownloadJobLifecycle.failed:
    case VideoDownloadJobLifecycle.needsAttention:
      return WidgetDownloadState.failed;
  }
  if (backendState == null) return WidgetDownloadState.active;
  return switch (torrentDisplayStatusFor(backendState)) {
    TorrentDisplayStatus.paused => WidgetDownloadState.paused,
    TorrentDisplayStatus.queued => WidgetDownloadState.queued,
    TorrentDisplayStatus.error => WidgetDownloadState.failed,
    TorrentDisplayStatus.seeding || TorrentDisplayStatus.completed => null,
    _ => WidgetDownloadState.active,
  };
}

/// "512 B/s", "84 KB/s", "1.2 MB/s" (binary units; units are not localized).
String formatWidgetSpeed(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return '';
  const List<String> units = <String>['B/s', 'KB/s', 'MB/s', 'GB/s'];
  double value = bytesPerSecond.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final String number = unit == 0 || value >= 100
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$number ${units[unit]}';
}

int? _percentOf(double? progress) {
  if (progress == null || progress.isNaN || progress.isInfinite) return null;
  final double clamped = progress < 0 ? 0 : (progress > 1 ? 1 : progress);
  return (clamped * 100).floor();
}

/// The snapshot `downloads` block.
///
/// - `count` = unfinished tasks (running, queued, paused, failed); `running` =
///   active + queued; `percent` = mean progress of the non-failed tasks that
///   report one (null when none does); `speed` = summed live speed of active tasks.
/// - `tasks` = the top [kWidgetDownloadsListLimit]: active, queued, failed,
///   paused; ties by newest first, then id (deterministic).
/// - Disabled / empty input gives `count: 0` and an empty list (widget empty state).
Map<String, Object?> buildWidgetDownloadsJson(WidgetDownloadsInput input) {
  final List<WidgetDownloadTaskInput> tasks = input.enabled
      ? List<WidgetDownloadTaskInput>.of(input.tasks)
      : <WidgetDownloadTaskInput>[];
  tasks.sort((WidgetDownloadTaskInput a, WidgetDownloadTaskInput b) {
    final int byRank = a.state.rank.compareTo(b.state.rank);
    if (byRank != 0) return byRank;
    final int byNew = b.createdAt.compareTo(a.createdAt);
    return byNew != 0 ? byNew : a.id.compareTo(b.id);
  });
  double sum = 0;
  int known = 0;
  int speed = 0;
  int running = 0;
  for (final WidgetDownloadTaskInput t in tasks) {
    if (_isRunning(t)) running++;
    if (t.state == WidgetDownloadState.active) {
      speed += t.downRateBps < 0 ? 0 : t.downRateBps;
    }
    final int? p = _percentOf(t.progress);
    if (t.state != WidgetDownloadState.failed && p != null) {
      sum += p;
      known++;
    }
  }
  return <String, Object?>{
    'count': tasks.length,
    'running': running,
    'percent': known == 0 ? null : (sum / known).floor(),
    'speed': formatWidgetSpeed(speed),
    'tasks': <Map<String, Object?>>[
      for (final WidgetDownloadTaskInput t in tasks.take(
        kWidgetDownloadsListLimit,
      ))
        <String, Object?>{
          'id': t.id,
          'title': t.title.trim(),
          'state': t.state.wire,
          'percent': _percentOf(t.progress),
          'speed': t.state == WidgetDownloadState.active
              ? formatWidgetSpeed(t.downRateBps)
              : '',
        },
    ],
  };
}

/// How long to wait before the next download republish: null = publish now
/// (never published, or the interval has elapsed).
Duration? widgetDownloadsPublishDelay({
  required DateTime? lastPublishedAt,
  required DateTime now,
  Duration minInterval = kWidgetDownloadsPublishInterval,
}) {
  if (lastPublishedAt == null) return null;
  final Duration since = now.difference(lastPublishedAt);
  if (since.isNegative) return minInterval;
  return since >= minInterval ? null : minInterval - since;
}

// ---------------------------------------------------------------------------
// On deck (media servers)
// ---------------------------------------------------------------------------

/// Items on the On deck widget.
const int kWidgetOnDeckLimit = 4;

/// `none` = no media server configured, `off` = servers exist but their items
/// are not shown in Home > Continue (the opt-in the dashboard uses), `ok`.
enum WidgetOnDeckState {
  none,
  off,
  ok;

  String get wire => name;
}

/// One in-progress server item (mirror of the dashboard's `ServerContinueCandidate`).
class WidgetOnDeckItemInput {
  const WidgetOnDeckItemInput({
    required this.source,
    required this.serverId,
    required this.serverName,
    required this.itemId,
    required this.title,
    this.collectionName,
    this.recentMs = 0,
    this.progress,
    this.coverPath = '',
  });

  final WidgetServerSource source;
  final String serverId;
  final String serverName;
  final String itemId;
  final String title;

  /// Series / podcast name; when set it is the headline and [title] the detail.
  final String? collectionName;
  final int recentMs;

  /// 0..1; null = unknown.
  final double? progress;

  /// Local cover file ('' = none yet).
  final String coverPath;
}

class WidgetOnDeckInput {
  const WidgetOnDeckInput({
    this.state = WidgetOnDeckState.none,
    this.items = const <WidgetOnDeckItemInput>[],
  });

  final WidgetOnDeckState state;
  final List<WidgetOnDeckItemInput> items;
}

/// The snapshot `onDeck` block: newest first, de-duplicated, at most
/// [kWidgetOnDeckLimit]. Titles are always present (the native side hides them
/// per privacy). Items only exist for `ok`.
Map<String, Object?> buildWidgetOnDeckJson(
  WidgetOnDeckInput input, {
  String Function(int epochMs)? formatAge,
}) {
  final List<WidgetOnDeckItemInput> items = <WidgetOnDeckItemInput>[];
  if (input.state == WidgetOnDeckState.ok) {
    final Set<String> seen = <String>{};
    final List<WidgetOnDeckItemInput> unique = <WidgetOnDeckItemInput>[
      for (final WidgetOnDeckItemInput i in input.items)
        if (i.itemId.isNotEmpty &&
            i.serverId.isNotEmpty &&
            seen.add('${i.source.wire}|${i.serverId}|${i.itemId}'))
          i,
    ];
    final List<int> order = <int>[for (int i = 0; i < unique.length; i++) i]
      ..sort((int a, int b) {
        final int byRecent = unique[b].recentMs.compareTo(unique[a].recentMs);
        return byRecent != 0 ? byRecent : a.compareTo(b);
      });
    items.addAll(order.take(kWidgetOnDeckLimit).map((int i) => unique[i]));
  }
  return <String, Object?>{
    'state': input.state.wire,
    'items': <Map<String, Object?>>[
      for (final WidgetOnDeckItemInput i in items)
        _onDeckItemJson(i, formatAge),
    ],
  };
}

Map<String, Object?> _onDeckItemJson(
  WidgetOnDeckItemInput i,
  String Function(int epochMs)? formatAge,
) {
  final String? collection = i.collectionName?.trim();
  final bool grouped = collection != null && collection.isNotEmpty;
  final double? raw = i.progress;
  final double progress = raw == null || raw.isNaN || raw.isInfinite
      ? 0
      : (raw < 0 ? 0 : (raw > 1 ? 1 : raw));
  return <String, Object?>{
    'kind': i.source == WidgetServerSource.audiobookshelf
        ? 'audiobook'
        : 'video',
    'title': (grouped ? collection : i.title).trim(),
    'subtitle': grouped ? i.title.trim() : '',
    'server': i.serverName.trim(),
    'progress': progress,
    'position': progress > 0 ? '${(progress * 100).round()}%' : '',
    'cover': i.coverPath,
    'lastActive': i.recentMs > 0 && formatAge != null
        ? formatAge(i.recentMs)
        : '',
    'link': WidgetServerLink.build(
      source: i.source,
      serverId: i.serverId,
      itemId: i.itemId,
    ),
  };
}

// ---------------------------------------------------------------------------
// Cover cache bookkeeping (files under <appSupport>/widget_covers/)
// ---------------------------------------------------------------------------

/// Stable, filesystem-safe cover file name for a cache key (two 32-bit FNV-1a
/// hashes, forward and reversed, so a collision needs both to collide).
String widgetCoverFileName(String key) {
  int fnv(Iterable<int> units) {
    int hash = 0x811c9dc5;
    for (final int unit in units) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  String hex(int v) => v.toRadixString(16).padLeft(8, '0');
  return '${hex(fnv(key.codeUnits))}${hex(fnv(key.codeUnits.reversed))}.png';
}

/// Which cached cover files to delete: everything not in [keep]. The directory
/// only holds covers this feature wrote, so "unreferenced" is the whole rule.
List<String> widgetCoversToPrune({
  required Iterable<String> existing,
  required Set<String> keep,
}) => <String>[
  for (final String name in existing)
    if (!keep.contains(name)) name,
];
