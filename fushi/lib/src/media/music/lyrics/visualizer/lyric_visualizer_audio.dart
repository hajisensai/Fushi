/// 全屏歌词动画的音频契约（folia 的 `audioPower` / `audioBands` / beat FX 信号）。
///
/// 实现方是音频分析服务（`lib/src/media/music/analysis/`，Rust 离线分析整首后交出包络与节拍网格）；
/// 样式只读这里的契约，经 `LyricVisualizerContext.audioFrameAt` 取一帧：分析就绪时是真音频，
/// 没有分析（未分析完 / 失败 / 无音频）时回落到歌词起字包络 `runtime.pulseAt`，样式只调一个函数。
///
/// 时间：契约一律是**音频时间**（播放位置，毫秒，不含歌词偏移）。歌词显示时间 = 音频时间 + offsetMs，
/// 换算由 `LyricVisualizerContext.audioTimeOf` 做，样式不要自己加减。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;

// 拍点 / 鼓击事件的共享工具（显示时间窗口、folia 重音增益、包络）与契约同出。
export 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_beats.dart';

/// 一帧音频信号。数值全部规整到 0–1（实现方负责归一化：整首自适应，不随音量绝对值跳）。
@immutable
class LyricVisualizerAudioFrame {
  const LyricVisualizerAudioFrame({
    required this.power,
    required this.low,
    required this.mid,
    required this.high,
    required this.vocal,
    required this.onset,
    required this.beatImpact,
    required this.downbeatImpact,
    required this.drumImpact,
    double? lowMid,
    double? upperMid,
    this.accentImpact,
    this.bpm,
    this.envelopeReady = false,
    this.beatsReady = false,
    this.drumsReady = false,
    this.vocalReady = false,
    this.fallback = false,
  }) : _lowMid = lowMid,
       _upperMid = upperMid;

  /// 全静（还没任何数据、也没有歌词可回落时）。
  static const LyricVisualizerAudioFrame silent = LyricVisualizerAudioFrame(
    power: 0,
    low: 0,
    mid: 0,
    high: 0,
    vocal: 0,
    onset: 0,
    beatImpact: 0,
    downbeatImpact: 0,
    drumImpact: 0,
    fallback: true,
  );

  /// 整体响度（RMS 包络；folia `audioPower`）。
  final double power;

  /// 低频（≈20–150 Hz；folia `bass`）。
  final double low;

  /// 中频（≈150–1200 Hz；folia `lowMid` + `mid` 两段的合并）。要逐段还原 folia `audioBands` 时用
  /// [lowMid] / [upperMid]。
  final double mid;

  final double? _lowMid;
  final double? _upperMid;

  /// 中低频（≈150–400 Hz；folia `lowMid`）。没有分段数据（旧分析结果 / 歌词回落）时等于 [mid]。
  double get lowMid => _lowMid ?? mid;

  /// 中频上段（≈400–1200 Hz；folia `audioBands.mid`）。没有分段数据时等于 [mid]。
  double get upperMid => _upperMid ?? mid;

  /// 高频（≈3.5 kHz 以上；folia `treble`）。
  final double high;

  /// 人声包络（有人声分离时是 vocal stem，否则中频人声带代理；folia `vocal`）。
  final double vocal;

  /// 起音强度（频谱通量，0–1）。
  final double onset;

  /// 拍点冲击：落在拍上冲到 1，随后衰减（folia `beatImpact`）。
  final double beatImpact;

  /// 强拍（小节第一拍）冲击（folia `downbeatImpact`）。
  final double downbeatImpact;

  /// 鼓击冲击（鼓 stem / 打击乐成分的击点；folia drum hits）。
  final double drumImpact;

  /// 按重音加权的拍点冲击（folia `beatAccents`）：只在有节奏的听感拍上打，峰值 = 该拍强度 ×
  /// 整首动感系数；前奏 / 无节奏段为 0。null = 没有重音数据（旧结果 / 歌词回落），样式退回
  /// [beatImpact]，或直接用 [accentOrBeat]。
  final double? accentImpact;

  /// 有重音就用重音，否则用原始拍点冲击。
  double get accentOrBeat => accentImpact ?? beatImpact;

  /// 整首速度（拍 / 分）；未知为 null。
  final double? bpm;

