import 'dart:math' as math;

import 'package:hibiki_audio/hibiki_audio.dart';

/// 字幕自动对轴（TODO-701 阶段1）的纯算法层。
///
/// 思路：把「字幕 cue 的时间窗」与「音频的语音活动包络」分别栅格化成同一时间栅格
/// 上的 0/1（或 0..1）活动序列，再做互相关（cross-correlation）在 ±[maxShiftMs]
/// 范围内滑动，找让两者重叠最大的整体平移 offset。**只整体平移、不重排单条 cue、
/// 不解帧率漂移**——这正是「手动延迟」做的事，本层只是自动算出该填多少延迟。
///
/// 全部纯函数（无 IO、无平台依赖），便于单测。音频包络的真实采样由
/// `audio_energy_probe.dart`（经 ffmpeg 抽象）提供。

/// 一次自动对轴的结果状态。
enum SubtitleAutoAlignStatus {
  /// 算出可信 offset，可写穿延迟。
  aligned,

  /// 输入不足（无 cue / 无音频包络）——不应改动延迟。
  noData,

  /// 算出了 offset 但置信度低于阈值——不写穿，仅提示用户。
  lowConfidence,
}

/// 自动对轴结果值对象（不可变）。
///
/// [offsetMs] 与现有手动延迟 `delayMs` 同号同义：正值＝字幕需整体延后（画面/音频
/// 先于文字）。[confidence] 是归一化的互相关峰值（0..1，越高越可信）。[status]
/// 标识是否产出可用结果，调用方据此决定写穿延迟还是仅提示。
class SubtitleAutoAlignResult {
  const SubtitleAutoAlignResult({
    required this.offsetMs,
    required this.confidence,
    required this.status,
  });

  /// 输入不足时的中性结果（offset=0、confidence=0、status=noData）。
  static const SubtitleAutoAlignResult noData = SubtitleAutoAlignResult(
    offsetMs: 0,
    confidence: 0.0,
    status: SubtitleAutoAlignStatus.noData,
  );

  /// 推荐的整体平移量（毫秒，与 `delayMs` 同号）。
  final int offsetMs;

  /// 归一化互相关峰值（0..1）。
  final double confidence;

  /// 结果状态。
  final SubtitleAutoAlignStatus status;

  @override
  bool operator ==(Object other) =>
      other is SubtitleAutoAlignResult &&
      other.offsetMs == offsetMs &&
      other.confidence == confidence &&
      other.status == status;

  @override
  int get hashCode => Object.hash(offsetMs, confidence, status);

  @override
  String toString() => 'SubtitleAutoAlignResult(offsetMs: $offsetMs, '
      'confidence: ${confidence.toStringAsFixed(3)}, status: $status)';
}

/// 默认时间栅格步长（毫秒）。100ms 兼顾分辨率与计算量：±15s 的搜索窗 → 300 个偏移
/// 步，序列长度按视频时长 / 100ms（一部 2h 电影约 72000 格），互相关 O(N·shifts)
/// 仍可接受。
const int kSubtitleAutoAlignBinMs = 100;

/// 默认最大搜索平移（毫秒）。±15s 覆盖绝大多数「字幕整体早/晚」的人工偏移；超出此
/// 范围通常不是整体平移问题（而是错配/帧率漂移），不在阶段1处理范围内。
const int kSubtitleAutoAlignMaxShiftMs = 15000;

/// 默认置信阈值。低于此值认为对齐不可信（噪声/无明显语音结构），不写穿延迟。
///
/// TODO-413：此 0.15 偏低，误判（把噪声当对齐而误移字幕）风险存在。**真机门禁须用真实
/// 错轴样本验是否过松**——过松则上调此常量（纯数值，配套纯函数测试同步），不在施工阶段
/// 擅自改动（阈值由真机门禁定）。
const double kSubtitleAutoAlignMinConfidence = 0.15;

