import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/media/video/video_playback_source.dart';

/// 完成判定纯函数：进度 ≥ 90% 且尚未完成、且时长已知。
bool shouldMarkCompleted(int? positionMs, int? durationMs, bool already) {
  if (already) return false;
  if (positionMs == null || durationMs == null || durationMs <= 0) return false;
  return positionMs / durationMs >= 0.9;
}

/// 单次 flush 允许的最大观看窗口。观看时长由 [VideoWatchTracker] 的 60s 定时器驱动，
/// 正常窗口 ≈ 60s。超过此上限说明定时器跨越了**非连续前台播放窗口**（app 后台挂起 /
/// 系统睡眠 / 长 GC 停顿致定时器被冻结后一次性补发），该段是否真在播放未知。
const Duration kMaxWatchGap = Duration(seconds: 120);

/// 纯谓词：[start]..[now] 是否是一次正常的连续播放窗口。
///
/// 过滤异常大间隔（见 [kMaxWatchGap]）：返回 false 时调用方应整窗丢弃、不累加观看时长，
/// 避免把后台挂起 / 熄屏 / 睡眠时长凭空计入。同时保证 [splitWatchTime] 永远只看到
/// ≤ [kMaxWatchGap] 的输入——单次至多跨一个小时/天边界，其单边界拆桶假设始终成立。
bool isContinuousWatchGap(DateTime start, DateTime now) {
  final Duration d = now.difference(start);
  return d > Duration.zero && d <= kMaxWatchGap;
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
///   (title, dateKey) 行。**dateKey 由本采集器决定**（字幕字数用当下日期；观看时长
///   用 [splitWatchTime] 各桶各自日期），上层回调直接透传，不得另算「今日」——否则
///   跨午夜的 flush 会与 [_addHourly] 的小时日志日归属不一致。
/// - [_addHourly]：把观看时长增量累加进 (dateKey, hour) 小时日志（可空：无需小时
///   统计的场景/测试传 null）。
/// - [_markCompleted]：首次进度达阈值时标记该 bookUid 完成（幂等由 DB 层保证）。
class VideoWatchTracker {
  VideoWatchTracker({
    required this.title,
    required this.bookUid,
    required FutureOr<void> Function(
            String title, String dateKey, int subtitleChars, int watchTimeMs)
        addStat,
    required Future<void> Function(String bookUid) markCompleted,
    Future<void> Function(String dateKey, int hour, int deltaMs)? addHourly,
  })  : _addStat = addStat,
        _markCompleted = markCompleted,
        _addHourly = addHourly;

  final String title;
  final String bookUid;
  final FutureOr<void> Function(
          String title, String dateKey, int subtitleChars, int watchTimeMs)
      _addStat;
  final Future<void> Function(String bookUid) _markCompleted;
  final Future<void> Function(String dateKey, int hour, int deltaMs)?
      _addHourly;

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
    _timer = Timer.periodic(_interval, (_) => unawaited(_flush()));
  }

  /// 停止观看计时（先 flush 退出瞬间的部分窗口再 cancel）。返回的 Future 在那次
  /// flush 的 DB 写完成后才完成，供进程退出路径 await（TODO-086/BUG-191）。
  Future<void> stop() async {
    await _flush();
    _timer?.cancel();
    _timer = null;
    _tickStart = null;
  }

  /// 换集：清空字幕去重集（新集字幕从头计），完成标记不变（按整本书）。
  void onEpisodeChanged() {
    _countedIndices.clear();
  }

  void dispose() {
    unawaited(stop());
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
        unawaited(Future<void>.value(
            _addStat(title, _dateKey(DateTime.now()), chars, 0)));
      }
    }
  }

  /// 把自上次 tick 起的观看时长落库。返回的 Future 在所有 DB 写完成后才完成，
  /// 供 [stop]（进而进程退出路径）await（TODO-086/BUG-191）；周期 tick 用
  /// `unawaited(_flush())` 不阻塞播放。
  Future<void> _flush() async {
    final VideoPlaybackSource? s = _source;
    final DateTime? start = _tickStart;
    final DateTime now = DateTime.now();
    _tickStart = now;
    if (s == null || start == null) return;

    // 仅在连续前台播放窗口内累加：[isContinuousWatchGap] 过滤异常大间隔（后台挂起 /
    // 系统睡眠 / 长 GC 停顿致定时器跨越非播放窗口），整窗丢弃而非凭空计入观看时长，
    // 并保证 [splitWatchTime] 输入恒 ≤ kMaxWatchGap（单次至多跨一个边界）。
    if (s.isPlaying && isContinuousWatchGap(start, now)) {
      for (final (String dateKey, int hour, int ms)
          in splitWatchTime(start, now)) {
        await _addHourly?.call(dateKey, hour, ms);
        // 逐桶配各自 dateKey：跨午夜正确归两天。
        await _addStat(title, dateKey, 0, ms);
      }
    }

    if (shouldMarkCompleted(s.positionMs, s.durationMs, _completed)) {
      _completed = true;
      await _markCompleted(bookUid);
    }
  }
}
