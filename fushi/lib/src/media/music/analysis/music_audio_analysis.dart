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

/// 结果文件布局版本（= native `format::FORMAT_VERSION`）。v2 加了每拍重音段与 track_scale / 分离进度；
/// v3 在文件尾加了分开的两段中频（lowMid / upperMid）。
const int kMusicAudioAnalysisFormatVersion = 3;

/// 仍能读的最老布局（v1：没有重音段，按中性值补）。
const int kMusicAudioAnalysisOldestFormatVersion = 1;

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

  /// htdemucs 还在分：鼓点 / 人声只到 [MusicAudioAnalysis.stemsUntilMs]，之后仍是 DSP 的。
  static const int stemsPartial = 1 << 4;
}

/// 每拍标志位（= native `format::BEAT_*`）。
abstract final class _BeatFlags {
  static const int rhythmic = 1 << 0;
  static const int pulse = 1 << 1;
}

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
    required this.formatVersion,
    required this.trackScale,
    required this.stemsUntilMs,
    required Uint8List? beatImpact,
    required Uint8List? beatLow,
    required Uint8List? beatMid,
    required Uint8List? beatHigh,
    required Uint8List? beatFlags,
    required Uint8List? lowMid,
    required Uint8List? upperMid,
    required this.beats,
    required this.drumHits,
  }) : _lowMid = lowMid,
       _upperMid = upperMid,
       _beatImpact = beatImpact,
       _beatLow = beatLow,
       _beatMid = beatMid,
       _beatHigh = beatHigh,
       _beatFlags = beatFlags,
       _power = power,
       _low = low,
       _mid = mid,
       _high = high,
       _onset = onset,
       _vocal = vocal,
       _hitStrength = hitStrength,
       _hitKind = hitKind;

  /// 解析 `.fma` 字节；读不了的文件（魔数不符、布局版本不在
  /// [kMusicAudioAnalysisOldestFormatVersion]..[kMusicAudioAnalysisFormatVersion] 里、截断）返回 null。
  /// v1 文件没有重音段，每拍重音按中性值（满强度、都有节奏、都是听感拍）；v1 / v2 没有分开的两段中频，
  /// 帧里的 lowMid / upperMid 读作合并的 mid。
  /// [expectedPipelineVersion] 给了时，算法版本不符也返回 null（服务不用它：旧结果先拿来用、再补算）。
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
    final int version = u32(4);
    if (version < kMusicAudioAnalysisOldestFormatVersion ||
        version > kMusicAudioAnalysisFormatVersion) {
      return null;
    }
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
    final int onsetsEnd = hitsEnd + 4 * v;
    final bool hasAccents = version >= 2;
    final int accentsEnd = onsetsEnd + (hasAccents ? 5 * b : 0);
    final bool hasSplitMids = version >= 3;
    final int midsStart = _align4(accentsEnd);
    if (bytes.length < (hasSplitMids ? midsStart + 2 * f : accentsEnd)) {
      return null;
    }
    Uint8List? splitMid(int i) => hasSplitMids
        ? Uint8List.sublistView(
            bytes,
            midsStart + i * f,
            midsStart + (i + 1) * f,
          )
        : null;
    Uint8List? perBeat(int i) => hasAccents
        ? Uint8List.sublistView(
            bytes,
            onsetsEnd + i * b,
            onsetsEnd + (i + 1) * b,
          )
        : null;
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

    final Int32List beatTimes = ints(envEnd, b);
    final Int32List downbeatTimes = ints(envEnd + 4 * b, d);
    final Int32List hitTimes = ints(envEnd + 4 * (b + d), hits);
    final Uint8List hitStrength = Uint8List.sublistView(
      bytes,
      timesEnd,
      timesEnd + hits,
    );
    final Uint8List hitKind = Uint8List.sublistView(
      bytes,
      timesEnd + hits,
      timesEnd + 2 * hits,
    );
    final Uint8List? accImpact = perBeat(0);
    final Uint8List? accLow = perBeat(1);
    final Uint8List? accMid = perBeat(2);
    final Uint8List? accHigh = perBeat(3);
    final Uint8List? accFlags = perBeat(4);
    final Set<int> downbeatSet = downbeatTimes.toSet();
    // 契约的逐拍 / 逐击对象表：整首一次建好（几千项），样式按窗口查。
    final List<LyricVisualizerBeat> beats =
        List<LyricVisualizerBeat>.unmodifiable(<LyricVisualizerBeat>[
          for (int i = 0; i < b; i++)
            LyricVisualizerBeat(
              timeMs: beatTimes[i],
              downbeat: downbeatSet.contains(beatTimes[i]),
              impact: accImpact == null ? null : accImpact[i] / 255,
              lowShare: accLow == null ? 1 / 3 : accLow[i] / 255,
              midShare: accMid == null ? 1 / 3 : accMid[i] / 255,
              highShare: accHigh == null ? 1 / 3 : accHigh[i] / 255,
              rhythmic:
                  accFlags == null || accFlags[i] & _BeatFlags.rhythmic != 0,
              pulse: accFlags == null || accFlags[i] & _BeatFlags.pulse != 0,
            ),
        ]);
    final List<LyricVisualizerDrumHit> drumHits =
        List<LyricVisualizerDrumHit>.unmodifiable(<LyricVisualizerDrumHit>[
          for (int i = 0; i < hits; i++)
            LyricVisualizerDrumHit(
              timeMs: hitTimes[i],
              kind: _drumKind(hitKind[i]),
              strength: hitStrength[i] / 255,
            ),
        ]);

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
      beatTimesMs: beatTimes,
      downbeatTimesMs: downbeatTimes,
      hitTimesMs: hitTimes,
      hitStrength: hitStrength,
      hitKind: hitKind,
      vocalOnsetsMs: ints(hitsEnd, v),
      formatVersion: version,
      trackScale: hasAccents ? h.getFloat32(52, Endian.little) : 1,
      stemsUntilMs: hasAccents ? u32(56) : 0,
      beatImpact: accImpact,
      beatLow: accLow,
      beatMid: accMid,
      beatHigh: accHigh,
      beatFlags: accFlags,
      lowMid: splitMid(0),
      upperMid: splitMid(1),
      beats: beats,
      drumHits: drumHits,
    );
  }

  static int _align4(int n) => (n + 3) & ~3;

  static LyricVisualizerDrumKind _drumKind(int code) =>
      LyricVisualizerDrumKind.values[math.min(code, 2)];

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

  /// 文件布局版本（1 = 没有重音段）。
  final int formatVersion;

  /// 整曲动感系数（folia `trackScale`：中位突起映射到 0.45–1；v1 文件为 1）。
  @override
  final double trackScale;

  /// [stemsPartial] 时分离已覆盖到的毫秒（之后的鼓点 / 人声仍是 DSP 的）；否则 0。
  final int stemsUntilMs;

  final Uint8List? _lowMid;
  final Uint8List? _upperMid;

  @override
  final List<LyricVisualizerBeat> beats;

  @override
  final List<LyricVisualizerDrumHit> drumHits;

  final Uint8List? _beatImpact;
  final Uint8List? _beatLow;
  final Uint8List? _beatMid;
  final Uint8List? _beatHigh;
  final Uint8List? _beatFlags;

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
  @override
  final Int32List vocalOnsetsMs;

  /// 拍点来自模型。
  bool get beatsFromModel => flags & MusicAudioAnalysisFlags.beatsModel != 0;

  /// 鼓点来自鼓轨。
  bool get drumsFromModel => flags & MusicAudioAnalysisFlags.drumsModel != 0;

  /// 人声来自人声轨。
  bool get vocalFromModel => flags & MusicAudioAnalysisFlags.vocalModel != 0;

  /// 没鼓的歌。
  bool get drumless => flags & MusicAudioAnalysisFlags.drumless != 0;

  /// 分离还在跑，鼓点 / 人声只到 [stemsUntilMs]（结果文件会继续刷新）。
  bool get stemsPartial => flags & MusicAudioAnalysisFlags.stemsPartial != 0;

  /// 有每拍重音（v2 起；v1 文件各访问器给中性值）。
  @override
  bool get hasBeatAccents => _beatImpact != null;

  /// 第 [i] 拍的重音强度（folia `impact`：突起 40% + 前后半秒响度 60%，全曲 p10–p90 归一后 ^0.7；0–1）。
  double beatImpact(int i) => _beatImpact == null ? 1 : _beatImpact[i] / 255;

  /// 第 [i] 拍突起里低频（<150 Hz）的占比（三段之和 ≈ 1）。
  double beatLowShare(int i) => _beatLow == null ? 1 / 3 : _beatLow[i] / 255;

  /// 第 [i] 拍突起里中频（150–2000 Hz）的占比。
  double beatMidShare(int i) => _beatMid == null ? 1 / 3 : _beatMid[i] / 255;

  /// 第 [i] 拍突起里高频（≥2000 Hz）的占比。
  double beatHighShare(int i) => _beatHigh == null ? 1 / 3 : _beatHigh[i] / 255;

  /// 第 [i] 拍有节奏可打（folia `rhythmic`：只有铺底的小节、模型拿不准的段落为 false）。
  bool beatRhythmic(int i) =>
      _beatFlags == null || _beatFlags[i] & _BeatFlags.rhythmic != 0;

  /// 第 [i] 拍是听感拍（folia `pulse`：数得比听感细时只留每组头一拍）。
  bool beatPulse(int i) =>
      _beatFlags == null || _beatFlags[i] & _BeatFlags.pulse != 0;

  /// 按重音加权的拍点冲击：只算有节奏的听感拍，峰值 = 该拍 [beatImpact] × [trackScale]，
  /// 衰减同 [kMusicBeatImpactDecayMs]。拍点特效想「强拍重、弱拍轻、前奏不打」时用它代替原始拍点冲击。
  double accentedBeatImpactAt(int audioMs) {
    int k = lyricVisualizerLastAtOrBefore(beatTimesMs, audioMs);
    // 往前找最近一个会打的拍（不打的拍不算一下）。
    while (k >= 0 && !(beatRhythmic(k) && beatPulse(k))) {
      k--;
    }
    if (k < 0) return 0;
    final double dt = (audioMs - beatTimesMs[k]).toDouble();
    return beatImpact(k) * trackScale * math.exp(-dt / kMusicBeatImpactDecayMs);
  }

  /// 第 [i] 个鼓点的强度（0–1）。
  double hitStrength(int i) => _hitStrength[i] / 255;

  /// 第 [i] 个鼓点的类别。
  LyricVisualizerDrumKind hitKind(int i) => _drumKind(_hitKind[i]);

  @override
  bool get envelopeReady => frameCount > 0;

  @override
  bool get beatsReady => beatTimesMs.isNotEmpty;

  /// 鼓点就绪：有鼓点，或判定没鼓（「没有鼓点」本身就是答案）。
  @override
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
      lowMid: _lowMid == null ? null : _sample(_lowMid, pos),
      upperMid: _upperMid == null ? null : _sample(_upperMid, pos),
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
      accentImpact: hasBeatAccents ? accentedBeatImpactAt(audioMs) : null,
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
      'hits: ${hitTimesMs.length}, vocalOnsets: ${vocalOnsetsMs.length}, '
      'format: $formatVersion, pipeline: $pipelineVersion, '
      'trackScale: $trackScale, stemsUntilMs: $stemsUntilMs)';
}
