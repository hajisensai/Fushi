// 信号处理调用点基准：删除前的纯 Dart 实现（原样复制在本文件下半部分）vs
// native/fushi_compute 的 ffc_signal_*。两条路径的结果逐位比对，不一致直接退出 1。
//
// 用法（在 packages/fushi_audio 下；AOT 更接近 app）：
//   dart compile exe benchmark/signal_benchmark.dart -o <out>.exe && <out>.exe
//   dart run benchmark/signal_benchmark.dart
//
// 每项先预热一次，再跑 [_runs] 次取中位数。规模取各调用点的真实上限：
// - 字幕自动对轴：20 分钟探测上界 @100 ms = 12000 格，±15 s = 301 个 shift。
// - galgame 波形：一句语音切片 10 s / 30 s，48 kHz 立体声 float32（WASAPI 共享模式）。
// - ffmpeg 逐帧 RMS 日志：20 分钟 @20 ms = 60000 帧（约 3.5 MB）；旧 = UTF-8 解码 + 正则，
//   新 = 字节直接进 Rust。
// - 波形降采样：60000 帧 → 1366 桶（面板宽度）；旧每次改宽都重算 6 万次 pow，新路径分
//   「一次性函数（含 dB→振幅）」与「缓存振幅后只重跑降采样」两项。
// - 有声书 cue 能量吸附：7 小时整本 = 1,260,000 帧 @20 ms，snap + refineEdges。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_compute/fushi_compute.dart';

const int _runs = 5;

int _medianUs(String label, void Function() body) {
  body();
  final List<int> us = <int>[];
  for (int i = 0; i < _runs; i++) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    us.add(sw.elapsedMicroseconds);
  }
  us.sort();
  final int median = us[us.length ~/ 2];
  stdout.writeln(
    '  ${label.padRight(58)} ${(median / 1000).toStringAsFixed(3).padLeft(10)} ms',
  );
  return median;
}

void _ratio(int oldUs, int newUs) {
  stdout.writeln(
    '  ${'=> speedup'.padRight(58)} ${(oldUs / newUs).toStringAsFixed(1).padLeft(10)} x',
  );
}

void _sameDoubles(List<double> a, List<double> b, String what) {
  final Float64List x = Float64List.fromList(a);
  final Float64List y = Float64List.fromList(b);
  if (x.length != y.length ||
      ffcSha256Bytes(x.buffer.asUint8List()) !=
          ffcSha256Bytes(y.buffer.asUint8List())) {
    stderr.writeln('MISMATCH: $what');
    exit(1);
  }
}

int _ordered(double v) {
  final int bits = (ByteData(8)..setFloat64(0, v)).getInt64(0);
  return bits >= 0 ? bits : -(bits & 0x7fffffffffffffff);
}

/// 依赖 libm `pow` 的输出：Dart VM 的 pow 与 Rust 调到的 CRT pow 不是同一份（见
/// native/fushi_compute/src/signal.rs），报告逐元素最大 ULP 偏差与不同元素数，超过 64 ULP 退出 1。
void _closeDoubles(List<double> a, List<double> b, String what) {
  if (a.length != b.length) {
    stderr.writeln('MISMATCH: $what length');
    exit(1);
  }
  int maxUlp = 0;
  int differing = 0;
  double maxAbs = 0;
  for (int i = 0; i < a.length; i++) {
    final int u = (_ordered(a[i]) - _ordered(b[i])).abs();
    if (u != 0) differing++;
    if (u > maxUlp) maxUlp = u;
    final double d = (a[i] - b[i]).abs();
    if (d > maxAbs) maxAbs = d;
  }
  stdout.writeln(
    '  $what: $differing / ${a.length} buckets differ, max $maxUlp ULP, max |Δ| $maxAbs',
  );
  if (maxUlp > 64) exit(1);
}

