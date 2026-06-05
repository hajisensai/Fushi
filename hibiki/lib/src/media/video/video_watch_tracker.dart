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
///
/// 不直接依赖 `VideoPlayerController`（其状态读 libmpv，测试宿主无法实例化），
/// 而经 [VideoPlaybackSource] 接口，因此纯单测可用 fake 验证采集逻辑。
///
/// 三类回调由上层（页面）注入，统一落 DB：
/// - [_addStat]：把一条增量（字幕字数或观看时长，另一维度传 0）累加进
///   (title, 今日) 行。
/// - [_addHourly]：把观看时长增量累加进 (dateKey, hour) 小时日志（可空：无需小时
///   统计的场景/测试传 null）。
/// - [_markCompleted]：首次进度达阈值时标记该 bookUid 完成（幂等由 DB 层保证）。
class VideoWatchTracker {
  VideoWatchTracker({
    required this.title,
    required this.bookUid,
    required void Function(String title, int subtitleChars, int watchTimeMs)
        addStat,
    required Future<void> Function(String bookUid) markCompleted,
    Future<void> Function(String dateKey, int hour, int deltaMs)? addHourly,
  })  : _addStat = addStat,
        _markCompleted = markCompleted,
        _addHourly = addHourly;

  final String title;
  final String bookUid;
  final void Function(String title, int subtitleChars, int watchTimeMs) _addStat;
  final Future<void> Function(String bookUid) _markCompleted;
  final Future<void> Function(String dateKey, int hour, int deltaMs)? _addHourly;

  static const Duration _interval = Duration(seconds: 60);

  VideoPlaybackSource? _source;
  Timer? _timer;
  DateTime? _tickStart;
  final Set<int> _countedIndices = <int>{};
  bool _completed = false;

  @visibleForTesting
  int debugSubtitleChars = 0;

  /// 绑定播放源并开始监听 cue 变化（字幕字数采集）。
  void attach(VideoPlaybackSource source) {
    _source = source;
    source.addListener(_onSourceChanged);
  }

  /// 启动观看时长定时器（60s 周期，仅播放时累加）。
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
    final String? text = s.currentCue?.text;
    if (idx >= 0 && text != null && _countedIndices.add(idx)) {
      final int chars = text.runes.length;
      if (chars > 0) {
        debugSubtitleChars += chars;
        _addStat(title, chars, 0);
      }
    }
  }

  void _flush() {
    final VideoPlaybackSource? s = _source;
    final DateTime? start = _tickStart;
    final DateTime now = DateTime.now();
    _tickStart = now;
    if (s == null || start == null) return;

    if (s.isPlaying) {
      final List<(String, int, int)> buckets = splitWatchTime(start, now);
      int totalMs = 0;
      for (final (String dateKey, int hour, int ms) in buckets) {
        totalMs += ms;
        _addHourly?.call(dateKey, hour, ms);
      }
      if (totalMs > 0) _addStat(title, 0, totalMs);
    }

    if (shouldMarkCompleted(s.positionMs, s.durationMs, _completed)) {
      _completed = true;
      unawaited(_markCompleted(bookUid));
    }
  }
}
