import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 完成判定纯函数：进度 ≥ 90% 且尚未完成、且时长已知。
bool shouldMarkCompleted(int? positionMs, int? durationMs, bool already) {
  if (already) return false;
  if (positionMs == null || durationMs == null || durationMs <= 0) return false;
  return positionMs / durationMs >= 0.9;
}

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

/// 视频观看统计采集器：字幕字数（停留门 + 单调去重，见 [shouldCountCueDwell]）+
/// 完成标记。**观看时长不在这里算**——v90 起交给 [StudyClock]（活跃态 = 正在播放），
/// 本类只把「正在播放吗」与「每 tick 的完成判定」挂到时钟上，字幕字数经
/// [StudyClock.addChars] 记到同一段。
///
/// 此前本类自己跑 60s 定时器、自己累计 `_sessionWatchMs` 并在 stop 时写活动行，
/// 而 `stop()` 在 `await _flush()` 之后才读取清零累计器——dispose 与进程退出并发
/// 各调一次 stop 就各写一条活动行（时长翻倍）。现在没有累计器、没有第二个时钟，
/// 幂等由 [StudyClock.stop] 在结构上保证。
///
/// 不直接依赖 `VideoPlayerController`（其状态读 libmpv，测试宿主无法实例化），
/// 而经 [VideoPlaybackSource] 接口，因此纯单测可用 fake 验证采集逻辑。
class VideoWatchTracker {
  VideoWatchTracker({
    required this.bookUid,
    required StudyClock clock,
    required Future<void> Function(String bookUid) markCompleted,
    FutureOr<void> Function()? onEpisodeCompleted,
  }) : _clock = clock,
       _markCompleted = markCompleted,
       _onEpisodeCompleted = onEpisodeCompleted {
    _clock.isActive = () => _source?.isPlaying ?? false;
    _clock.onTick = (DateTime _) => unawaited(_checkCompletion());
  }

  final String bookUid;
  final StudyClock _clock;
  final Future<void> Function(String bookUid) _markCompleted;
  final FutureOr<void> Function()? _onEpisodeCompleted;

  VideoPlaybackSource? _source;
  final Set<int> _countedIndices = <int>{};
  bool _completed = false;
  bool _episodeCompletionReported = false;

  @visibleForTesting
  int debugSubtitleChars = 0;

  /// 绑定播放源并开始监听 cue 变化（字幕字数采集）。
  void attach(VideoPlaybackSource source) {
    _source = source;
    source.addListener(_onSourceChanged);
  }

  /// 启动观看计时（[StudyClock] 60s 周期，仅播放态入账）。
  void start() => _clock.start();

  /// 停止观看计时。返回的 Future 在最后一次 DB 写完成后才完成，供进程退出路径
  /// await（TODO-086/BUG-191）。可重复调用，第二次 no-op。
  Future<void> stop() async {
    await _clock.stop();
    await _checkCompletion();
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
      // 字幕字数与观看时长记到**同一段**（同 uid 同一行），不再各自派生 dateKey。
      _clock.addChars(chars);
    }
  }

  /// 完成判定（每 tick + stop 各查一次）。
  Future<void> _checkCompletion() async {
    final VideoPlaybackSource? s = _source;
    if (s == null) return;
    try {
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
      // fail-open：完成标记失败不阻塞播放 / 退出；下个 tick 再试。补
      // ErrorLogService.log 使 DB 写异常线上可诊断（fail_open_logging_guard）。
      ErrorLogService.instance.log('VideoWatchTracker.checkCompletion', e, st);
    }
  }
}