/// splitmix64。
final class _Rng {
  _Rng(this._s);
  int _s;
  int next() {
    _s = _s + 0x9E3779B97F4A7C15;
    int z = _s;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  double nextDouble() => (next() >>> 11) / 9007199254740992.0;
  int nextInt(int bound) => (next() >>> 1) % bound;
}

void main() {
  FushiCompute.require();
  stdout.writeln(
    '${Platform.operatingSystem} dart ${Platform.version.split(' ').first}',
  );
  final _Rng rng = _Rng(20261018);

  // ── 字幕自动对轴互相关 ──────────────────────────────────────────────────────
  stdout.writeln(
    'subtitle auto-align cross-correlation (12000 bins, ±150 bins)',
  );
  final List<double> audio = List<double>.filled(12000, 0.0);
  for (int i = 0; i < 12000;) {
    final int on = 5 + rng.nextInt(40);
    for (int k = i; k < i + on && k < 12000; k++) {
      audio[k] = 1.0;
    }
    i += on + 3 + rng.nextInt(30);
  }
  final List<double> cue = List<double>.generate(
    12000,
    (int i) => i >= 37 && audio[i - 37] > 0 ? 1.0 : 0.0,
  );
  late AlignResult oldAlign;
  late ({int shiftBins, double confidence})? newAlign;
  final int xOld = _medianUs('Dart bestOffsetMsByCrossCorrelation', () {
    oldAlign = bestOffsetMsByCrossCorrelation(audio, cue);
  });
  final int xNew = _medianUs('ffcXcorrBestShift', () {
    newAlign = ffcXcorrBestShift(audio, cue, binMs: 100, maxShiftMs: 15000);
  });
  _ratio(xOld, xNew);
  if (newAlign!.shiftBins * 100 != oldAlign.offsetMs ||
      newAlign!.confidence != oldAlign.confidence) {
    stderr.writeln('MISMATCH: xcorr');
    exit(1);
  }

  // ── galgame 波形逐窗 RMS ───────────────────────────────────────────────────
  for (final int seconds in <int>[10, 30]) {
    stdout.writeln('galgame waveform RMS (${seconds}s, 48 kHz stereo float32)');
    final Float32List samples = Float32List(48000 * seconds * 2);
    for (int i = 0; i < samples.length; i++) {
      samples[i] =
          (rng.nextDouble() - 0.5) * (i ~/ 48000 % 3 == 0 ? 0.001 : 0.8);
    }
    final Uint8List pcm = samples.buffer.asUint8List();
    const ({int sampleRate, int channels, int bitsPerSample, bool isFloat})
    fmt = (sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true);
    late List<double> a;
    late List<double> b;
    final int o = _medianUs('Dart pcmToEnergyEnvelope', () {
      a = pcmToEnergyEnvelope(pcm, fmt);
    });
    final int n = _medianUs('ffcPcmRmsDb', () {
      b = ffcPcmRmsDb(
        pcm,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 32,
        isFloat: true,
        windowMs: 20,
        silenceDb: -120.0,
      );
    });
    _ratio(o, n);
    _sameDoubles(a, b, 'pcm $seconds s');
  }

  // ── ffmpeg 逐帧 RMS 日志解析 ───────────────────────────────────────────────
  stdout.writeln('ffmpeg per-frame RMS log (60000 frames)');
  final StringBuffer log = StringBuffer();
  for (int i = 0; i < 60000; i++) {
    log
      ..write(
        'frame:$i    pts:${i * 160}  pts_time:${(i * 0.02).toStringAsFixed(2)}\n',
      )
      ..write(
        rng.nextInt(40) == 0
            ? 'lavfi.astats.Overall.RMS_level=-inf\n'
            : 'lavfi.astats.Overall.RMS_level='
                  '${(-90 + rng.nextDouble() * 85).toStringAsFixed(6)}\n',
      );
  }
  final Uint8List logBytes = Uint8List.fromList(utf8.encode(log.toString()));
  stdout.writeln('  (${logBytes.length} bytes)');
  late List<double> pa;
  late List<double> pb;
  final int po = _medianUs('Dart utf8.decode + RegExp.allMatches', () {
    pa = parseAudioRmsEnvelopeFromFfmpegLog(utf8.decode(logBytes));
  });
  final int pn = _medianUs('ffcParseRmsLog (bytes)', () {
    pb = ffcParseRmsLog(logBytes);
  });
  _ratio(po, pn);
  _sameDoubles(pa, pb, 'log');

  // ── 波形降采样 ─────────────────────────────────────────────────────────────
  stdout.writeln('waveform downsample (60000 frames -> 1366 buckets)');
  final List<double> frames = List<double>.from(pb);
  late List<double> da;
  late List<double> db;
  late List<double> dc;
  final int dOld = _medianUs('Dart downsampleEnergyEnvelope', () {
    da = downsampleEnergyEnvelope(frames, 1366);
  });
  final int dNew = _medianUs(
    'FfcEnergyEnvelope.fromDb + downsample (one-shot)',
    () {
      db = FfcEnergyEnvelope.fromDb(frames).downsample(1366);
    },
  );
  final FfcEnergyEnvelope cached = FfcEnergyEnvelope.fromDb(frames);
  final int dCached = _medianUs(
    'cached FfcEnergyEnvelope.downsample (width change)',
    () {
      dc = cached.downsample(1366);
    },
  );
  _ratio(dOld, dNew);
  _ratio(dOld, dCached);
  _closeDoubles(da, db, 'downsample');
  _closeDoubles(da, dc, 'downsample cached');

  // ── 有声书 cue 能量吸附 ────────────────────────────────────────────────────
  stdout.writeln('audiobook cue energy snap (7 h book, 1,260,000 frames)');
  const int bookFrames = 7 * 3600 * 50;
  final Int8List energy = Int8List(bookFrames);
  final List<(int, int, List<int>?)> spec = <(int, int, List<int>?)>[];
  for (int f = 0; f < bookFrames;) {
    final int on = 60 + rng.nextInt(300);
    for (int k = f; k < f + on && k < bookFrames; k++) {
      energy[k] = -30 + rng.nextInt(23);
    }
    final int startMs = f * 20 + rng.nextInt(300) - 150;
    f += on;
    final int off = rng.nextInt(4) == 0
        ? 2 + rng.nextInt(4)
        : 8 + rng.nextInt(30);
    for (int k = f; k < f + off && k < bookFrames; k++) {
      energy[k] = -70 + rng.nextInt(12);
    }
    final int endMs =
        (f + (rng.nextInt(2) == 0 ? off ~/ 2 : 0)) * 20 +
        rng.nextInt(200) -
        100;
    spec.add((
      startMs,
      endMs,
      rng.nextInt(3) == 0
          ? null
          : <int>[rng.nextInt(120), (endMs - startMs) ~/ 2],
    ));
    f += off;
  }
  // 让一半的 cue 紧挨下一条（切点在停顿里）。
  for (int i = 0; i + 1 < spec.length; i += 2) {
    spec[i] = (spec[i].$1, spec[i + 1].$1 - rng.nextInt(80), spec[i].$3);
  }
  stdout.writeln('  (${spec.length} cues)');
  List<AudioCue> cues() => <AudioCue>[
    for (final (int, int, List<int>?) s in spec)
      AudioCue()
        ..bookKey = 'b'
        ..chapterHref = ''
        ..sentenceIndex = 0
        ..textFragmentId = ''
        ..text = 'x'
        ..startMs = s.$1
        ..endMs = s.$2 > s.$1 ? s.$2 : s.$1 + 400
        ..audioFileIndex = 0
        ..tokenTiming = s.$3 == null
            ? null
            : CueTokenTiming(
                tokens: const <String>['a', 'b'],
                offsetsMs: s.$3!,
              ),
  ];
  late List<AudioCue> sa;
  late List<AudioCue> sb;
  final int sOld = _medianUs('Dart CueEnergySnapper snap + refineEdges', () {
    sa = cues();
    const OldCueEnergySnapper s = OldCueEnergySnapper();
    s.snap(sa, energy);
    s.refineEdges(sa, energy);
  });
  final int sNew = _medianUs(
    'CueEnergySnapper (ffc_signal_cue_*) snap + refineEdges',
    () {
      sb = cues();
      const CueEnergySnapper s = CueEnergySnapper();
      s.snap(sb, energy);
      s.refineEdges(sb, energy);
    },
  );
  _ratio(sOld, sNew);
  for (int i = 0; i < sa.length; i++) {
    if (sa[i].startMs != sb[i].startMs ||
        sa[i].endMs != sb[i].endMs ||
        '${sa[i].tokenTiming?.offsetsMs}' !=
            '${sb[i].tokenTiming?.offsetsMs}') {
      stderr.writeln('MISMATCH: snap cue $i');
      exit(1);
    }
  }
  stdout.writeln('all outputs identical');
}

// ======== 原样复制：fushi/lib/src/media/video/subtitle_auto_align.dart ========
enum SubtitleAutoAlignStatus { aligned, noData, lowConfidence }

typedef AlignResult = ({
  int offsetMs,
  double confidence,
  SubtitleAutoAlignStatus status,
});
const AlignResult _noData = (
  offsetMs: 0,
  confidence: 0.0,
  status: SubtitleAutoAlignStatus.noData,
);

AlignResult bestOffsetMsByCrossCorrelation(
  List<double> audioActivity,
  List<double> cueActivity, {
  int binMs = 100,
  int maxShiftMs = 15000,
  double minConfidence = 0.15,
}) {
  if (binMs <= 0 ||
      audioActivity.isEmpty ||
      cueActivity.isEmpty ||
      maxShiftMs < 0) {
    return _noData;
  }
  final double audioActiveCount = _activeCount(audioActivity);
  final double cueActiveCount = _activeCount(cueActivity);
  if (audioActiveCount <= 0 || cueActiveCount <= 0) {
    return _noData;
  }
  final double maxOverlap = math.min(audioActiveCount, cueActiveCount);

  final int maxShiftBins = maxShiftMs ~/ binMs;
  int bestShiftBins = 0;
  double bestOverlap = -1.0;
  for (int shift = -maxShiftBins; shift <= maxShiftBins; shift++) {
    final double overlap = _overlapAtShift(audioActivity, cueActivity, shift);
    if (overlap > bestOverlap ||
        (overlap == bestOverlap && shift.abs() < bestShiftBins.abs())) {
      bestOverlap = overlap;
      bestShiftBins = shift;
    }
  }

  final double confidence = maxOverlap > 0
      ? (bestOverlap / maxOverlap).clamp(0.0, 1.0)
      : 0.0;
  final int offsetMs = bestShiftBins * binMs;
  final SubtitleAutoAlignStatus status = confidence >= minConfidence
      ? SubtitleAutoAlignStatus.aligned
      : SubtitleAutoAlignStatus.lowConfidence;
  return (offsetMs: offsetMs, confidence: confidence, status: status);
}

double _activeCount(List<double> activity) {
  double sum = 0.0;
  for (final double v in activity) {
    if (v > 0) sum += v;
  }
  return sum;
}

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

// ======== 原样复制：fushi/lib/src/mining/galgame_waveform.dart（PcmFormat 拆成参数）========
List<double> pcmToEnergyEnvelope(
  Uint8List pcm,
  ({int sampleRate, int channels, int bitsPerSample, bool isFloat}) format, {
  int windowMs = 20,
  double silenceDb = -120.0,
}) {
  final int bytesPerSample = format.bitsPerSample ~/ 8;
  final int channels = format.channels;
  if (pcm.isEmpty ||
      channels <= 0 ||
      bytesPerSample <= 0 ||
      format.sampleRate <= 0 ||
      windowMs <= 0) {
    return const <double>[];
  }
  final ByteData bd = ByteData.sublistView(pcm);
  double? Function(int byteOffset)? decode;
  if (format.isFloat && format.bitsPerSample == 32) {
    decode = (o) => bd.getFloat32(o, Endian.little).toDouble();
  } else if (!format.isFloat && format.bitsPerSample == 16) {
    decode = (o) => bd.getInt16(o, Endian.little) / 32768.0;
  } else if (!format.isFloat && format.bitsPerSample == 32) {
    decode = (o) => bd.getInt32(o, Endian.little) / 2147483648.0;
  }
  if (decode == null) {
    return const <double>[];
  }

  final int frameBytes = channels * bytesPerSample;
  final int totalFrames = pcm.length ~/ frameBytes;
  if (totalFrames == 0) {
    return const <double>[];
  }
  final int framesPerWindow = math.max(
    1,
    (format.sampleRate * windowMs) ~/ 1000,
  );
  final double floorAmp = math.pow(10.0, silenceDb / 20.0).toDouble();

  final List<double> envelope = <double>[];
  for (int f0 = 0; f0 < totalFrames; f0 += framesPerWindow) {
    final int f1 = math.min(totalFrames, f0 + framesPerWindow);
    double sumSq = 0.0;
    int count = 0;
    for (int f = f0; f < f1; f++) {
      final int frameOffset = f * frameBytes;
      for (int c = 0; c < channels; c++) {
        final double s = decode(frameOffset + c * bytesPerSample)!;
        sumSq += s * s;
        count++;
      }
    }
    final double rms = count > 0 ? math.sqrt(sumSq / count) : 0.0;
    final double amp = rms < floorAmp ? floorAmp : rms;
    double db = 20.0 * (math.log(amp) / math.ln10);
    if (db > 0.0) db = 0.0;
    if (db < silenceDb) db = silenceDb;
    envelope.add(db);
  }
  return envelope;
}

// ======== 原样复制：fushi/lib/src/media/video/audio_energy_probe.dart ========
List<double> parseAudioRmsEnvelopeFromFfmpegLog(
  String ffmpegStderr, {
  double silenceDb = -120.0,
}) {
  if (ffmpegStderr.isEmpty) return const <double>[];
  final List<double> values = <double>[];
  final RegExp pattern = RegExp(
    r'lavfi\.astats\.Overall\.RMS_level\s*=\s*(-?\d+(?:\.\d+)?|-?inf)',
  );
  for (final RegExpMatch m in pattern.allMatches(ffmpegStderr)) {
    final String raw = m.group(1)!;
    if (raw == '-inf' || raw == 'inf') {
      values.add(silenceDb);
      continue;
    }
    final double? v = double.tryParse(raw);
    if (v == null) continue;
    values.add(v.isFinite ? v : silenceDb);
  }
  return values;
}

double dbToLinearAmplitude(double db) => math.pow(10.0, db / 20.0).toDouble();

double _percentileValue(List<double> values, double percentile) {
  if (values.isEmpty) return 0.0;
  final double p = percentile.clamp(0.0, 1.0).toDouble();
  final List<double> sorted = List<double>.of(values)..sort();
  final int idx = ((sorted.length - 1) * p).round();
  return sorted[idx];
}

List<double> downsampleEnergyEnvelope(
  List<double> frames,
  int targetBuckets, {
  double normalizeCeilingPercentile = 0.99,
}) {
  final int n = frames.length;
  if (n == 0 || targetBuckets <= 0) return <double>[];
  final int buckets = targetBuckets >= n ? n : targetBuckets;
  final List<double> peaks = List<double>.filled(buckets, 0.0);
  double minPeak = double.infinity;
  for (int b = 0; b < buckets; b++) {
    final int start = (b * n) ~/ buckets;
    final int end = ((b + 1) * n) ~/ buckets;
    double peak = dbToLinearAmplitude(frames[start]);
    for (int i = start + 1; i < end; i++) {
      final double amp = dbToLinearAmplitude(frames[i]);
      if (amp > peak) peak = amp;
    }
    peaks[b] = peak;
    if (peak < minPeak) minPeak = peak;
  }
  final double ceiling = _percentileValue(peaks, normalizeCeilingPercentile);
  final double range = ceiling - minPeak;
  if (range <= 0) return List<double>.filled(buckets, 0.0);
  for (int b = 0; b < buckets; b++) {
    final double v = (peaks[b] - minPeak) / range;
    peaks[b] = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
  }
  return peaks;
}

// ======== 原样复制：packages/fushi_audio/lib/src/matching/cue_energy_snapper.dart（删除前）========
class OldCueEnergySnapper {
  const OldCueEnergySnapper({
    this.frameMs = 20,
    this.maxGapMs = 400,
    this.windowMs = 600,
    this.minValleyMs = 120,
    this.distancePenalty = 0.5,
    this.tailMs = 80,
    this.leadMs = 40,
    this.minDurationMs = 500,
    this.floorMarginDb = 16,
    this.minThresholdDb = -50,
    this.maxThresholdDb = -30,
    this.tokenGuardMs = 200,
    this.edgeMaxShiftMs = 600,
    this.edgeMinVoiceMs = 60,
    this.edgeLeadMs = 150,
    this.edgeTailMs = 80,
  });

