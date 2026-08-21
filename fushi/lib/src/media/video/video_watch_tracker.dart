import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_audio/fushi_audio.dart';
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

/// 一句 cue 计入字幕字数所需的最低真实播放停留（媒体时间，毫秒）。
/// 短 cue 取自身时长为门（日语字幕大量 cue 短于该值，固定阈值会让它们永远不计）。
///
/// 取自跨域共享的 [kArrivalDwellMs]：「多久才算停留过」是同一条产品判据，漫画的
/// 翻页停留门用的是同一个数，不再各写各的 1500。
const int kCueDwellMs = kArrivalDwellMs;

/// 停留量与墙钟流逝的对账余量（毫秒）。媒体时间推进得比墙钟快出这个余量以上的部分
/// 不算停留——拖进度条 / 字幕列表点跳会让位置瞬间前进几秒而墙钟只过了几十毫秒。
/// 留一点余量是因为倍速播放与 tick 抖动会让两者不严格相等。
const int kCueDwellWallClockSlackMs = 250;

/// 纯谓词（BUG-1763）：候选 cue 的**真实播放推进量**是否已满足停留门。
///
/// [playedMs] 只累计播放态下的位置前进（seek 跳变与暂停不算，见调用方的观察窗
/// 累计规则）。旧实现「位置进入 cue 即全额计」没有任何停留判据：暂停态拖进度条、
/// 字幕列表点击、开视频落在断点 cue 上，都会把整句字数刷进统计。
bool shouldCountCueDwell({
  required int playedMs,
  required int? cueStartMs,
  required int? cueEndMs,
}) {
  final int threshold =
      (cueStartMs != null && cueEndMs != null && cueEndMs > cueStartMs)
          ? math.min(kCueDwellMs, cueEndMs - cueStartMs)
          : kCueDwellMs;
  return playedMs >= threshold;
}

