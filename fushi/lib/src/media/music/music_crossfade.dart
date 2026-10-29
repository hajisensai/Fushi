/// 交叉淡入（设计 §7.2「交叉淡入（可选，默认关；开了即非 bit-perfect，标注）」）：双 libmpv
/// 实例方案。
///
/// **增益在各自实例的滤镜链里按样本施加**，不靠 Dart 定时改音量（那样每次改都是一个增益
/// 台阶，会出拉链噪声）：每个曲目加载时由 mpv `on_load` 钩子设逐文件
/// `file-local-options/af`（[musicCrossfadeAf]），里面是两个带标签的 lavfi `afade`——
/// `@fushixfin`（淡入，只有交叉淡入进来的那一首是 `qsin`，其余是 `nofade`）与
/// `@fushixfout`（淡出，平时起点在 86400 s 即透传，排定交叉淡入时用 `af-command` 把起点
/// 改到曲尾）。两条曲线 `sin(πt/2)` / `cos(πt/2)`，平方和恒为 1（等功率）。`afade` 按帧
/// 时间戳算增益，每个文件（含 CUE 的 EDL 段）时间轴都从 0 开始；增益曲线从 0 起、到 0 止，
/// 所以无论两路起点在设备上差几毫秒，叠加后都没有阶跃（实测见
/// `test/media/music/music_crossfade_real_test.dart`）。
///
/// 逐文件设滤镜而不是改全局 `af`：全局滤镜在 gapless 下一首时间戳归零后会再淡入一次；
/// 逐文件选项在 gapless 播放列表里换文件时逐样本无缝（真 libmpv 实测）。
///
/// **交叉淡入关闭时什么都不装**（`af` 不碰），行为与没有本模块时逐样本一致。
///
/// 编排在 [MusicCrossfadeBackend]：对引擎仍是**一个** [MusicOutputBackend]（队列只在
/// Dart 引擎里一份）；曲目之间真有边界（[musicTransitionIsBoundary]）时，下一首不排进当前
/// 实例的 gapless 播放列表，而是在第二个实例里预加载（暂停），当前曲目出声到淡出起点时
/// 启动它并发 [MusicBackendAdvanced]；前一首在旧实例里按已排好的曲线淡出，播完即释放。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 交叉淡入此刻能不能用。
enum MusicCrossfadeAvailability {
  /// 设置里关着（时长 0）。
  off,

  /// 可用。
  available,

  /// 独占 / bit-perfect 输出：两个实例无法同时占设备，自动停用。
  disabledByExclusive,

  /// Linux ALSA 硬件设备直出（`alsa/hw:`）：同一设备只能被一个流打开，自动停用。
  disabledByDirectDevice,
}

/// 纯函数：输出设置 → 交叉淡入是否可用。独占按「请求了」判（退回共享时仍停用：用户要的是
/// bit-perfect，不该因为一次退回就悄悄混两路）。
MusicCrossfadeAvailability musicCrossfadeAvailability(
  MusicOutputSettings settings, {
  required MusicOutputPlatform platform,
}) {
  if (settings.crossfade <= Duration.zero) {
    return MusicCrossfadeAvailability.off;
  }
  if (settings.exclusive) return MusicCrossfadeAvailability.disabledByExclusive;
  if (platform == MusicOutputPlatform.linux &&
      settings.audioDevice.startsWith('alsa/hw:')) {
    return MusicCrossfadeAvailability.disabledByDirectDevice;
  }
  return MusicCrossfadeAvailability.available;
}

/// 纯函数：[from] → [to] 之间是否是真边界（否 = 本来就该无缝衔接，默认不淡入）。
///
/// * CUE 拆轨：同一整轨文件、下一段起点正好是上一段终点 → 连续。
/// * 同一专辑（`albumUid` 相同）：两边都有轨号时，同碟且轨号相邻 → 连续，否则（跳轨、
///   换碟）是边界；缺轨号时按播放语境——整张专辑顺序播（[albumOrder]）视为连续。
/// * 其余都是边界。
bool musicTransitionIsBoundary(
  MusicPlayItem from,
  MusicPlayItem to, {
  required bool albumOrder,
}) {
  if (from.path == to.path &&
      from.endMs != null &&
      to.startMs != null &&
      to.startMs == from.endMs) {
    return false;
  }
  final String? album = from.albumUid;
  if (album == null || album != to.albumUid) return true;
  final int? a = from.trackNo;
  final int? b = to.trackNo;
  if (a != null && b != null) {
    return !(from.discNo == to.discNo && b == a + 1);
  }
  return !albumOrder;
}