  /// [refineEdges]：终点留到收声后多少。春物卷 2 扫过 80 / 150：150 起点延迟
  /// p90 从 88 涨回 110~124 ms、尾挂变多，只换来提前截断少 3~9 条。
  final int edgeTailMs;

  /// [refineEdges]：起点挪到开口前多少。比 [leadMs] 宽——轻声开口（气声、清辅音）
  /// 常在门限下，40 ms 时字头被切（晚起 > 150 ms）11~16 条，150 ms 降到 7~8 条，
  /// 提前开始几乎不变（春物卷 2 扫 40 / 100 / 150）。
  final int edgeLeadMs;

  /// [refineEdges]：起止点最多往 cue 内收多远。
  final int edgeMaxShiftMs;

  /// [refineEdges]：多长的连续有声才算真开口 / 真收声（滤掉单帧噪声）。
  final int edgeMinVoiceMs;

  /// 包络帧长（与转录时写入的一致）。
  final int frameMs;

  /// 两条 cue 之间空隙超过此值就不算「紧挨着」（那是 VAD 已经切开的停顿）。
  final int maxGapMs;

  /// 在原切点前后多远内找谷。
  final int windowMs;

  /// 谷的最短长度：塞音闭塞只有几十毫秒，不算句间停顿。
  final int minValleyMs;