/// **纯函数**：把字幕 [cues] 栅格化成时间轴活动序列。
///
/// 在 `[0, durationMs)` 上按 [binMs] 分格，cue 时间窗 `[startMs, endMs)` 覆盖到的
/// 格置 1，其余 0。返回长度 `ceil(durationMs / binMs)` 的 0/1 列表（double，便于
/// 与音频能量包络同类型互相关）。空 cue / 非正时长返回空列表。
///
/// start>=end 的退化 cue 跳过。**截断语义（TODO-413）**：`startMs >= durationMs` 的
/// cue 整段在上界之外，**直接跳过**（不 clamp 到末格——否则前 N 分钟截断时所有尾部
/// cue 会在边界格堆出假活动，污染互相关）；横跨上界的 cue 只保留落在 `[0, durationMs)`
/// 内的部分（endMs 端点 clamp 到末格）。这样 cue 栅格与音频 `-t` 截断后的包络共享同一
/// `[0, durationMs)` 时间窗，相位一致。
List<double> buildCueActivityEnvelope(
  List<AudioCue> cues,
  int durationMs, {
  int binMs = kSubtitleAutoAlignBinMs,
}) {
  if (durationMs <= 0 || binMs <= 0 || cues.isEmpty) {
    return const <double>[];
  }
  final int length = (durationMs + binMs - 1) ~/ binMs;
  final List<double> envelope = List<double>.filled(length, 0.0);
  for (final AudioCue cue in cues) {
    final int startMs = cue.startMs;
    final int endMs = cue.endMs;
    if (endMs <= startMs) continue;
    // 整段越上界：跳过（不堆边界假活动）。负 endMs 同理被 endMs<=startMs 或此处过滤。
    if (startMs >= durationMs || endMs <= 0) continue;
    final int startBin = (startMs ~/ binMs).clamp(0, length - 1);
    // endMs 闭区间末尾落在前一格：用 (endMs - 1) 防止把整段右边多覆盖一格。
    final int endBin = ((endMs - 1) ~/ binMs).clamp(0, length - 1);
    for (int b = startBin; b <= endBin; b++) {
      envelope[b] = 1.0;
    }
  }
  return envelope;
}

/// **纯函数**：把逐帧 RMS 能量 [rawRms]（任意单位，越大越响）阈值化成 0/1 语音活动
/// （VAD）序列。
///
/// 简单能量门限 VAD：对每格能量做归一化后与 [voiceThreshold]（0..1，相对峰值）比较，
/// 超过则置 1（有语音/声音），否则 0。这样字幕活动（说话时段）与音频活动（有声时段）
/// 用同一「0/1 活动」表示，互相关才有意义。空输入返回空列表。
///
/// 归一化基准取序列的 [min, max] 区间（而非绝对 dB），抹平不同片源/音轨的整体响度差异；
/// 区间退化（全等值）时返回全 0。NaN（无数据格）按 0 处理。
List<double> normalizeAudioEnergyEnvelope(
  List<double> rawRms, {
  double voiceThreshold = 0.35,
}) {
  if (rawRms.isEmpty) return const <double>[];
  double maxV = double.negativeInfinity;
  double minV = double.infinity;
  for (final double v in rawRms) {
    if (v.isNaN) continue;
    if (v > maxV) maxV = v;
    if (v < minV) minV = v;
  }
  if (!maxV.isFinite || !minV.isFinite || maxV <= minV) {
    return List<double>.filled(rawRms.length, 0.0);
  }
  final double range = maxV - minV;
  final double threshold = voiceThreshold.clamp(0.0, 1.0).toDouble();
  final List<double> out = List<double>.filled(rawRms.length, 0.0);
  for (int i = 0; i < rawRms.length; i++) {
    final double v = rawRms[i];
    if (v.isNaN) {
      out[i] = 0.0;
      continue;
    }
    final double norm = (v - minV) / range;
    out[i] = norm >= threshold ? 1.0 : 0.0;
  }
  return out;
}

