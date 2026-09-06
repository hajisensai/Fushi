import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/stats/interval_coverage.dart';
import 'package:fushi/src/stats/study_char_count.dart';
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

/// 观看时长采样间隔（BUG-2108）。位置推进按这个节奏采样成「片内区间」并入
/// [IntervalCoverage]；只有首次覆盖的部分计时。1s 足够细：一次 ≥ 1.5s 的 seek 在
/// 一个采样间隔里就会超过 [kPlaybackAdvanceSlackMs] 余量被判成跳变。
const Duration kWatchSampleInterval = Duration(seconds: 1);

/// 采样间隔内「媒体推进 vs 墙钟 × 倍速」的对账余量（毫秒）。超出 = seek 跳变，该
/// 区间不算看过、不计时（跳过去的内容没看）。
const int kPlaybackAdvanceSlackMs = 500;

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

/// 纯函数（BUG-2108）：两次采样之间位置从 [fromMs] 推进到 [toMs]，墙钟走了 [wallMs]，
/// 倍速 [speed]——这是**连续播放**还是 seek 跳变？连续播放时媒体推进 ≈ 墙钟 × 倍速，
/// 允许 25% 抖动 + [kPlaybackAdvanceSlackMs] 余量；超出即跳变。倒退 / 不动一律 false
/// （暂停 / 拖回 / 回放上一句，位置没有向前推进就没有「新看到的内容」）。
bool isContinuousPlaybackAdvance({
  required int fromMs,
  required int toMs,
  required int wallMs,
  required double speed,
}) {
  final int delta = toMs - fromMs;
  if (delta <= 0 || wallMs <= 0) return false;
  final double rate = speed > 0 ? speed : 1.0;
  return delta <= wallMs * rate * 1.25 + kPlaybackAdvanceSlackMs;
}

/// 视频观看统计采集器：观看时长（首次覆盖，BUG-2108）+ 字幕字数（停留门 + 单调去重，
/// 见 [shouldCountCueDwell]）+ 完成标记。
///
/// 观看时长口径（用户拍板 2026-09-04）：**重听不计**。每 [kWatchSampleInterval] 采一次
/// 位置，两次采样间若是连续播放（[isContinuousPlaybackAdvance]），把这段片内区间并入
/// [IntervalCoverage]，只有**此前未覆盖**的部分按比例折成墙钟时间经
/// [StudyClock.addActiveMs] 记账。回放上一句 / 拖回重听 / 次日重看：区间已在并集里，
/// 推进为 0，不计。覆盖并集按视频身份持久化（[loadCoverage] / [saveCoverage]），
/// 所以单部视频累计观看时长 ≤ 片长。
///
/// 此前观看时长由 [StudyClock] 按 tick 末刻 `isPlaying` 整窗计——一个 20s 回放可能
/// 记 60s 也可能记 0s，而且重听照计：用户实测 90 分钟电影记 120 分钟。现在时钟走
/// [StudyAccrual.explicit]，只做段生命周期与落库。
///
/// 字幕字数同律：本次会话前就已整段覆盖的 cue 不再计字（[_coverageAtAttach]）；
/// 会话内回看由 [_countedIndices] 去重。
///
/// 不直接依赖 `VideoPlayerController`（其状态读 libmpv，测试宿主无法实例化），
/// 而经 [VideoPlaybackSource] 接口，因此纯单测可用 fake 验证采集逻辑。
class VideoWatchTracker {
  VideoWatchTracker({
    required this.bookUid,
    required StudyClock clock,
    required Future<void> Function(String bookUid) markCompleted,
    FutureOr<void> Function()? onEpisodeCompleted,
    Future<String?> Function()? loadCoverage,
    Future<void> Function(String json)? saveCoverage,
  })  : assert(
          clock.accrual == StudyAccrual.explicit,
          '视频面时钟必须是显式记账：时长由 tracker 按首次覆盖推入',
        ),
        _clock = clock,
        _markCompleted = markCompleted,
        _onEpisodeCompleted = onEpisodeCompleted,
        _loadCoverage = loadCoverage,
        _saveCoverage = saveCoverage {
    _clock.onTick = (DateTime _) {
      unawaited(_checkCompletion());
      unawaited(_persistCoverage());
    };
  }