  /// 选谷打分 = 谷长 − 此系数 × 谷中心离原切点的距离（都按毫秒）。
  final double distancePenalty;

  /// 前句终点在谷起点之后留的余韵。
  final int tailMs;

  /// 后句起点在谷终点之前提前的量。
  final int leadMs;

  /// 吸附后两侧 cue 都不得短于此值，否则不动。
  final int minDurationMs;

  /// 门限 = 附近 ±15 s 电平第 10 百分位（底噪）+ 此值，夹到
  /// [[minThresholdDb], [maxThresholdDb]]。下限比能量 VAD（−55）高：−45 ~ −55 dB
  /// 的气声/混响尾巴听感上已是静音，按 −55 判会把前句终点推迟进停顿里。
  final double floorMarginDb;
  final double minThresholdDb;
  final double maxThresholdDb;

  /// 后句新起点不晚于它首 token 发射时刻 + 此值（RNN-T 首 token 一般早于开口，
  /// 比它还晚很多就是吸错了谷、会吃掉字头）。
  final int tokenGuardMs;

  static const int _floorBlockFrames = 250;
  static const int _floorSpanFrames = 750;

  /// [energyDb]：从时间 0 起每 [frameMs] 一帧的电平（整数 dBFS，0 = 未知，按有声
  /// 处理）。就地修改 [cues] 的起止时间，返回挪动的切点数。
  int snap(List<AudioCue> cues, Int8List energyDb) {
    final int n = energyDb.length;
    if (n == 0 || cues.length < 2) return 0;
    final Float64List threshold = _thresholds(energyDb);
    bool quiet(int f) {
      final int v = energyDb[f];
      return v != 0 && v < threshold[f];
    }

    final int minValley = (minValleyMs / frameMs).ceil();
    int moved = 0;
    for (int i = 0; i + 1 < cues.length; i++) {
      final AudioCue cur = cues[i];
      final AudioCue next = cues[i + 1];
      if (cur.audioFileIndex != next.audioFileIndex) continue;
      final int gap = next.startMs - cur.endMs;
      if (gap < 0 || gap > maxGapMs) continue;
      final int b = (cur.endMs + next.startMs) ~/ 2;
      final int f0 = math.max(0, (b - windowMs) ~/ frameMs);
      final int f1 = math.min(n, (b + windowMs) ~/ frameMs);
      int best = -1;
      int bestLen = 0;
      double bestScore = 0;
      int f = f0;
      while (f < f1) {
        if (!quiet(f)) {
          f++;
          continue;
        }
        // 窗口只限定谷落在哪，谷本身量到真实的两端（不被窗口边截断）。
        int s = f;
        while (s > 0 && quiet(s - 1)) {
          s--;
        }
        while (f < n && quiet(f)) {
          f++;
        }
        final int len = f - s;
        if (len < minValley) continue;
        final double center = (s + f) * frameMs / 2;
        final double score =
            len * frameMs - distancePenalty * (center - b).abs();
        if (best < 0 || score > bestScore) {
          best = s;
          bestLen = len;
          bestScore = score;
        }
      }
      if (best < 0) continue;
      final int valleyStart = best * frameMs;
      final int valleyEnd = (best + bestLen) * frameMs;
      final int end = math.min(valleyStart + tailMs, valleyEnd);
      final int start = math.max(
        math.max(valleyEnd - leadMs, valleyStart),
        end,
      );
      if (end - cur.startMs < minDurationMs ||
          next.endMs - start < minDurationMs) {
        continue;
      }
      final int? firstToken = _firstTokenMs(next);
      if (firstToken != null && start > firstToken + tokenGuardMs) continue;
      _shiftStart(next, start);
      cur.endMs = end;
      moved++;
    }
    return moved;
  }

