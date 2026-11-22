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
    this.bpm,
    this.envelopeReady = false,
    this.beatsReady = false,
    this.drumsReady = false,
    this.vocalReady = false,
    this.fallback = false,
  });

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

  /// 中频（≈150–1200 Hz；folia `lowMid` + `mid`）。
  final double mid;

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
      other.high == high &&
      other.vocal == vocal &&
      other.onset == onset &&
      other.beatImpact == beatImpact &&
      other.downbeatImpact == downbeatImpact &&
      other.drumImpact == drumImpact &&
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
    high,
    vocal,
    onset,
    beatImpact,
    downbeatImpact,
    drumImpact,
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
      '$downbeatImpact, drum: $drumImpact, bpm: $bpm, fallback: $fallback)';
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
