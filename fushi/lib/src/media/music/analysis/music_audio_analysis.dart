/// 一首歌的离线音频分析结果（native `ffc_mana_*` 写出的 `.fma` 文件）+ 全屏歌词动画音频契约的实现。
///
/// 整份文件读进内存，按偏移切成 TypedData 视图；[frameAt] 是 O(log n) 查表 + 线性插值，不跨 FFI、
/// 不分配大对象，每帧调都便宜。布局与 native/fushi_compute/src/music_analysis/format.rs 头注逐字段对应，
/// 改布局两侧同改、同升 [kMusicAudioAnalysisFormatVersion]。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_audio.dart';

/// 结果文件布局版本（= native `format::FORMAT_VERSION`）。
const int kMusicAudioAnalysisFormatVersion = 1;

/// 头长（字节）。
const int _kHeaderBytes = 64;

/// 魔数 "FMA1"。
const List<int> _kMagic = <int>[0x46, 0x4D, 0x41, 0x31];

/// 结果 flags（= native `format::FLAG_*`）。
abstract final class MusicAudioAnalysisFlags {
  /// 拍点来自 Beat This! 模型（否则是 DSP 退路）。
  static const int beatsModel = 1 << 0;

  /// 鼓点来自 htdemucs 鼓轨（否则是 HPSS 打击成分）。
  static const int drumsModel = 1 << 1;

  /// 人声来自 htdemucs 人声轨（否则是混音的 1–3.5 kHz 人声频段）。
  static const int vocalModel = 1 << 2;

  /// 判为没鼓的歌（鼓轨路径上判，鼓点表为空）。
  static const int drumless = 1 << 3;
}

/// 鼓点类别。
enum MusicDrumHitKind { kick, snare, hat }

/// 拍点冲击的衰减（与 `LyricVisualizerContext.audioFrameAt` 的回落路径同值）。
const int kMusicBeatImpactDecayMs = 180;

/// 强拍冲击的衰减。
const int kMusicDownbeatImpactDecayMs = 320;

/// 鼓击冲击的衰减。
const int kMusicDrumImpactDecayMs = 150;

/// 一首歌的分析结果。
@immutable
class MusicAudioAnalysis implements LyricVisualizerAudio {
  const MusicAudioAnalysis._({
    required this.flags,
    required this.frameRate,
    required this.frameCount,
    required this.bpm,
    required this.beatsPerBar,
    required this.durationMs,
    required this.pipelineVersion,
    required Uint8List power,
    required Uint8List low,
    required Uint8List mid,
    required Uint8List high,
    required Uint8List onset,
    required Uint8List vocal,
    required this.beatTimesMs,
    required this.downbeatTimesMs,
    required this.hitTimesMs,
    required Uint8List hitStrength,
    required Uint8List hitKind,
    required this.vocalOnsetsMs,
  }) : _power = power,
       _low = low,
       _mid = mid,
       _high = high,
       _onset = onset,
       _vocal = vocal,
       _hitStrength = hitStrength,
       _hitKind = hitKind;

  /// 解析 `.fma` 字节；不是本版本的文件（魔数 / 布局版本不符、截断）返回 null。
  /// [expectedPipelineVersion] 给了时，算法版本不符也返回 null（旧缓存作废重算）。
  static MusicAudioAnalysis? tryParse(
    Uint8List bytes, {
    int? expectedPipelineVersion,
  }) {
    if (bytes.length < _kHeaderBytes) return null;
    for (int i = 0; i < 4; i++) {
      if (bytes[i] != _kMagic[i]) return null;
    }
    final ByteData h = ByteData.sublistView(bytes, 0, _kHeaderBytes);
    int u32(int o) => h.getUint32(o, Endian.little);
    if (u32(4) != kMusicAudioAnalysisFormatVersion) return null;
    final int pipeline = u32(48);
    if (expectedPipelineVersion != null &&
        pipeline != expectedPipelineVersion) {
      return null;
    }
    final int f = u32(16);
    final int b = u32(28);
    final int d = u32(32);
    final int hits = u32(36);
    final int v = u32(40);
    final int envEnd = _kHeaderBytes + _align4(6 * f);
    final int timesEnd = envEnd + 4 * (b + d + hits);
    final int hitsEnd = timesEnd + _align4(2 * hits);
    if (bytes.length < hitsEnd + 4 * v) return null;
    final double frameRate = h.getFloat32(12, Endian.little);
    if (!(frameRate > 0)) return null;
    final double bpm = h.getFloat32(20, Endian.little);
    Uint8List series(int i) => Uint8List.sublistView(
      bytes,
      _kHeaderBytes + i * f,
      _kHeaderBytes + (i + 1) * f,
    );
    // 整数表按小端逐个取出（平台字节序无关；表长不过几千，一次性的）。
    Int32List ints(int from, int n) {
      final ByteData view = ByteData.sublistView(bytes, from, from + 4 * n);
      final Int32List out = Int32List(n);
      for (int k = 0; k < n; k++) {
        out[k] = view.getInt32(4 * k, Endian.little);
      }
      return out;
    }

    return MusicAudioAnalysis._(
      flags: u32(8),
      frameRate: frameRate,
      frameCount: f,
      bpm: bpm > 0 ? bpm : null,
      beatsPerBar: u32(24),
      durationMs: u32(44),
      pipelineVersion: pipeline,
      power: series(0),
      low: series(1),
      mid: series(2),
      high: series(3),
      onset: series(4),
      vocal: series(5),
      beatTimesMs: ints(envEnd, b),
      downbeatTimesMs: ints(envEnd + 4 * b, d),
      hitTimesMs: ints(envEnd + 4 * (b + d), hits),
      hitStrength: Uint8List.sublistView(bytes, timesEnd, timesEnd + hits),
      hitKind: Uint8List.sublistView(
        bytes,
        timesEnd + hits,
        timesEnd + 2 * hits,
      ),
      vocalOnsetsMs: ints(hitsEnd, v),
    );
  }