  /// 起止点落在静音里时收回到真实有声处（[snap] 之后跑）。
  ///
  /// [snap] 只管紧挨着的两条 cue；前面是长停顿的起点、后面是长停顿的终点它不碰，
  /// 而那里恰是 token 时刻粗的模型（Kitsune CTC 80 ms 一帧、多字 token 线性摊开，
  /// 同一字相对 RNN-T ±200 ms 散布）最常把字幕挂进静音的地方：
  /// - 起点所在帧是静音 → 往后 [edgeMaxShiftMs] 内找第一段 ≥ [edgeMinVoiceMs] 的
  ///   有声，起点挪到它 − [leadMs]；
  /// - 终点前一帧是静音 → 往前同样找最后一段有声，终点收到它 + [tailMs]，但不早于
  ///   末 token 发射时刻 − [tokenGuardMs]。
  ///
  /// 只往 cue 内部收，不越界、不动文本；挪完短于 [minDurationMs] 的不动。返回
  /// 挪动的边数。
  int refineEdges(List<AudioCue> cues, Int8List energyDb) {
    final int n = energyDb.length;
    if (n == 0 || cues.isEmpty) return 0;
    final Float64List threshold = _thresholds(energyDb);
    bool quiet(int f) {
      final int v = energyDb[f];
      return v != 0 && v < threshold[f];
    }

    final int maxShift = edgeMaxShiftMs ~/ frameMs;
    final int minVoice = (edgeMinVoiceMs / frameMs).ceil();
    int moved = 0;
    for (final AudioCue cue in cues) {
      final int fs = cue.startMs ~/ frameMs;
      if (fs >= 0 && fs < n && quiet(fs)) {
        int f = fs;
        final int limit = math.min(n, fs + maxShift);
        int onset = -1;
        while (f < limit) {
          if (quiet(f)) {
            f++;
            continue;
          }
          int g = f;
          while (g < n && !quiet(g) && g - f < minVoice) {
            g++;
          }
          if (g - f >= minVoice) {
            onset = f;
            break;
          }
          f = g;
        }
        if (onset >= 0) {
          final int start = math.max(cue.startMs, onset * frameMs - edgeLeadMs);
          if (start > cue.startMs && cue.endMs - start >= minDurationMs) {
            _shiftStart(cue, start);
            moved++;
          }
        }
      }
      final int fe = (cue.endMs - 1) ~/ frameMs;
      if (fe >= 0 && fe < n && quiet(fe)) {
        int f = fe;
        final int limit = math.max(-1, fe - maxShift);
        int offset = -1;
        while (f > limit) {
          if (quiet(f)) {
            f--;
            continue;
          }
          int g = f;
          while (g >= 0 && !quiet(g) && f - g < minVoice) {
            g--;
          }
          if (f - g >= minVoice) {
            offset = f;
            break;
          }
          f = g;
        }
        if (offset >= 0) {
          final int end = math.min(
            cue.endMs,
            (offset + 1) * frameMs + edgeTailMs,
          );
          final int? lastToken = _lastTokenMs(cue);
          if (end < cue.endMs &&
              end - cue.startMs >= minDurationMs &&
              (lastToken == null || end >= lastToken - tokenGuardMs)) {
            cue.endMs = end;
            moved++;
          }
        }
      }
    }
    return moved;
  }

