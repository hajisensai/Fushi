import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/video/audio_energy_probe.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 字幕对轴**人工波形视图**的分段懒加载（反馈 EUvw-RjUE4）。
///
/// 自动对轴只看前 N 分钟（[subtitleAlignProbeLimitMs]），那是互相关求整体平移的性能
/// 截断；人工查看的波形视图历史上沿用了这个上界——时间窗 = min(片长, 20 分钟)、包络
/// 也只抽前 20 分钟，24 分钟的一集在 20:00 之后没有波形、也拖不过去。两件事在这里
/// 拆开：视图时间窗恒为片长全程，包络按 [kSubtitleWaveformSegmentMs] 一段一段抽，
/// **视口滚到哪段才抽哪段**（流音源因此也不会一打开就把整集拉下来），已抽段缓存。
///
/// **相位一致（按段成立）**：段边界都是 [kSubtitleWaveformSegmentMs] 的整数倍，而段长
/// 是逐帧窗口 [kSubtitleWaveformWindowMs]（以及自动对轴 bin 100ms）的整数倍，所以第
/// i 段第 k 帧的起点恰为全局第 `i*段帧数+k` 帧的起点——各段从自己的起点同窗口起抽，
/// 拼起来与「从 t=0 一次抽整轨」逐帧同相位，段与段之间不错位。
///
/// 纯函数（段划分 / 帧数 / 拼接）无 IO，可单测；[SubtitleWaveformSegments] 只管
/// 「哪段在抽 / 抽完了 / 抽空了」的状态与串行调度，真正的抽取由调用方注入。

/// 人工波形视图每段的时长（毫秒）：2 分钟。
///
/// 本地文件一段 2 分钟 @20ms 约 6000 帧，桌面 ffmpeg 半秒级；流音源一段只拉 2 分钟
/// 音频，视口所在段先出、其余按需。视口在最低缩放下也只覆盖半分钟左右，一段足够铺满。
/// 必须是 [kSubtitleWaveformWindowMs] 与 [kAudioEnergyWindowMs] 的整数倍（见文件头）。
const int kSubtitleWaveformSegmentMs = 2 * 60 * 1000;

/// 尚未抽到（或该段抽不出音频）的帧在拼接包络里的填充值（dB）：与
/// [parseAudioRmsEnvelopeFromFfmpegLog] 的静音值同，画出来贴地、不参与成峰。
const double kSubtitleWaveformUnloadedDb = -120.0;

/// 抽取一段 `[startMs, endMs)` 的逐帧 RMS 包络（dB）。空列表 = 该段抽不出。
typedef SubtitleWaveformSegmentLoader =
    Future<List<double>> Function(int startMs, int endMs);

/// 一段的时间范围 `[startMs, endMs)`（毫秒）。
@immutable
class WaveformSegmentRange {
  const WaveformSegmentRange(this.startMs, this.endMs);

  final int startMs;
  final int endMs;

  int get spanMs => endMs - startMs;

  @override
  bool operator ==(Object other) =>
      other is WaveformSegmentRange &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() => 'WaveformSegmentRange($startMs, $endMs)';
}

/// **纯函数**：人工波形视图的时间窗上界（毫秒）。片长已知取片长全程（**不**再与自动
/// 对轴的探测上界取 min）；片长未知（<=0）时用 [cues] 里最晚的结束时间兜底，仍未知
/// 返回 0（无可画时间轴）。
int subtitleWaveformWindowEndMs({
  required int durationMs,
  required List<AudioCue> cues,
}) {
  if (durationMs > 0) return durationMs;
  int latest = 0;
  for (final AudioCue cue in cues) {
    if (cue.endMs > latest) latest = cue.endMs;
  }
  return latest;
}

/// **纯函数**：[durationMs] 按 [segmentMs] 切成几段（末段可不满）。<=0 返回 0。
int waveformSegmentCount(
  int durationMs, {
  int segmentMs = kSubtitleWaveformSegmentMs,
}) {
  if (durationMs <= 0 || segmentMs <= 0) return 0;
  return (durationMs + segmentMs - 1) ~/ segmentMs;
}

/// **纯函数**：第 [index] 段的时间范围。末段收尾到 [durationMs]。
WaveformSegmentRange waveformSegmentRange(
  int index, {
  required int durationMs,
  int segmentMs = kSubtitleWaveformSegmentMs,
}) {
  final int start = index * segmentMs;
  final int end = start + segmentMs;
  return WaveformSegmentRange(start, end > durationMs ? durationMs : end);
}

