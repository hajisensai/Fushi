import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';

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

// P4 写侧收敛：dateKey 派生统一走 DB 层权威实现（与复合入口同一份格式化）。
String _dateKey(DateTime d) => FushiDatabase.statDateKeyOf(d);

/// 视频观看统计采集器：观看时长（仅播放时累加）+ 字幕字数（单调去重）+ 完成标记。
///
/// 不直接依赖 `VideoPlayerController`（其状态读 libmpv，测试宿主无法实例化），
/// 而经 [VideoPlaybackSource] 接口，因此纯单测可用 fake 验证采集逻辑。
///
/// 三类回调由上层（页面）注入，统一落 DB（P4 写侧收敛后两条统计路都指向
/// `FushiDatabase.recordWatchFlush` 复合入口）：
/// - [_recordFlush]：把一次 flush 的观看时长桶（[splitWatchTime] 输出，
///   **dateKey/hour 由本采集器按各桶自身时刻决定**，跨午夜正确归两天）交给上层
///   同一事务写小时日志 + 日聚合。上层直接透传，不得另算「今日」。
/// - [_addSubtitleChars]：把一句新 cue 的字幕字数按 cue 时刻的 dateKey 累加进
///   日聚合（不进小时日志）。
/// - [_markCompleted]：首次进度达阈值时标记该 bookUid 完成（幂等由 DB 层保证）。
class VideoWatchTracker {
  VideoWatchTracker({
    required this.title,
    required this.bookUid,
    required FutureOr<void> Function(
            List<(String dateKey, int hour, int watchMs)> buckets)
        recordFlush,
    required FutureOr<void> Function(String dateKey, int subtitleChars)
        addSubtitleChars,
    required Future<void> Function(String bookUid) markCompleted,
    FutureOr<void> Function(String title, String bookUid, String dateKey,
            int timestampMs, int durationMs, int subtitleChars)?
        recordActivity,
    FutureOr<void> Function()? onEpisodeCompleted,
  })  : _recordFlush = recordFlush,
        _addSubtitleChars = addSubtitleChars,
        _markCompleted = markCompleted,
        _recordActivity = recordActivity,
        _onEpisodeCompleted = onEpisodeCompleted;

  final String title;
  final String bookUid;
  final FutureOr<void> Function(
      List<(String dateKey, int hour, int watchMs)> buckets) _recordFlush;
  final FutureOr<void> Function(String dateKey, int subtitleChars)
      _addSubtitleChars;
  final Future<void> Function(String bookUid) _markCompleted;

  /// v49：一次观看 session（attach→stop 生命周期）结束时写一条精确时刻的活动事件，
  /// 喂首页 Activity 时间轴。与按 60s tick 落库的 [_recordFlush] 不同——那会一坐
  /// 产生几十行噪声，故活动事件在 session 累积后**只落一行**（总时长 + 总字幕字数），
  /// dateKey 取 **stop 时刻**。跨午夜时它与桶的日归属**刻意**不同（session 事件 vs
  /// 桶粒度投影，见 recordWatchFlush 的 doc），不得从桶派生、不得「顺手统一」。
  final FutureOr<void> Function(String title, String bookUid, String dateKey,
      int timestampMs, int durationMs, int subtitleChars)? _recordActivity;
  final FutureOr<void> Function()? _onEpisodeCompleted;

  static const Duration _interval = Duration(seconds: 60);

  VideoPlaybackSource? _source;
  Timer? _timer;
  DateTime? _tickStart;
  final Set<int> _countedIndices = <int>{};
  bool _completed = false;
  bool _episodeCompletionReported = false;

  /// v49 session 累积：本次观看的净观看时长（[_flush] 里过滤挂起后累加）与字幕字数，
  /// [stop] 时聚合成一条活动事件后清零（幂等：二次 stop 见 0 不重复写）。
  int _sessionWatchMs = 0;
  int _sessionChars = 0;

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
    // v49：session 结束落一条活动事件（有净观看时长才记）。清零保证幂等——
    // dispose 与进程退出路径可能各调一次 stop，第二次见 0 不重复写。
    final int ms = _sessionWatchMs;
    if (ms > 0 && _recordActivity != null) {
      final int chars = _sessionChars;
      _sessionWatchMs = 0;
      _sessionChars = 0;
      final DateTime now = DateTime.now();
      try {
        await _recordActivity(title, bookUid, _dateKey(now),
            now.millisecondsSinceEpoch, ms, chars);
      } catch (e, st) {
        ErrorLogService.instance.log('VideoWatchTracker.recordActivity', e, st);
      }
    }
  }

  /// 换集：清空字幕去重集与外部单集完成门闩；本地 book 完成标记仍按整本书保持。
  void onEpisodeChanged() {
    _countedIndices.clear();
    _episodeCompletionReported = false;
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
        _sessionChars += chars;
        unawaited(Future<void>.value(
            _addSubtitleChars(_dateKey(DateTime.now()), chars)));
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

    // 周期 tick 经 `unawaited(_flush())` fire-and-forget 调用，DB 写异常无处捕获会被
    // 静默丢弃且线上不可诊断。整段 DB 写包 try/catch：fail-open（异常不冒泡、不阻塞
    // 播放，仅丢本次统计增量），并补 ErrorLogService.log 使其可诊断。
    try {
      // 仅在连续前台播放窗口内累加：[isContinuousWatchGap] 过滤异常大间隔（后台挂起 /
      // 系统睡眠 / 长 GC 停顿致定时器跨越非播放窗口），整窗丢弃而非凭空计入观看时长，
      // 并保证 [splitWatchTime] 输入恒 ≤ kMaxWatchGap（单次至多跨一个边界）。
      if (s.isPlaying && isContinuousWatchGap(start, now)) {
        final List<(String, int, int)> buckets = splitWatchTime(start, now);
        if (buckets.isNotEmpty) {
          // P4 写侧收敛：整批桶一次交给复合入口（同一事务写小时日志 + 日聚合，
          // 桶归属不变——逐桶配各自 dateKey，跨午夜正确归两天），消掉旧接线
          // 「两次独立 await 各自 fail-open」的 hourly/daily 不同步丢失面。
          await _recordFlush(buckets);
          for (final (_, _, int ms) in buckets) {
            _sessionWatchMs += ms; // v49 session 累积（净观看时长，已过挂起守卫）。
          }
        }
      }

      if (shouldMarkCompleted(s.positionMs, s.durationMs, _completed)) {
        _completed = true;
        await _markCompleted(bookUid);
      }
      if (shouldMarkCompleted(
        s.positionMs,
        s.durationMs,
        _episodeCompletionReported,
      )) {
        _episodeCompletionReported = true;
        await _onEpisodeCompleted?.call();
      }
    } catch (e, st) {
      ErrorLogService.instance.log('VideoWatchTracker.flush', e, st);
    }
  }
}