  final String bookUid;
  final StudyClock _clock;
  final Future<void> Function(String bookUid) _markCompleted;
  final FutureOr<void> Function()? _onEpisodeCompleted;
  final Future<String?> Function()? _loadCoverage;
  final Future<void> Function(String json)? _saveCoverage;

  VideoPlaybackSource? _source;
  final Set<int> _countedIndices = <int>{};
  bool _completed = false;
  bool _episodeCompletionReported = false;

  @visibleForTesting
  int debugSubtitleChars = 0;

  /// 绑定播放源并开始监听 cue 变化（字幕字数采集）；同时异步加载该视频的覆盖并集。
  void attach(VideoPlaybackSource source) {
    _source = source;
    source.addListener(_onSourceChanged);
    _coverageLoad ??= _initCoverage();
  }

  /// 启动观看计时（位置采样 + [StudyClock] 60s 周期落库）。
  void start() {
    _clock.start();
    _lastSample = null;
    _sampler ??= Timer.periodic(kWatchSampleInterval, (_) => _sample());
    _sample();
  }

  /// 停止观看计时。返回的 Future 在最后一次 DB 写完成后才完成，供进程退出路径
  /// await（TODO-086/BUG-191）。可重复调用，第二次 no-op。
  Future<void> stop() async {
    _sampler?.cancel();
    _sampler = null;
    _sample();
    _lastSample = null;
    await _clock.stop();
    await _checkCompletion();
    await _persistCoverage();
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

  // ── 观看时长：位置采样 → 首次覆盖区间 → 显式记账（BUG-2108）──────────────

  /// 本视频已看过的片内区间并集（attach 时从持久层加载，会话中增长）。
  IntervalCoverage _coverage = IntervalCoverage();

  /// 本次会话前的覆盖快照：字幕字数门用（已看过的句不再计字）。
  IntervalCoverage _coverageAtAttach = IntervalCoverage();
  Future<void>? _coverageLoad;
  bool _coverageReady = false;
  bool _coverageDirty = false;
  Timer? _sampler;

  /// 上一次采样：(位置, 墙钟, 播放态)。
  ({int? posMs, DateTime at, bool playing})? _lastSample;

  /// 已覆盖并集（测试 / 诊断）。
  @visibleForTesting
  IntervalCoverage get debugCoverage => _coverage;

  /// 覆盖并集加载完成（测试等待用）。
  @visibleForTesting
  Future<void> get debugCoverageLoaded => _coverageLoad ?? Future<void>.value();

  Future<void> _initCoverage() async {
    String? json;
    try {
      json = await _loadCoverage?.call();
    } catch (e, st) {
      // fail-open：读不到就当没看过（宁可多计一次首看，不阻塞播放）。
      ErrorLogService.instance.log('VideoWatchTracker.loadCoverage', e, st);
    }
    _coverage = IntervalCoverage.fromJson(json);
    _coverageAtAttach = _coverage.copy();
    _coverageReady = true;
  }

  /// 采一次位置。相邻两次采样之间若是连续播放，把 `[prev, now)` 并入覆盖并集，
  /// 只有新增（此前未覆盖）的部分按「墙钟 × 新增/推进」折成时长记账。
  ///
  /// 采样点 = 定时器每秒一次 + 播放源每次通知（play / pause / seek / 换句都会
  /// 通知），所以状态翻转那一刻也会被结算到，精度不受 1s 节奏限制。
  void _sample() {
    final VideoPlaybackSource? s = _source;
    if (s == null) return;
    final DateTime now = debugNowForTesting();
    final int? pos = s.positionMs;
    final bool playing = s.isPlaying;
    final ({int? posMs, DateTime at, bool playing})? prev = _lastSample;
    _lastSample = (posMs: pos, at: now, playing: playing);
    if (prev == null || !_coverageReady) return;
    final int? from = prev.posMs;
    if (from == null || pos == null) return;
    // 两端都在播放才算一段连续播放窗口；中途暂停过的窗口（≤ 1s）整窗不计，
    // 与「宁可少算」的停留门同一取向。
    if (!prev.playing || !playing) return;
    final int wallMs = now.difference(prev.at).inMilliseconds;
    if (!isContinuousPlaybackAdvance(
      fromMs: from,
      toMs: pos,
      wallMs: wallMs,
      speed: s.speed,
    )) {
      return;
    }
    final int advanced = pos - from;
    final int fresh = _coverage.add(from, pos);
    if (fresh <= 0) return;
    _coverageDirty = true;
    // 记账封顶：这段新内容按当前倍速播完本来就只需要 `fresh / rate` 毫秒真实时间，
    // 记账不可能比它多。
    //
    // 没有这条时，采样窗口的墙钟没有任何上界，而 [isContinuousPlaybackAdvance] 的容差
    // 是 `wallMs * rate * 1.25`——窗口越大越松，恒判「连续」，于是整段墙钟被记成观看
    // 时长。两条真实路径都会踩到：
    //  * **合盖睡眠**：Flutter 桌面端 S3 唤醒不走 `paused`（只有 paused/hidden 分支才
    //    `stop()`），sampler 全程没停；唤醒后位置只前进几百毫秒，墙钟却走了 8 小时；
    //  * **网络流长时间卡缓冲**：`isPlaying` 仍为 true，位置冻结十分钟后前进 100ms。
    // 后果不只是数字虚高——`addActiveMs` 会把这些毫秒全塞进单个小时桶，产出一条
    // `durationMs = 8h` 的段，直接破坏本域「段不跨小时边界」的不变式。
    //
    // **不用「窗口超界就整窗丢弃」**：那会误杀「采样被拖慢但内容真的在播」的合法窗口
    // （位置与墙钟同步推进 10s，本该记 10s）。封顶按内容量结算，两种病态各自收敛到
    // 它们真正看掉的那点内容，合法窗口分毫不动。
    final double rate = s.speed > 0 ? s.speed : 1.0;
    final int credit = math.min(
      (wallMs * fresh) ~/ advanced,
      (fresh / rate).round(),
    );
    if (credit <= 0) return;
    _clock.addActiveMs(credit);
  }

  Future<void> _persistCoverage() async {
    if (!_coverageDirty || !_coverageReady) return;
    final Future<void> Function(String)? save = _saveCoverage;
    if (save == null) return;
    _coverageDirty = false;
    try {
      await save(_coverage.toJson());
    } catch (e, st) {
      // fail-open：写失败下个 tick 再写（并集只增不减，重写是幂等的）。
      _coverageDirty = true;
      ErrorLogService.instance.log('VideoWatchTracker.saveCoverage', e, st);
    }
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

  /// 测试注入的墙钟：停留量与观看时长都要与真实流逝时间对账（见 [_accumulatePending]
  /// / [_sample]）。
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
    // 播放源每次通知都是一个采样点（播放态翻转 / seek / 换句）。
    if (_sampler != null) _sample();
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
  /// 本次会话前就整段看过的句（覆盖快照）不再计字——重听不计，字数与时长同律。
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
    final int? start = _pendingCueStartMs;
    final int? end = _pendingCueEndMs;
    if (start != null && end != null && _coverageAtAttach.covers(start, end)) {
      return;
    }
    // 与 EPUB / 漫画 / galgame 同一口径（[countStudyChars]）。此前是裸
    // `runes.length`：标点空白照计、英文按字母计，同一列 study_segments.chars
    // 里三种口径混着相加，跨媒体的每日目标与热力图本身就不成立。
    final int chars = countStudyChars(_pendingCueText);
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