/// **纯函数**：[timeMs] 落在第几段（clamp 到 `[0, 段数-1]`）。无段返回 -1。
int waveformSegmentIndexAt(
  int timeMs, {
  required int durationMs,
  int segmentMs = kSubtitleWaveformSegmentMs,
}) {
  final int count = waveformSegmentCount(durationMs, segmentMs: segmentMs);
  if (count == 0) return -1;
  if (timeMs <= 0) return 0;
  final int idx = timeMs ~/ segmentMs;
  return idx >= count ? count - 1 : idx;
}

/// **纯函数**：与 `[startMs, endMs)` 相交的段下标，按离区间中点由近到远排序（视口
/// 中间那段最先抽），同距按下标升序。区间先 clamp 到 `[0, durationMs)`；空区间返回空列表。
List<int> waveformSegmentsOverlapping({
  required int startMs,
  required int endMs,
  required int durationMs,
  int segmentMs = kSubtitleWaveformSegmentMs,
}) {
  final int count = waveformSegmentCount(durationMs, segmentMs: segmentMs);
  if (count == 0) return const <int>[];
  final int lo = startMs < 0 ? 0 : startMs;
  final int hi = endMs > durationMs ? durationMs : endMs;
  if (hi <= lo) return const <int>[];
  final int first = lo ~/ segmentMs;
  final int lastRaw = (hi - 1) ~/ segmentMs;
  final int last = lastRaw >= count ? count - 1 : lastRaw;
  final double center = (lo + hi) / 2;
  double distance(int i) {
    final WaveformSegmentRange r = waveformSegmentRange(
      i,
      durationMs: durationMs,
      segmentMs: segmentMs,
    );
    if (center < r.startMs) return r.startMs - center;
    if (center >= r.endMs) return center - r.endMs;
    return 0;
  }

  final List<int> out = <int>[for (int i = first; i <= last; i++) i];
  out.sort((int a, int b) {
    final int byDistance = distance(a).compareTo(distance(b));
    return byDistance != 0 ? byDistance : a.compareTo(b);
  });
  return out;
}

/// **纯函数**：[spanMs] 毫秒按 [frameMs] 一帧有几帧（末帧不满也算一帧）。
int waveformFrameCount(int spanMs, int frameMs) {
  if (spanMs <= 0 || frameMs <= 0) return 0;
  return (spanMs + frameMs - 1) ~/ frameMs;
}

/// **纯函数**：把一段抽回来的逐帧包络对齐到该段应有的帧数 [expected]。
///
/// ffmpeg 输入端 `-ss`/`-t` 截断后帧数恰为段长 / 窗口（见 [buildFfmpegPcmEnvelopeArgs]
/// 的 `-t` 文档），这里是防御：多一两帧（末段解码尾巴）或少一两帧（音轨比视频短）时按
/// 最近邻均匀映射到 [expected] 帧——与历史「整条包络均匀铺满时间窗」同一语义，只是
/// 现在按段成立，误差不会跨段累积。[frames] 空返回空列表（该段抽不出）。
List<double> fitWaveformSegmentFrames(List<double> frames, int expected) {
  if (frames.isEmpty || expected <= 0) return const <double>[];
  final int n = frames.length;
  if (n == expected) return frames;
  return List<double>.generate(
    expected,
    (int i) => frames[(i * n) ~/ expected],
  );
}

/// **纯函数**：把已抽到的各段（下标 -> 该段逐帧 dB）拼成覆盖 `[0, durationMs)` 的整条
/// 逐帧包络，第 j 帧对应时间 `j * frameMs`。未抽到 / 抽空的段填 [fillDb]。
///
/// [segmentMs] 必须是 [frameMs] 的整数倍（段内帧与全局帧同相位，见文件头）。
List<double> stitchWaveformSegments({
  required int durationMs,
  required Map<int, List<double>> segments,
  int segmentMs = kSubtitleWaveformSegmentMs,
  int frameMs = kSubtitleWaveformWindowMs,
  double fillDb = kSubtitleWaveformUnloadedDb,
}) {
  assert(segmentMs % frameMs == 0, 'segmentMs must be a multiple of frameMs');
  final int total = waveformFrameCount(durationMs, frameMs);
  if (total == 0) return const <double>[];
  final List<double> out = List<double>.filled(total, fillDb);
  final int framesPerSegment = segmentMs ~/ frameMs;
  final int count = waveformSegmentCount(durationMs, segmentMs: segmentMs);
  for (final MapEntry<int, List<double>> entry in segments.entries) {
    final int index = entry.key;
    if (index < 0 || index >= count) continue;
    final WaveformSegmentRange range = waveformSegmentRange(
      index,
      durationMs: durationMs,
      segmentMs: segmentMs,
    );
    final List<double> fitted = fitWaveformSegmentFrames(
      entry.value,
      waveformFrameCount(range.spanMs, frameMs),
    );
    final int offset = index * framesPerSegment;
    for (int k = 0; k < fitted.length && offset + k < total; k++) {
      out[offset + k] = fitted[k];
    }
  }
  return out;
}