/// **纯函数**：在 ±[maxShiftMs] 内滑动求 [audioActivity] 与 [cueActivity] 的互相关
/// 峰值，返回让「字幕整体平移后与音频活动重叠最大」的偏移（毫秒）+ 归一化置信度。
///
/// 约定：正 offset 表示**字幕需整体延后**（与 `delayMs` 同号同义）。实现上枚举 shift
/// （以格为单位），把 cueActivity 整体右移 shift 格后与 audioActivity 逐格相乘求和
/// （重叠的「都为 1」格累加）；归一化分母取两序列各自的活动格数中较小者（最大可能
/// 重叠），得 0..1 的置信度。无重叠/空输入返回 noData。
///
/// shift 步长 = [binMs]；搜索范围 `[-maxShiftMs, +maxShiftMs]` 换算成格数枚举。
SubtitleAutoAlignResult bestOffsetMsByCrossCorrelation(
  List<double> audioActivity,
  List<double> cueActivity, {
  int binMs = kSubtitleAutoAlignBinMs,
  int maxShiftMs = kSubtitleAutoAlignMaxShiftMs,
  double minConfidence = kSubtitleAutoAlignMinConfidence,
}) {
  if (binMs <= 0 ||
      audioActivity.isEmpty ||
      cueActivity.isEmpty ||
      maxShiftMs < 0) {
    return SubtitleAutoAlignResult.noData;
  }
  final double audioActiveCount = _activeCount(audioActivity);
  final double cueActiveCount = _activeCount(cueActivity);
  if (audioActiveCount <= 0 || cueActiveCount <= 0) {
    return SubtitleAutoAlignResult.noData;
  }
  // 归一化分母：理论最大重叠 = 两序列活动格数中较小者。
  final double maxOverlap = math.min(audioActiveCount, cueActiveCount);

  final int maxShiftBins = maxShiftMs ~/ binMs;
  int bestShiftBins = 0;
  double bestOverlap = -1.0;
  for (int shift = -maxShiftBins; shift <= maxShiftBins; shift++) {
    final double overlap = _overlapAtShift(audioActivity, cueActivity, shift);
    // 平手时偏向 |shift| 更小者（更接近无偏移，避免过度平移）。
    if (overlap > bestOverlap ||
        (overlap == bestOverlap && shift.abs() < bestShiftBins.abs())) {
      bestOverlap = overlap;
      bestShiftBins = shift;
    }
  }

  final double confidence =
      maxOverlap > 0 ? (bestOverlap / maxOverlap).clamp(0.0, 1.0) : 0.0;
  final int offsetMs = bestShiftBins * binMs;
  final SubtitleAutoAlignStatus status = confidence >= minConfidence
      ? SubtitleAutoAlignStatus.aligned
      : SubtitleAutoAlignStatus.lowConfidence;
  return SubtitleAutoAlignResult(
    offsetMs: offsetMs,
    confidence: confidence,
    status: status,
  );
}

/// 序列中「活动格」（值 > 0）的总和（活动强度），用作互相关归一化基准。
double _activeCount(List<double> activity) {
  double sum = 0.0;
  for (final double v in activity) {
    if (v > 0) sum += v;
  }
  return sum;
}

/// 把 [cueActivity] 整体右移 [shiftBins] 格（正＝字幕延后）后与 [audioActivity]
/// 逐格相乘求和。`audio[i]` 对应 `cue[i - shiftBins]`。
double _overlapAtShift(
  List<double> audioActivity,
  List<double> cueActivity,
  int shiftBins,
) {
  double overlap = 0.0;
  final int n = audioActivity.length;
  final int m = cueActivity.length;
  for (int i = 0; i < n; i++) {
    final int j = i - shiftBins;
    if (j < 0 || j >= m) continue;
    final double a = audioActivity[i];
    final double c = cueActivity[j];
    if (a > 0 && c > 0) overlap += a * c;
  }
  return overlap;
}