/// 纯函数：这一处衔接要不要交叉淡入。[includeContinuous] = 用户选了「连续曲目也淡入」。
bool musicTransitionCrossfades(
  MusicPlayItem from,
  MusicPlayItem to, {
  required bool albumOrder,
  required bool includeContinuous,
}) =>
    includeContinuous ||
    musicTransitionIsBoundary(from, to, albumOrder: albumOrder);

/// mpv 滤镜标签。
const String kMusicCrossfadeInLabel = 'fushixfin';
const String kMusicCrossfadeOutLabel = 'fushixfout';

/// 淡出「未排定」时的起点（秒）：远超任何曲目，`afade` 在起点前原样透传（逐样本不变）。
const double kMusicCrossfadeIdleStartSeconds = 86400;

String _secs(Duration d) => (d.inMicroseconds / 1e6).toStringAsFixed(6);

/// 纯函数：逐文件 `af`。[fadeIn] 为 0 = 不淡入（`nofade`，逐样本不变）。
///
/// [originSeconds]：这一首在文件时间轴上的起点。普通文件与 EDL 段从 0 起；音频 CD 曲目是
/// 整盘 `cdda://` 加 `start`，时间戳是盘时间，淡入要从这一首的起点算。
String musicCrossfadeAf({required Duration fadeIn, double originSeconds = 0}) {
  final bool inActive = fadeIn > Duration.zero;
  final String origin = originSeconds == 0
      ? '0'
      : originSeconds.toStringAsFixed(6);
  return '@$kMusicCrossfadeInLabel:lavfi=[afade=t=in:st=$origin:'
      'd=${inActive ? _secs(fadeIn) : '1'}:curve=${inActive ? 'qsin' : 'nofade'}],'
      '@$kMusicCrossfadeOutLabel:lavfi=[afade=t=out:'
      'st=${kMusicCrossfadeIdleStartSeconds.toStringAsFixed(0)}:d=1:curve=qsin]';
}

