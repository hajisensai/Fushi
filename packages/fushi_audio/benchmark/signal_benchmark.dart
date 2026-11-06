// 信号处理调用点基准：删除前的纯 Dart 实现（原样复制在本文件下半部分）vs
// native/fushi_compute 的 ffc_signal_*。两条路径的结果逐位比对，不一致直接退出 1。
// （有声书 cue 能量吸附已迁到上游 fushi-subtitles，基准在 packages/fushi_engine/benchmark/
// asr_cue_post_benchmark.dart。）
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
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