/// 波形归一化上限分位（与 [downsampleEnergyEnvelope] 的默认值同）：以第 99 分位桶峰值为满幅，
/// 单个响亮瞬态不把整段语音压扁。
const double kSubtitleWaveformCeilingPercentile = 0.99;

/// **纯函数**：只抽到一部分段时，传给降采样的归一化上限分位。
///
/// 拼接包络里未抽到的段是静音填充，它们的桶峰值全落在最底部；若仍取第 99 分位，上限会
/// 落进已抽段的前 `1% / 已抽比例`（只抽了 1/12 时是前 12%），已抽段的响段被大面积削顶，
/// 且每抽完一段整条波形的增益都跳一下。按已抽比例 [loadedFraction] 把「顶部 1%」换算回
/// 全体桶：`1 - (1 - base) * loadedFraction`，上限恒为已抽段内的第 99 分位。全抽完时
/// 等于 [base]；一段没抽到（0）时为 1（取最大值，全静音时归一化退化为全 0）。
double waveformCeilingPercentile(
  double loadedFraction, {
  double base = kSubtitleWaveformCeilingPercentile,
}) {
  final double f = loadedFraction.isNaN
      ? 0
      : loadedFraction.clamp(0.0, 1.0).toDouble();
  return 1 - (1 - base) * f;
}

/// 一段的加载状态。
enum WaveformSegmentState {
  /// 还没请求。
  idle,

  /// 排队中或正在抽。
  loading,

  /// 抽到了非空包络。
  ready,

  /// 抽完但为空 / 抽取抛错（无音轨、ffmpeg 不可用、超时、音轨比视频短）。视口驱动的
  /// [SubtitleWaveformSegments.ensureRange] 不自动重试（否则失败段会被每帧重新触发），
  /// 显式 [SubtitleWaveformSegments.ensureSegment] 会重试。
  empty,
}

/// 波形视图一次打开的分段状态与串行调度（生命周期 = 对轴弹窗，由打开方 dispose；跨次
/// 打开的秒开靠注入的 [SubtitleWaveformSegmentLoader] 背后的页面级缓存）。
///
/// **串行**：同一时刻只抽一段（本地是一个 ffmpeg 子进程、流是一路 HTTP 读），视口外的
/// 排队请求在视口移走时撤销——快速拖过整集不会堆出一串 ffmpeg、也不会把整集拉下来。
class SubtitleWaveformSegments extends ChangeNotifier {
  SubtitleWaveformSegments({
    required this.durationMs,
    required SubtitleWaveformSegmentLoader loadSegment,
    this.segmentMs = kSubtitleWaveformSegmentMs,
    this.frameMs = kSubtitleWaveformWindowMs,
  }) : assert(segmentMs % frameMs == 0),
       _loadSegment = loadSegment;

  /// 视图时间窗上界（毫秒）= 片长全程。
  final int durationMs;
  final int segmentMs;
  final int frameMs;
  final SubtitleWaveformSegmentLoader _loadSegment;

  final Map<int, List<double>> _frames = <int, List<double>>{};
  final Set<int> _empty = <int>{};

  /// 已请求、尚未完成的段 -> 完成器（排队的与正在抽的都在这里）。
  final Map<int, Completer<bool>> _pending = <int, Completer<bool>>{};

  /// 排队顺序（不含正在抽的那段）。
  final List<int> _queue = <int>[];

  /// 显式请求（[ensureSegment]）的段：视口移走也不撤销。
  final Set<int> _explicit = <int>{};

  int? _active;
  List<double>? _stitched;
  bool _disposed = false;

  int get segmentCount =>
      waveformSegmentCount(durationMs, segmentMs: segmentMs);

  WaveformSegmentRange rangeOf(int index) =>
      waveformSegmentRange(index, durationMs: durationMs, segmentMs: segmentMs);

  WaveformSegmentState stateOf(int index) {
    if (_frames.containsKey(index)) return WaveformSegmentState.ready;
    if (_pending.containsKey(index)) return WaveformSegmentState.loading;
    if (_empty.contains(index)) return WaveformSegmentState.empty;
    return WaveformSegmentState.idle;
  }

  /// 已抽到（非空）的段占时间窗的比例（0..1），用于归一化上限换算
  /// （[waveformCeilingPercentile]）。
  double get loadedFraction {
    if (durationMs <= 0) return 0;
    int loadedMs = 0;
    for (final int index in _frames.keys) {
      loadedMs += rangeOf(index).spanMs;
    }
    return loadedMs / durationMs;
  }