  static int _align4(int n) => (n + 3) & ~3;

  /// [MusicAudioAnalysisFlags] 的组合。
  final int flags;

  /// 包络帧率（帧 / 秒，≈86.13）。
  final double frameRate;

  /// 包络帧数。
  final int frameCount;

  @override
  final double? bpm;

  /// 每小节拍数（模型数出来的；退路在 3 / 4 里选）。
  final int beatsPerBar;

  /// 分析覆盖的时长（毫秒）。
  final int durationMs;

  /// 写出这份结果的分析算法版本。
  final int pipelineVersion;

  final Uint8List _power;
  final Uint8List _low;
  final Uint8List _mid;
  final Uint8List _high;
  final Uint8List _onset;
  final Uint8List _vocal;

  @override
  final Int32List beatTimesMs;

  @override
  final Int32List downbeatTimesMs;

  /// 鼓点时间（毫秒，升序）。
  final Int32List hitTimesMs;

  final Uint8List _hitStrength;
  final Uint8List _hitKind;

  /// 人声起音（毫秒，升序；只有人声分轨时有）。
  final Int32List vocalOnsetsMs;

  /// 拍点来自模型。
  bool get beatsFromModel => flags & MusicAudioAnalysisFlags.beatsModel != 0;

  /// 鼓点来自鼓轨。
  bool get drumsFromModel => flags & MusicAudioAnalysisFlags.drumsModel != 0;

  /// 人声来自人声轨。
  bool get vocalFromModel => flags & MusicAudioAnalysisFlags.vocalModel != 0;

  /// 没鼓的歌。
  bool get drumless => flags & MusicAudioAnalysisFlags.drumless != 0;

  /// 第 [i] 个鼓点的强度（0–1）。
  double hitStrength(int i) => _hitStrength[i] / 255;

  /// 第 [i] 个鼓点的类别。
  MusicDrumHitKind hitKind(int i) =>
      MusicDrumHitKind.values[math.min(_hitKind[i], 2)];

  @override
  bool get envelopeReady => frameCount > 0;

  @override
  bool get beatsReady => beatTimesMs.isNotEmpty;

  /// 鼓点就绪：有鼓点，或判定没鼓（「没有鼓点」本身就是答案）。
  bool get drumsReady => hitTimesMs.isNotEmpty || drumless;

  /// 一条包络在帧位置 [pos] 的线性插值（0–1）；范围外为 0。
  double _sample(Uint8List s, double pos) {
    if (pos < 0 || frameCount == 0 || pos > frameCount - 1) return 0;
    final int i = pos.floor();
    final int j = math.min(i + 1, frameCount - 1);
    final double t = pos - i;
    return (s[i] * (1 - t) + s[j] * t) / 255;
  }

  /// 鼓击冲击：最近三下里「强度 × 衰减」最大的那个。
  double drumImpactAt(int audioMs) {
    final int last = lyricVisualizerLastAtOrBefore(hitTimesMs, audioMs);
    double best = 0;
    for (int k = last; k >= 0 && k > last - 3; k--) {
      final double dt = (audioMs - hitTimesMs[k]).toDouble();
      final double v = hitStrength(k) * math.exp(-dt / kMusicDrumImpactDecayMs);
      if (v > best) best = v;
    }
    return best;
  }

  @override
  LyricVisualizerAudioFrame frameAt(int audioMs) {
    final double pos = audioMs * frameRate / 1000;
    return LyricVisualizerAudioFrame(
      power: _sample(_power, pos),
      low: _sample(_low, pos),
      mid: _sample(_mid, pos),
      high: _sample(_high, pos),
      vocal: _sample(_vocal, pos),
      onset: _sample(_onset, pos),
      beatImpact: lyricVisualizerImpactAt(
        beatTimesMs,
        audioMs,
        decayMs: kMusicBeatImpactDecayMs,
      ),
      downbeatImpact: lyricVisualizerImpactAt(
        downbeatTimesMs,
        audioMs,
        decayMs: kMusicDownbeatImpactDecayMs,
      ),
      drumImpact: drumImpactAt(audioMs),
      bpm: bpm,
      envelopeReady: envelopeReady,
      beatsReady: beatsReady,
      drumsReady: drumsReady,
      vocalReady: envelopeReady,
    );
  }

  @override
  String toString() =>
      'MusicAudioAnalysis(flags: $flags, frames: $frameCount, bpm: $bpm, '
      'beats: ${beatTimesMs.length}, downbeats: ${downbeatTimesMs.length}, '
      'hits: ${hitTimesMs.length}, vocalOnsets: ${vocalOnsetsMs.length})';
}