/// 视频观看统计采集器：观看时长（仅播放时累加）+ 字幕字数（停留门 + 单调去重，
/// 见 [shouldCountCueDwell]）+ 完成标记。
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

  /// 换集：清空字幕去重集、停留门候选与外部单集完成门闩；本地 book 完成标记仍按
  /// 整本书保持。候选必须一并清：下标指向的是旧集 cue 表。
  void onEpisodeChanged() {
    _countedIndices.clear();
    _pendingCueIndex = -1;
    _pendingPlayedMs = 0;
    _pendingObservedAt = null;
    _episodeCompletionReported = false;
  }

  void dispose() {
    unawaited(stop());
    _source?.removeListener(_onSourceChanged);
    _source = null;
  }

  /// BUG-1763 停留门候选（观察窗）：当前句、其字幕文本/起止时刻、上次观察到的
  /// 播放位置、以及累计的**真实播放推进量**。
  int _pendingCueIndex = -1;
  String _pendingCueText = '';
  int? _pendingCueStartMs;
  int? _pendingCueEndMs;
  int _pendingLastPosMs = 0;
  int _pendingPlayedMs = 0;
  DateTime? _pendingObservedAt;

  /// 测试注入的墙钟：停留量要与真实流逝时间对账（见 [_accumulatePending]）。
  @visibleForTesting
  DateTime Function() debugNowForTesting = DateTime.now;

  /// BUG-1763：字幕字数入账必须过停留门（[shouldCountCueDwell]），不再「位置进入
  /// cue 即全额计」。旧实现不看 isPlaying、不看播了多久：暂停态拖进度条 / 字幕列表
  /// 点击跳句 / 开视频落在断点 cue 上，每个落点命中的句子都全额入账——「0 分钟
  /// 观看 + 几千字幕字」可以纯靠暂停拖条刷出来。
  ///
  /// 停留量由 [_accumulatePending] 从「进句 / 换句」两个事件之间的媒体位置推进推导，
  /// 并与墙钟对账——**不按 tick 累加**，因为生产端明确抑制同句 tick 通知（详见
  /// [_accumulatePending] 的说明）。达到门槛立即入账。
  void _onSourceChanged() {
    final VideoPlaybackSource? s = _source;
    if (s == null) return;
    final int idx = s.currentCueIndex;
    final int? pos = s.positionMs;
    if (idx != _pendingCueIndex) {
      // 换句这一刻先把上一句的停留量结算掉：生产路径上这**就是**上一句能收到的最后
      // 一次通知（见 [_accumulatePending] 的说明）。
      _accumulatePending(pos);
      _commitPendingIfDwelled();
      final AudioCue? cue = idx >= 0 ? s.currentCue : null;
      final String? text = cue?.text;
      if (cue != null &&
          text != null &&
          pos != null &&
          !_countedIndices.contains(idx)) {
        _pendingCueIndex = idx;
        _pendingCueText = text;
        _pendingCueStartMs = cue.startMs;
        _pendingCueEndMs = cue.endMs;
        _pendingLastPosMs = _clampToPendingCue(pos);
        _pendingPlayedMs = 0;
        _pendingObservedAt = debugNowForTesting();
      }
      return;
    }
    if (_pendingCueIndex < 0 || pos == null) return;
    // 同句再次收到通知（部分源会因别的原因通知）：照常推进，与换句结算共用同一套账。
    _accumulatePending(pos);
    if (shouldCountCueDwell(
      playedMs: _pendingPlayedMs,
      cueStartMs: _pendingCueStartMs,
      cueEndMs: _pendingCueEndMs,
    )) {
      _commitPendingIfDwelled();
    }
  }

  /// 把 [pos] 夹进候选 cue 的时间窗。换句那一刻 pos 已经落在下一句里，不夹的话会把
  /// 后面的时间算进上一句；跳走同理。
  int _clampToPendingCue(int pos) {
    final int? start = _pendingCueStartMs;
    final int? end = _pendingCueEndMs;
    if (start == null || end == null || end <= start) return pos;
    return pos < start ? start : (pos > end ? end : pos);
  }

  /// 把候选 cue 的停留量推进到 [pos] 这一刻。
  ///
  /// **不能依赖「同句 tick 会不会来」**：[VideoPlayerController] 的契约明确规定命中
  /// 下标与当前相同时**不重复** notifyListeners（源码注释写着「避免每 125ms tick 无谓
  /// notifyListeners」）。所以生产路径上一句 cue 从进到出只收到两次通知——进句一次、
  /// 换句一次。按 tick 累加的写法在生产里恒为 0，字幕字数会**永远计不上**（而假源每
  /// 500ms emit 一次的测试照样绿）。故停留量从这两个事件之间的媒体位置推进推导。
  ///
  /// 两道钳制，缺一不可：
  ///  * 位置先夹进本句时间窗（[_clampToPendingCue]），否则换句那一刻的 pos 会把下一句
  ///    的时间算进上一句；
  ///  * 再与**墙钟**流逝量对账取小：拖进度条 / 字幕列表点跳会让媒体时间瞬间推进几秒而
  ///    墙钟只过了几十毫秒，那不是停留。倍速播放时按墙钟收费，偏保守（宁可少算）。
  void _accumulatePending(int? pos) {
    if (_pendingCueIndex < 0 || pos == null) return;
    final DateTime now = debugNowForTesting();
    final DateTime? since = _pendingObservedAt;
    final int clamped = _clampToPendingCue(pos);
    final int delta = clamped - _pendingLastPosMs;
    _pendingLastPosMs = clamped;
    _pendingObservedAt = now;
    if (delta <= 0) return;
    final int wallMs = since == null
        ? delta
        : now.difference(since).inMilliseconds + kCueDwellWallClockSlackMs;
    _pendingPlayedMs += math.min(delta, math.max(0, wallMs));
  }

  /// 结算候选：停留量达标才入账（去重集兜底），未达标直接丢弃（宁可少算）。
  void _commitPendingIfDwelled() {
    final int idx = _pendingCueIndex;
    if (idx < 0) return;
    _pendingCueIndex = -1;
    if (!shouldCountCueDwell(
      playedMs: _pendingPlayedMs,
      cueStartMs: _pendingCueStartMs,
      cueEndMs: _pendingCueEndMs,
    )) {
      return;
    }
    if (!_countedIndices.add(idx)) return;
    final int chars = _pendingCueText.runes.length;
    if (chars > 0) {
      debugSubtitleChars += chars;
      _sessionChars += chars;
      unawaited(Future<void>.value(
          _addSubtitleChars(_dateKey(DateTime.now()), chars)));
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