  /// [power] / 频段 / [onset] 来自真音频分析。
  final bool envelopeReady;

  /// [beatImpact] / [downbeatImpact] / [bpm] 来自真节拍网格。
  final bool beatsReady;

  /// [drumImpact] 来自真鼓击检测。
  final bool drumsReady;

  /// [vocal] 来自真人声包络。
  final bool vocalReady;

  /// true = 这一帧是歌词起字包络的代用品（没有音频分析）。
  final bool fallback;

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerAudioFrame &&
      other.power == power &&
      other.low == low &&
      other.mid == mid &&
      other.lowMid == lowMid &&
      other.upperMid == upperMid &&
      other.high == high &&
      other.vocal == vocal &&
      other.onset == onset &&
      other.beatImpact == beatImpact &&
      other.downbeatImpact == downbeatImpact &&
      other.drumImpact == drumImpact &&
      other.accentImpact == accentImpact &&
      other.bpm == bpm &&
      other.envelopeReady == envelopeReady &&
      other.beatsReady == beatsReady &&
      other.drumsReady == drumsReady &&
      other.vocalReady == vocalReady &&
      other.fallback == fallback;

  @override
  int get hashCode => Object.hash(
    power,
    low,
    mid,
    lowMid,
    upperMid,
    high,
    vocal,
    onset,
    beatImpact,
    downbeatImpact,
    drumImpact,
    accentImpact,
    bpm,
    envelopeReady,
    beatsReady,
    drumsReady,
    vocalReady,
    fallback,
  );

  @override
  String toString() =>
      'LyricVisualizerAudioFrame(power: $power, low: $low, mid: $mid, '
      'high: $high, vocal: $vocal, beat: $beatImpact, downbeat: '
      '$downbeatImpact, drum: $drumImpact, accent: $accentImpact, bpm: $bpm, fallback: $fallback)';
}

/// 鼓击种类（folia drum hits 的 kind）。
enum LyricVisualizerDrumKind { kick, snare, hat }

/// 一下鼓击（音频时间）。
@immutable
class LyricVisualizerDrumHit {
  const LyricVisualizerDrumHit({
    required this.timeMs,
    required this.kind,
    required this.strength,
  });

  /// 音频时间（毫秒）。
  final int timeMs;

  final LyricVisualizerDrumKind kind;

  /// 力度 0–1。
  final double strength;

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerDrumHit &&
      other.timeMs == timeMs &&
      other.kind == kind &&
      other.strength == strength;

  @override
  int get hashCode => Object.hash(timeMs, kind, strength);

  @override
  String toString() =>
      'LyricVisualizerDrumHit($timeMs, ${kind.name}, $strength)';
}

/// 一拍的数据（音频时间；folia `beatAccents` 的一项 + 拍 / 强拍归属）。
@immutable
class LyricVisualizerBeat {
  const LyricVisualizerBeat({
    required this.timeMs,
    required this.downbeat,
    this.impact,
    this.lowShare = 1 / 3,
    this.midShare = 1 / 3,
    this.highShare = 1 / 3,
    this.rhythmic = true,
    this.pulse = true,
  });

  /// 音频时间（毫秒）。
  final int timeMs;

  /// 是强拍（小节第一拍，[LyricVisualizerAudio.downbeatTimesMs] 里有它）。
  final bool downbeat;

  /// 重音强度 0–1（folia `impact`）；null = 没有重音数据（旧结果），此时音色三项都是 1/3、
  /// [rhythmic] / [pulse] 都是 true。
  final double? impact;

  /// 这一拍突起里低频（<150 Hz）/ 中频（150–2000 Hz）/ 高频（≥2000 Hz）的占比（三者和 ≈ 1；folia `tone`）。
  final double lowShare;
  final double midShare;
  final double highShare;

  /// 这一拍有节奏可打（folia `rhythmic`：只有铺底的小节为 false，拍点特效不打）。
  final bool rhythmic;

  /// 是听感拍（folia `pulse`：复合拍子数得比听感细时只留每组头一拍；false 的拍 folia 不进特效表）。
  final bool pulse;