  static int? _lastTokenMs(AudioCue cue) {
    final CueTokenTiming? t = cue.tokenTiming;
    if (t == null || t.isEmpty) return null;
    return cue.startMs + t.offsetsMs.last;
  }

  /// 每帧的门限（按 [_floorBlockFrames] 一块算一次局部底噪）。未知帧不参与。
  Float64List _thresholds(Int8List db) {
    final int n = db.length;
    final Float64List out = Float64List(n);
    final List<int> window = <int>[];
    for (int b0 = 0; b0 < n; b0 += _floorBlockFrames) {
      final int lo = math.max(0, b0 - _floorSpanFrames);
      final int hi = math.min(n, b0 + _floorBlockFrames + _floorSpanFrames);
      window.clear();
      for (int k = lo; k < hi; k++) {
        if (db[k] != 0) window.add(db[k]);
      }
      double t = maxThresholdDb;
      if (window.isNotEmpty) {
        window.sort();
        final double floor = window[((window.length - 1) * 10 / 100).round()]
            .toDouble();
        t = (floor + floorMarginDb).clamp(minThresholdDb, maxThresholdDb);
      }
      final int end = math.min(n, b0 + _floorBlockFrames);
      for (int k = b0; k < end; k++) {
        out[k] = t;
      }
    }
    return out;
  }

  static int? _firstTokenMs(AudioCue cue) {
    final CueTokenTiming? t = cue.tokenTiming;
    if (t == null || t.isEmpty) return null;
    return cue.startMs + t.offsetsMs.first;
  }

  /// 挪起点时 token 偏移（相对起点）一起平移，绝对发射时刻不变。
  static void _shiftStart(AudioCue cue, int start) {
    final CueTokenTiming? t = cue.tokenTiming;
    final int delta = start - cue.startMs;
    cue.startMs = start;
    if (t == null || t.isEmpty || delta == 0) return;
    cue.tokenTiming = CueTokenTiming(
      tokens: t.tokens,
      offsetsMs: List<int>.unmodifiable(
        t.offsetsMs.map((int o) => math.max(0, o - delta)),
      ),
    );
  }
}