  /// 是否至少有一段抽到了非空包络。
  bool get hasAnyFrames => _frames.isNotEmpty;

  /// 拼好的整条逐帧包络（dB，覆盖 `[0, durationMs)`，未抽段为静音填充）。段抽到新数据
  /// 才重拼；引用不变即内容不变，消费方按 `identical` 判是否要重算降采样。
  List<double> get stitchedDb => _stitched ??= stitchWaveformSegments(
    durationMs: durationMs,
    segments: _frames,
    segmentMs: segmentMs,
    frameMs: frameMs,
  );

  /// 显式抽第 [index] 段（打开弹窗时播放头所在段）。已抽到直接返回 true；抽空过的段
  /// 会重试；返回该段是否抽到非空包络。
  Future<bool> ensureSegment(int index) {
    if (index < 0 || index >= segmentCount || _disposed) {
      return Future<bool>.value(false);
    }
    if (_frames.containsKey(index)) return Future<bool>.value(true);
    _explicit.add(index);
    final Completer<bool>? existing = _pending[index];
    if (existing != null) {
      // 已在排队：显式请求提到队首（正在抽的不在队里，原样等它完成）。
      if (_queue.remove(index)) _queue.insert(0, index);
      return existing.future;
    }
    _empty.remove(index);
    final Completer<bool> completer = Completer<bool>();
    _pending[index] = completer;
    _queue.insert(0, index);
    notifyListeners();
    _pump();
    return completer.future;
  }

  /// 显式抽 [timeMs] 所在的段。
  Future<bool> ensureSegmentAt(int timeMs) => ensureSegment(
    waveformSegmentIndexAt(
      timeMs,
      durationMs: durationMs,
      segmentMs: segmentMs,
    ),
  );

  /// 视口驱动：让与 `[startMs, endMs)` 相交的段进队（中间那段优先），并撤销排队中
  /// 已不在此区间的非显式请求。已抽到 / 抽空 / 正在抽的段不动。幂等，可每帧调；
  /// 只在段状态真的变化时通知。
  void ensureRange(int startMs, int endMs) {
    if (_disposed) return;
    final List<int> wanted = waveformSegmentsOverlapping(
      startMs: startMs,
      endMs: endMs,
      durationMs: durationMs,
      segmentMs: segmentMs,
    );
    final Set<int> wantedSet = wanted.toSet();
    bool changed = false;
    for (final int index in List<int>.of(_queue)) {
      if (wantedSet.contains(index) || _explicit.contains(index)) continue;
      _queue.remove(index);
      _pending.remove(index)?.complete(false);
      changed = true;
    }
    final List<int> nextQueue = <int>[
      for (final int i in _queue)
        if (_explicit.contains(i)) i,
    ];
    for (final int index in wanted) {
      if (nextQueue.contains(index)) continue;
      if (_queue.contains(index)) {
        nextQueue.add(index);
        continue;
      }
      if (stateOf(index) != WaveformSegmentState.idle) continue;
      _pending[index] = Completer<bool>();
      nextQueue.add(index);
      changed = true;
    }
    _queue
      ..clear()
      ..addAll(nextQueue);
    if (changed) notifyListeners();
    _pump();
  }

  void _pump() {
    if (_disposed || _active != null || _queue.isEmpty) return;
    final int index = _queue.removeAt(0);
    _active = index;
    unawaited(_run(index));
  }

  Future<void> _run(int index) async {
    final WaveformSegmentRange range = rangeOf(index);
    List<double> frames;
    try {
      frames = await _loadSegment(range.startMs, range.endMs);
    } catch (e, stack) {
      // 页面侧抽取自身已把 ffmpeg 失败降级为空包络；这里兜住注入方抛出的异常，记诊断、
      // 该段按空处理（不自动重试），不让一段失败拖垮整个视图。
      debugPrint(
        '[subtitle-waveform] segment $index $range failed: $e\n$stack',
      );
      frames = const <double>[];
    }
    _active = null;
    _explicit.remove(index);
    final Completer<bool>? completer = _pending.remove(index);
    if (_disposed) {
      if (completer != null && !completer.isCompleted) {
        completer.complete(false);
      }
      return;
    }
    if (frames.isEmpty) {
      _empty.add(index);
    } else {
      _frames[index] = frames;
      _stitched = null;
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete(frames.isNotEmpty);
    }
    notifyListeners();
    _pump();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final Completer<bool> c in _pending.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _pending.clear();
    _queue.clear();
    super.dispose();
  }
}