  /// 有重音数据。
  bool get hasAccents => impact != null;

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerBeat &&
      other.timeMs == timeMs &&
      other.downbeat == downbeat &&
      other.impact == impact &&
      other.lowShare == lowShare &&
      other.midShare == midShare &&
      other.highShare == highShare &&
      other.rhythmic == rhythmic &&
      other.pulse == pulse;

  @override
  int get hashCode => Object.hash(
    timeMs,
    downbeat,
    impact,
    lowShare,
    midShare,
    highShare,
    rhythmic,
    pulse,
  );

  @override
  String toString() =>
      'LyricVisualizerBeat($timeMs, downbeat: $downbeat, impact: $impact, '
      'tone: $lowShare/$midShare/$highShare, rhythmic: $rhythmic, pulse: $pulse)';
}

/// 一首歌的音频分析结果（实现方：音频分析服务）。只读；分析进度变化时实现方换一个新对象交给宿主
/// （宿主据此重建 context），或者同一对象内部的 ready 标志变 true。
///
/// 每帧调 [frameAt] 必须便宜（O(log n) 查表 + 插值，**不跨 FFI**：数据整首一次性交到 Dart 的
/// TypedData 里）。
abstract interface class LyricVisualizerAudio {
  /// [audioMs] 时刻（音频时间）的一帧。还没就绪的部分填 0 并把对应 ready 标志置 false。
  LyricVisualizerAudioFrame frameAt(int audioMs);

  /// 拍点（音频时间毫秒，升序）。没有节拍网格时为空。可以是 `Int32List`。
  List<int> get beatTimesMs;

  /// 强拍（音频时间毫秒，升序，是 [beatTimesMs] 的子集）。
  List<int> get downbeatTimesMs;

  /// 整首速度；未知为 null。
  double? get bpm;

  /// 逐拍数据，与 [beatTimesMs] 等长同序。没有节拍网格时为空。拍点特效一般不直接读它，而是经
  /// `LyricVisualizerBeats.of(context)`（folia 的合并 / 过滤 / 重音增益都在那里做好）。
  List<LyricVisualizerBeat> get beats;

  /// 有逐拍重音（[LyricVisualizerBeat.impact] 非 null）。
  bool get hasBeatAccents;

  /// 整曲动感系数（folia `trackScale`，0.45–1；没有重音数据时为 1）。
  double get trackScale;

  /// 鼓击（音频时间升序）。没有鼓击检测或判为没鼓的歌为空，看 [drumsReady] 区分。
  List<LyricVisualizerDrumHit> get drumHits;

  /// 鼓击检测已就绪（有鼓击，或判定这首没鼓——「没有鼓击」本身就是答案）。
  bool get drumsReady;

  /// 人声起音（音频时间毫秒，升序；只有人声分轨时有，否则为空）。
  List<int> get vocalOnsetsMs;

  /// 包络（power / 频段）已就绪。为 false 时 `audioFrameAt` 回落到歌词包络。
  bool get envelopeReady;

  /// 节拍网格已就绪。
  bool get beatsReady;
}

/// 拍点冲击包络：最近一个不晚于 [timeMs] 的拍点处为 1，按 [decayMs] 指数回落（folia beat FX 同型）。
/// [times] 升序；没有拍点或还没到第一拍为 0。
double lyricVisualizerImpactAt(
  List<int> times,
  int timeMs, {
  int decayMs = 180,
}) {
  final int i = lyricVisualizerLastAtOrBefore(times, timeMs);
  if (i < 0) return 0;
  final double dt = (timeMs - times[i]).toDouble();
  return math.exp(-dt / decayMs);
}

/// 升序表里最后一个 ≤ [timeMs] 的下标（没有为 -1）。
int lyricVisualizerLastAtOrBefore(List<int> times, int timeMs) {
  int lo = 0;
  int hi = times.length - 1;
  int found = -1;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    if (times[mid] <= timeMs) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

/// 拍内相位 0–1（上一拍 → 下一拍）；拍点不足两个或在首拍前 / 末拍后为 null。
double? lyricVisualizerBeatPhaseAt(List<int> beats, int timeMs) {
  final int i = lyricVisualizerLastAtOrBefore(beats, timeMs);
  if (i < 0 || i + 1 >= beats.length) return null;
  final int span = beats[i + 1] - beats[i];
  if (span <= 0) return null;
  return (timeMs - beats[i]) / span;
}