/// 纯函数：从 mpv `af` 里去掉本模块的两个滤镜（信号路径面板单独标「交叉淡入」，不把它
/// 算成用户滤镜）。
String musicStripCrossfadeFilters(String af) {
  final List<String> parts = <String>[];
  int depth = 0;
  final StringBuffer cur = StringBuffer();
  for (final int c in af.codeUnits) {
    final String ch = String.fromCharCode(c);
    if (ch == '[') depth++;
    if (ch == ']') depth--;
    if (ch == ',' && depth == 0) {
      parts.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  if (cur.isNotEmpty) parts.add(cur.toString());
  return parts
      .where(
        (String p) =>
            p.trim().isNotEmpty &&
            !p.trim().startsWith('@$kMusicCrossfadeInLabel:') &&
            !p.trim().startsWith('@$kMusicCrossfadeOutLabel:'),
      )
      .join(',');
}

/// 淡出结束到曲目真正结束之间留的余量（媒体时间）：时长估计（有损格式）差一两帧时，曲尾
/// 不会以非零增益被截断。
const Duration kMusicCrossfadeEndGuard = Duration(milliseconds: 50);

/// 交叉淡入太短就不做（< 200 ms 听起来只是一刀切）。
const Duration kMusicCrossfadeMinLength = Duration(milliseconds: 200);

/// 一次交叉淡入的时间参数（都是**媒体时间**：前一首的 [fadeStart]，两路共用 [fadeLength]）。
@immutable
class MusicCrossfadeTiming {
  const MusicCrossfadeTiming({
    required this.fadeStart,
    required this.fadeLength,
  });

  final Duration fadeStart;
  final Duration fadeLength;

  @override
  bool operator ==(Object other) =>
      other is MusicCrossfadeTiming &&
      other.fadeStart == fadeStart &&
      other.fadeLength == fadeLength;

  @override
  int get hashCode => Object.hash(fadeStart, fadeLength);

  @override
  String toString() =>
      'MusicCrossfadeTiming(start: $fadeStart, length: $fadeLength)';
}

/// 纯函数：前一首时长 [from]、下一首时长 [to]（未知可空）、设置时长 [crossfade]（墙钟）、
/// 速度 → 时间参数；不可行（太短）为 null。淡入淡出长度按墙钟设、换算成媒体时间乘速度；
/// 不超过任一首的 45%（下一首自己的下一次交叉淡入不会和这次重叠）。
MusicCrossfadeTiming? musicCrossfadeTiming({
  required Duration from,
  required Duration? to,
  required Duration crossfade,
  required double speed,
}) {
  if (crossfade <= Duration.zero) return null;
  final double s = speed <= 0 ? 1 : speed;
  int us = (crossfade.inMicroseconds * s).round();
  us = math.min(us, (from.inMicroseconds * 0.45).round());
  if (to != null) us = math.min(us, (to.inMicroseconds * 0.45).round());
  final Duration length = Duration(microseconds: us);
  if (length < kMusicCrossfadeMinLength) return null;
  final Duration start = from - kMusicCrossfadeEndGuard - length;
  if (start <= Duration.zero) return null;
  return MusicCrossfadeTiming(fadeStart: start, fadeLength: length);
}

/// 交叉淡入要求单个输出实例额外提供的能力（[MpvMusicOutputBackend] 实现；测试给替身）。
abstract interface class MusicCrossfadeInstance implements MusicOutputBackend {
  /// 之后加载的每个文件都装 [musicCrossfadeAf] 滤镜（关 = 什么都不装）。
  set crossfadeFiltersEnabled(bool value);

  /// 作为交叉淡入的「下一首」预加载（暂停）：它加载时淡入 [fadeIn]（媒体时间）。
  Future<void> openIncoming(MusicPlayItem item, {required Duration fadeIn});

  /// 正在出声的曲目加载时装了交叉淡入滤镜。
  bool get audibleHasCrossfadeFilters;

  /// 正在出声的曲目的媒体时长（mpv `duration`；CUE 段 = 段长）；未知为 null。
  Duration? get audibleMediaDuration;

  /// 解码器已切到 gapless 下一首、前一首尾巴还在出声（切换期）。
  bool get advancePending;

  /// 给正在出声的曲目排淡出：媒体时间 [start] 起、长 [length]。
  Future<void> armFadeOut({required Duration start, required Duration length});

  /// 撤销淡出（起点挪回 [kMusicCrossfadeIdleStartSeconds]）。
  Future<void> disarmFadeOut();

  /// 每个 `audio-pts` 采样（正在出声的曲目、非切换期；秒，媒体时间）。
  set onAudiblePts(void Function(double pts)? callback);
}

/// 墙钟（微秒），可注入。
typedef MusicClock = int Function();

final Stopwatch _kMonotonic = Stopwatch()..start();
int _monotonicMicros() => _kMonotonic.elapsedMicroseconds;

/// 一次已排定、还没开始的交叉淡入。
class _Plan {
  _Plan(this.next);

  MusicPlayItem next;
  MusicCrossfadeTiming? timing;

  /// 前一首的淡出已排进滤镜。
  bool armed = false;
  bool arming = false;

  /// 预加载在途。
  bool preloading = false;

  /// 预加载完成后立刻启动（到点时还没加载完）。
  bool startWhenReady = false;
}

/// 双实例交叉淡入后端。交叉淡入不可用（关 / 独占 / 硬件直出）时只有一个实例，所有调用
/// 原样转给它——与单实例后端逐调用一致。
class MusicCrossfadeBackend implements MusicOutputBackend {
  MusicCrossfadeBackend({
    required MusicCrossfadeInstance Function() instanceFactory,
    required MusicOutputPlatform platform,
    MusicClock? clock,
  }) : _factory = instanceFactory,
       _platform = platform,
       _clock = clock ?? _monotonicMicros;

  /// 排淡出的最晚时机（墙钟）：解码器比出声超前约 0.4 s（mpv 缓冲 + 设备缓冲，实测），
  /// 留到 1 s，过了这个点滤镜里的淡出已经（可能）被解码过，不能再改。
  static const Duration kLockLead = Duration(seconds: 1);

  /// 下一首提前多久在第二个实例里预加载（墙钟）。
  static const Duration kPreloadLead = Duration(seconds: 5);

  /// 离起点多近时改用精确定时器启动（墙钟）；`audio-pts` 采样只有约 10–20 Hz。
  static const Duration kPreciseWindow = Duration(milliseconds: 600);

  final MusicCrossfadeInstance Function() _factory;
  final MusicOutputPlatform _platform;
  final MusicClock _clock;

  final StreamController<MusicBackendEvent> _events =
      StreamController<MusicBackendEvent>.broadcast();

  MusicOutputSettings _settings = const MusicOutputSettings(
    gapless: true,
    replayGain: MusicReplayGainMode.off,
  );

  MusicCrossfadeInstance? _primary;
  MusicCrossfadeInstance? _incoming;
  MusicCrossfadeInstance? _outgoing;
  final Map<MusicCrossfadeInstance, StreamSubscription<MusicBackendEvent>>
  _subs = <MusicCrossfadeInstance, StreamSubscription<MusicBackendEvent>>{};

  _Plan? _plan;
  Timer? _startTimer;
  double? _lastPts;
  bool _primaryPlaying = false;

  /// 前一首已放完、预加载完成后启动时直接释放它（[_Plan.startWhenReady] 路径）。
  bool _previousEnded = false;

  /// 前一首播完时要接着开的下一首（交叉淡入半路被取消，例如开了独占）。
  MusicPlayItem? _handoff;

  /// 重叠期两路的 `audio-pts` 采样（对齐诊断）。
  final List<(int, double)> _overlapOut = <(int, double)>[];
  final List<(int, double)> _overlapIn = <(int, double)>[];
  Duration? _overlapFadeStart;
  Duration? _overlapFadeLength;
  List<double> _lastOverlapOffsetsMs = const <double>[];

  /// 启动补偿（微秒）：后一首比理想时刻晚出声的量（设备起播延迟，WASAPI 共享实测稳定在
  /// 约 20 ms），由上一次完整重叠的对齐中位数学出来，下一次提前这么多启动。
  int _startLeadUs = 0;

  /// 补偿上限：再大说明测量本身不可信，不跟。
  static const int _kMaxStartLeadUs = 100000;

  @override
  Stream<MusicBackendEvent> get events => _events.stream;

  bool get _enabled =>
      musicCrossfadeAvailability(_settings, platform: _platform) ==
      MusicCrossfadeAvailability.available;

  double get _speed => _settings.speed <= 0 ? 1 : _settings.speed;

  /// 测试 / 诊断：此刻活着的实例数。
  @visibleForTesting
  int get debugInstanceCount => <MusicCrossfadeInstance?>[
    _primary,
    _incoming,
    _outgoing,
  ].whereType<MusicCrossfadeInstance>().length;

  /// 测试 / 诊断：重叠期（前一首仍在淡出）。
  @visibleForTesting
  bool get debugOverlapping => _outgoing != null;

  /// 测试 / 诊断：已排定的交叉淡入（时间参数）。
  @visibleForTesting
  MusicCrossfadeTiming? get debugPlannedTiming => _plan?.timing;

  /// 测试 / 诊断：最近一次已启动的交叉淡入的时间参数。
  @visibleForTesting
  MusicCrossfadeTiming? get debugLastStartedTiming => _overlapFadeStart == null
      ? null
      : MusicCrossfadeTiming(
          fadeStart: _overlapFadeStart!,
          fadeLength: _overlapFadeLength ?? Duration.zero,
        );

  /// 测试 / 诊断：最近一次重叠期两路的对齐误差（毫秒，正 = 后一首晚于理想时刻）。
  @visibleForTesting
  List<double> get debugLastOverlapOffsetsMs => _lastOverlapOffsetsMs;

  /// 测试：不等 `audio-pts`（`ao=pcm` 这种非实时输出不发），按出声位置 [pts] 立刻排淡出。
  @visibleForTesting
  Future<void> debugArmAt(double pts) async {
    final _Plan? plan = _plan;
    if (plan != null && !plan.armed) await _arm(plan, pts);
  }

  void _emit(MusicBackendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  MusicCrossfadeInstance _create() {
    final MusicCrossfadeInstance inst = _factory();
    _subs[inst] = inst.events.listen(
      (MusicBackendEvent e) => _onInstanceEvent(inst, e),
    );
    return inst;
  }

  Future<void> _disposeInstance(MusicCrossfadeInstance? inst) async {
    if (inst == null) return;
    inst.onAudiblePts = null;
    await _subs.remove(inst)?.cancel();
    await inst.dispose();
  }

  MusicCrossfadeInstance _ensurePrimary() {
    final MusicCrossfadeInstance? existing = _primary;
    if (existing != null) return existing;
    final MusicCrossfadeInstance created = _create();
    created.onAudiblePts = _onPrimaryPts;
    _primary = created;
    return created;
  }

  // ── 事件路由：对外只有「当前出声」那一个实例 ──────────────────────────────────

  void _onInstanceEvent(MusicCrossfadeInstance inst, MusicBackendEvent e) {
    if (identical(inst, _primary)) {
      switch (e) {
        case MusicBackendPlaying(:final bool playing):
          _primaryPlaying = playing;
          if (!playing) {
            _startTimer?.cancel();
            _startTimer = null;
          }
          _emit(e);
        case MusicBackendCompleted():
          // 前一首在交叉淡入启动前就放完了（到点时暂停 / 采样太稀 / 预加载失败）：立刻接上。
          if (_plan != null || _handoff != null) {
            unawaited(_startIncomingAfterEnd());
            return;
          }
          _emit(e);
        case MusicBackendPosition():
        case MusicBackendAdvanced():
        case MusicBackendOutputFallback():
        case MusicBackendFailed():
          _emit(e);
      }
      return;
    }
    if (identical(inst, _outgoing)) {
      if (e is MusicBackendCompleted) unawaited(_finishOverlap());
      if (e is MusicBackendOutputFallback) _emit(e);
      return;
    }
    if (identical(inst, _incoming)) {
      if (e is MusicBackendFailed) {
        // 预加载失败：丢掉它，前一首放完时在主实例里直接开下一首（不淡入）。这里不上报——
        // 那次重开若仍失败会由主实例报（届时它才是该出声的那一首）；现在报会让引擎把
        // 「下一首」的失败当成正在放的这首。
        _dropIncomingForHandoff(inst);
      }
    }
  }

  void _dropIncomingForHandoff(MusicCrossfadeInstance failed) {
    if (identical(_incoming, failed)) _incoming = null;
    final _Plan? plan = _plan;
    if (plan != null) {
      _handoff = plan.next;
      _plan = null;
    }
    unawaited(_disposeInstance(failed));
  }

  // ── 调度 ────────────────────────────────────────────────────────────────

  void _onPrimaryPts(double pts) {
    _lastPts = pts;
    if (_outgoing != null) _overlapIn.add((_clock(), pts));
    final _Plan? plan = _plan;
    if (plan == null) return;
    if (!plan.armed) {
      if (!plan.arming) unawaited(_arm(plan, pts));
      return;
    }
    final MusicCrossfadeTiming timing = plan.timing!;
    final double startS = timing.fadeStart.inMicroseconds / 1e6;
    final double remainingWallS = (startS - pts) / _speed - _startLeadUs / 1e6;
    if (_incoming == null &&
        !plan.preloading &&
        remainingWallS <= kPreloadLead.inMicroseconds / 1e6) {
      unawaited(_preload(plan));
    }
    if (remainingWallS <= 0) {
      unawaited(_startIncoming());
    } else if (_primaryPlaying &&
        remainingWallS <= kPreciseWindow.inMicroseconds / 1e6) {
      _startTimer?.cancel();
      _startTimer = Timer(
        Duration(microseconds: (remainingWallS * 1e6).round()),
        () => unawaited(_startIncoming()),
      );
    }
  }

  /// 排前一首的淡出；排不了（没装滤镜 / 时长未知 / 太短 / 太晚）就退回 gapless。
  Future<void> _arm(_Plan plan, double pts) async {
    final MusicCrossfadeInstance? primary = _primary;
    if (primary == null) return;
    plan.arming = true;
    try {
      final Duration? from = primary.audibleMediaDuration;
      final MusicCrossfadeTiming? timing =
          !primary.audibleHasCrossfadeFilters ||
              primary.advancePending ||
              from == null
          ? null
          : musicCrossfadeTiming(
              from: from,
              to: plan.next.durationMs == null
                  ? null
                  : Duration(milliseconds: plan.next.durationMs!),
              crossfade: _settings.crossfade,
              speed: _speed,
            );
      final double lockS = kLockLead.inMicroseconds / 1e6 * _speed;
      if (timing == null ||
          pts + lockS >= timing.fadeStart.inMicroseconds / 1e6) {
        // 退回：下一首照常排进主实例的 gapless 播放列表。
        if (identical(_plan, plan)) _plan = null;
        await primary.replaceNext(plan.next);
        return;
      }
      await primary.armFadeOut(
        start: timing.fadeStart,
        length: timing.fadeLength,
      );
      plan.timing = timing;
      plan.armed = true;
    } finally {
      plan.arming = false;
    }
  }

  /// 已排的淡出能否撤销（解码器还没走到淡出起点前的锁定线）。
  bool _canDisarm(_Plan plan) {
    final MusicCrossfadeTiming? timing = plan.timing;
    if (!plan.armed || timing == null) return true;
    final double? pts = _lastPts;
    if (pts == null) return true;
    final double lockS = kLockLead.inMicroseconds / 1e6 * _speed;
    return pts + lockS < timing.fadeStart.inMicroseconds / 1e6;
  }

  Future<void> _preload(_Plan plan) async {
    plan.preloading = true;
    final MusicCrossfadeInstance inst = _create();
    inst.crossfadeFiltersEnabled = true;
    await inst.applySettings(_settings);
    try {
      await inst.openIncoming(plan.next, fadeIn: plan.timing!.fadeLength);
    } on MusicTrackOpenException {
      // 下一首取流失败：同上，前一首放完时在主实例里再开一次（仍失败由主实例报）。
      if (identical(_plan, plan)) {
        _dropIncomingForHandoff(inst);
      } else {
        await _disposeInstance(inst);
      }
      return;
    }
    if (!identical(_plan, plan) || _incoming != null) {
      await _disposeInstance(inst);
      return;
    }
    _incoming = inst;
    if (plan.startWhenReady) await _startIncoming();
  }

  /// 启动预加载好的下一首。[previousEnded] = 前一首已经放完（不再进入重叠期，直接释放）。
  Future<void> _startIncoming({bool previousEnded = false}) async {
    _startTimer?.cancel();
    _startTimer = null;
    final _Plan? plan = _plan;
    if (plan == null) return;
    if (previousEnded) _previousEnded = true;
    final MusicCrossfadeInstance? incoming = _incoming;
    if (incoming == null) {
      plan.startWhenReady = true;
      if (!plan.preloading && plan.timing != null) unawaited(_preload(plan));
      return;
    }
    _plan = null;
    _incoming = null;
    final MusicCrossfadeInstance? old = _primary;
    // 上一次重叠还没收尾（极短曲目）：它此时已淡到 0，启动后直接释放。
    final MusicCrossfadeInstance? stale = _outgoing;
    final bool ended = _previousEnded;
    _previousEnded = false;
    _primary = incoming;
    _outgoing = ended ? null : old;
    if (!ended) {
      old?.onAudiblePts = (double pts) => _overlapOut.add((_clock(), pts));
    }
    incoming.onAudiblePts = _onPrimaryPts;
    _overlapOut.clear();
    _overlapIn.clear();
    _overlapFadeStart = plan.timing?.fadeStart;
    _overlapFadeLength = plan.timing?.fadeLength;
    _lastPts = null;
    _primaryPlaying = true;
    // 先启动（对齐只看这一下），收尾放后面。
    await incoming.play();
    _emit(MusicBackendAdvanced(plan.next.trackUid));
    await _disposeInstance(stale);
    if (ended) await _disposeInstance(old);
  }

  /// 前一首放完而交叉淡入还没启动：直接接上（前一首已淡到 0 或被取消了淡入）。
  Future<void> _startIncomingAfterEnd() async {
    final MusicPlayItem? handoff = _handoff;
    if (handoff != null) {
      _handoff = null;
      await _openAfterEnd(handoff);
      return;
    }
    final _Plan? plan = _plan;
    if (plan == null) return;
    if (plan.timing == null) {
      // 还没排上淡出就放完了（极短曲目）：在主实例里直接开下一首。
      _plan = null;
      await _openAfterEnd(plan.next);
      return;
    }
    await _startIncoming(previousEnded: true);
  }

  /// 前一首放完后在主实例里直接开 [item]，当作自然推进上报。打不开（取流失败）时报
  /// **这一首**的失败（引擎据 trackUid 推进到它并按失败处理），不发推进。被更晚的
  /// [openPair] 作废时什么都不报。
  Future<void> _openAfterEnd(MusicPlayItem item) async {
    final int gen = _openGen;
    final MusicCrossfadeInstance primary = _ensurePrimary();
    try {
      await primary.openPair(item, null, play: true);
    } on MusicTrackOpenException catch (e) {
      if (gen == _openGen) _emit(e.failure);
      return;
    }
    if (gen != _openGen) return;
    _emit(MusicBackendAdvanced(item.trackUid));
  }

  Future<void> _finishOverlap() async {
    final MusicCrossfadeInstance? out = _outgoing;
    _outgoing = null;
    _lastOverlapOffsetsMs = _alignmentOffsetsMs();
    // 只从完整走完的重叠学补偿（被用户操作打断的那次样本太少）。
    if (_lastOverlapOffsetsMs.length >= 5) {
      final List<double> sorted = List<double>.of(_lastOverlapOffsetsMs)
        ..sort();
      final double medianMs = sorted[sorted.length ~/ 2];
      _startLeadUs = (_startLeadUs + medianMs * 1000).round().clamp(
        0,
        _kMaxStartLeadUs,
      );
    }
    await _disposeInstance(out);
  }

  /// 测试 / 诊断：当前的启动补偿。
  @visibleForTesting
  Duration get debugStartLead => Duration(microseconds: _startLeadUs);

  /// 重叠期内，每个后一首采样时刻用前一首相邻两采样线性插值，比「前一首超过淡出起点的量」
  /// 与「后一首的位置」之差。
  List<double> _alignmentOffsetsMs() {
    final Duration? start = _overlapFadeStart;
    if (start == null || _overlapOut.length < 2) return const <double>[];
    final double startS = start.inMicroseconds / 1e6;
    final List<double> out = <double>[];
    for (final (int at, double vb) in _overlapIn) {
      if (vb <= 0.02) continue;
      (int, double)? lo;
      (int, double)? hi;
      for (final (int x, double y) in _overlapOut) {
        if (x <= at) lo = (x, y);
        if (x >= at) {
          hi = (x, y);
          break;
        }
      }
      if (lo == null || hi == null) continue;
      final double va = hi.$1 == lo.$1
          ? lo.$2
          : lo.$2 + (hi.$2 - lo.$2) * (at - lo.$1) / (hi.$1 - lo.$1);
      out.add(((va - startS) - vb) / _speed * 1000);
    }
    return out;
  }

  /// 结束重叠：前一首立即停止（用户操作 seek / 暂停 / 跳曲 / 变速 / 改输出时）。当前曲目
  /// 按原淡入曲线继续升到全增益（不跳增益，免得出台阶）。
  Future<void> _collapse() async {
    final MusicCrossfadeInstance? out = _outgoing;
    if (out == null) return;
    _outgoing = null;
    _lastOverlapOffsetsMs = _alignmentOffsetsMs();
    await _disposeInstance(out);
  }

  /// 丢掉还没开始的交叉淡入。[disarm] = 能撤就撤前一首的淡出。
  Future<void> _dropPlan({required bool disarm}) async {
    _startTimer?.cancel();
    _startTimer = null;
    final _Plan? plan = _plan;
    _plan = null;
    final MusicCrossfadeInstance? incoming = _incoming;
    _incoming = null;
    await _disposeInstance(incoming);
    if (disarm && plan != null && plan.armed) await _primary?.disarmFadeOut();
  }

  // ── MusicOutputBackend ───────────────────────────────────────────────────

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {
    final MusicOutputSettings prev = _settings;
    _settings = settings;
    final bool enabled = _enabled;
    final bool outputChanged =
        prev.speed != settings.speed ||
        prev.exclusive != settings.exclusive ||
        prev.audioDevice != settings.audioDevice;
    if (outputChanged || !enabled) await _collapse();
    final _Plan? plan = _plan;
    if (plan != null) {
      if (!enabled || outputChanged) {
        if (_canDisarm(plan)) {
          await _dropPlan(disarm: true);
          if (_primary != null) await _primary!.replaceNext(plan.next);
        } else {
          // 淡出已锁定：前一首照常淡出到结束，然后在主实例里直接开下一首。
          await _dropPlan(disarm: false);
          _handoff = plan.next;
        }
      } else if (prev.crossfade != settings.crossfade && _canDisarm(plan)) {
        // 时长改了：重新排（下一个采样按新时长排）。
        if (plan.armed) await _primary?.disarmFadeOut();
        final MusicCrossfadeInstance? incoming = _incoming;
        _incoming = null;
        await _disposeInstance(incoming);
        plan
          ..armed = false
          ..timing = null
          ..preloading = false
          ..startWhenReady = false;
      }
    }
    final MusicCrossfadeInstance primary = _ensurePrimary();
    primary.crossfadeFiltersEnabled = enabled;
    await primary.applySettings(settings);
    final MusicCrossfadeInstance? incoming = _incoming;
    if (incoming != null) await incoming.applySettings(settings);
    final MusicCrossfadeInstance? out = _outgoing;
    if (out != null) await out.applySettings(settings);
  }

  /// 打开代次：每次 [openPair] / [stop] 加一。主实例取流期间又来了一次打开，前一次回来后
  /// 不再排交叉淡入计划（那会把旧队列的「下一首」挂到新曲目后面）。
  int _openGen = 0;

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async {
    final int gen = ++_openGen;
    await _collapse();
    await _dropPlan(disarm: false);
    if (gen != _openGen) return;
    _handoff = null;
    _lastPts = null;
    final MusicCrossfadeInstance primary = _ensurePrimary();
    final bool enabled = _enabled;
    primary.crossfadeFiltersEnabled = enabled;
    if (enabled && crossfadeNext && next != null) {
      await primary.openPair(current, null, play: play);
      if (gen != _openGen) return;
      _plan = _Plan(next);
    } else {
      await primary.openPair(current, next, play: play);
    }
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {
    final MusicCrossfadeInstance primary = _ensurePrimary();
    final _Plan? plan = _plan;
    _handoff = null;
    if (plan != null && !_canDisarm(plan)) {
      // 淡出已锁定：这次衔接仍按交叉淡入，只换「下一首」是谁（或取消 = 淡出后停）。
      if (next == null) {
        await _dropPlan(disarm: false);
        return;
      }
      if (next == plan.next) return;
      plan.next = next;
      final MusicCrossfadeInstance? incoming = _incoming;
      _incoming = null;
      plan
        ..preloading = false
        ..startWhenReady = false;
      await _disposeInstance(incoming);
      return;
    }
    if (plan != null) await _dropPlan(disarm: true);
    if (_enabled && crossfadeNext && next != null && !primary.advancePending) {
      await primary.replaceNext(null);
      final _Plan created = _Plan(next);
      _plan = created;
      final double? pts = _lastPts;
      if (pts != null) await _arm(created, pts);
    } else {
      await primary.replaceNext(next);
    }
  }

  @override
  Future<void> play() async => _primary?.play();

  @override
  Future<void> pause() async {
    await _collapse();
    _startTimer?.cancel();
    _startTimer = null;
    await _primary?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _collapse();
    _startTimer?.cancel();
    _startTimer = null;
    final _Plan? plan = _plan;
    if (plan != null) {
      // 预加载按新位置重新算（可能离曲尾远了）。
      final MusicCrossfadeInstance? incoming = _incoming;
      _incoming = null;
      plan
        ..preloading = false
        ..startWhenReady = false;
      await _disposeInstance(incoming);
    }
    _lastPts = null;
    await _primary?.seek(position);
  }

  /// AB 循环只作用在出声的主实例上；换曲目时引擎显式关（新主实例收到的就是「关」）。
  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async =>
      _primary?.setAbLoop(a, b);

  @override
  Future<void> stop() async {
    _openGen++;
    await _collapse();
    await _dropPlan(disarm: false);
    _handoff = null;
    await _primary?.stop();
  }

  @override
  Future<void> dispose() async {
    _startTimer?.cancel();
    _plan = null;
    _handoff = null;
    final List<MusicCrossfadeInstance?> all = <MusicCrossfadeInstance?>[
      _outgoing,
      _incoming,
      _primary,
    ];
    _outgoing = null;
    _incoming = null;
    _primary = null;
    for (final MusicCrossfadeInstance? i in all) {
      await _disposeInstance(i);
    }
    await _events.close();
  }

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async =>
      _primary?.readSignalPath();

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      _ensurePrimary().listAudioDevices();
}
