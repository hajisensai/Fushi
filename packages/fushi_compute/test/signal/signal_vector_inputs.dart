// ffc_signal_* 回归向量的确定性输入（只依赖 dart:core / dart:typed_data / dart:convert）。
//
// 冻结向量（test/fixtures/signal_vectors.json）由删除前的纯 Dart 实现对这里生成的输入
// 算出；测试端用同一份代码重新生成输入，再与 Rust 输出逐位比对。改这里的任何一个数字
// 都会让向量作废——只能追加新用例，不能改旧用例。
library;

import 'dart:convert';
import 'dart:typed_data';

/// splitmix64：跨平台确定（Dart VM 的 int 是 64 位补码，乘法按 2^64 回绕）。
final class VectorRng {
  VectorRng(this._state);

  int _state;

  int nextU64() {
    _state = _state + 0x9E3779B97F4A7C15;
    int z = _state;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  /// [0, 1)，53 位。
  double nextDouble() => (nextU64() >>> 11) / 9007199254740992.0;

  /// [0, bound)。
  int nextInt(int bound) => (nextU64() >>> 1) % bound;
}

// ── 互相关 ────────────────────────────────────────────────────────────────────

/// 互相关用例：音频活动、cue 活动、binMs、maxShiftMs。
typedef XcorrCase = ({
  String id,
  List<double> audio,
  List<double> cue,
  int binMs,
  int maxShiftMs,
});

/// 一段「说话 / 静音」交替的 0/1 活动序列。
List<double> _speechActivity(VectorRng rng, int length, {double fill = 1.0}) {
  final List<double> out = List<double>.filled(length, 0.0);
  int i = rng.nextInt(20);
  while (i < length) {
    final int on = 5 + rng.nextInt(40);
    for (int k = i; k < i + on && k < length; k++) {
      out[k] = fill;
    }
    i += on + 3 + rng.nextInt(30);
  }
  return out;
}

List<XcorrCase> xcorrCases() {
  final List<XcorrCase> cases = <XcorrCase>[
    (
      id: 'empty-audio',
      audio: <double>[],
      cue: <double>[1, 1],
      binMs: 100,
      maxShiftMs: 15000,
    ),
    (
      id: 'empty-cue',
      audio: <double>[1, 0],
      cue: <double>[],
      binMs: 100,
      maxShiftMs: 15000,
    ),
    (
      id: 'silent-audio',
      audio: <double>[0, 0, 0],
      cue: <double>[1, 1, 1],
      binMs: 100,
      maxShiftMs: 15000,
    ),
    (
      id: 'bin-zero',
      audio: <double>[1, 1],
      cue: <double>[1, 1],
      binMs: 0,
      maxShiftMs: 15000,
    ),
    (
      id: 'shift-negative',
      audio: <double>[1, 1],
      cue: <double>[1, 1],
      binMs: 100,
      maxShiftMs: -1,
    ),
    (
      id: 'shift-zero',
      audio: <double>[0, 1, 1, 0],
      cue: <double>[1, 1, 0, 0],
      binMs: 100,
      maxShiftMs: 0,
    ),
    (
      id: 'tie-prefers-small-shift',
      audio: <double>[1, 0, 1, 0, 1, 0, 1, 0],
      cue: <double>[1, 0, 1, 0, 1, 0, 1, 0],
      binMs: 100,
      maxShiftMs: 400,
    ),
    (
      id: 'tie-negative-vs-positive',
      audio: <double>[0, 0, 1, 0, 0],
      cue: <double>[0, 1, 0, 1, 0],
      binMs: 100,
      maxShiftMs: 300,
    ),
    (
      id: 'fractional-and-nan',
      audio: <double>[0.5, double.nan, 0.25, -1, 0.75, 1, 0, 0.125],
      cue: <double>[double.nan, 0.5, 1, 1, -0.5, 0.25],
      binMs: 50,
      maxShiftMs: 250,
    ),
    (
      id: 'max-shift-beyond-length',
      audio: <double>[0, 0, 1, 1, 0],
      cue: <double>[1, 1, 0],
      binMs: 10,
      maxShiftMs: 100000,
    ),
  ];
  // 真实规模：20 分钟 @100ms = 12000 格，字幕比音频晚 37 格、加噪。
  final VectorRng rng = VectorRng(701);
  final List<double> audio = _speechActivity(rng, 12000);
  final List<double> cue = List<double>.filled(12000, 0.0);
  for (int i = 0; i < 12000; i++) {
    final int j = i - 37;
    if (j >= 0 && audio[j] > 0) cue[i] = 1.0;
    if (rng.nextInt(50) == 0) cue[i] = 1.0 - cue[i];
  }
  cases.add((
    id: 'movie-20min',
    audio: audio,
    cue: cue,
    binMs: 100,
    maxShiftMs: 15000,
  ));
  cases.add((
    id: 'movie-20min-reversed-roles',
    audio: cue,
    cue: audio,
    binMs: 100,
    maxShiftMs: 15000,
  ));
  // 长度不等、带分数权重。
  final VectorRng rng2 = VectorRng(702);
  final List<double> a2 = List<double>.generate(
    3000,
    (_) => rng2.nextInt(3) == 0 ? rng2.nextDouble() : 0.0,
  );
  final List<double> c2 = List<double>.generate(
    2800,
    (_) => rng2.nextInt(4) == 0 ? rng2.nextDouble() : 0.0,
  );
  cases.add((
    id: 'fractional-3000x2800',
    audio: a2,
    cue: c2,
    binMs: 50,
    maxShiftMs: 7000,
  ));
  // 低置信：互不相关的随机序列。
  final VectorRng rng3 = VectorRng(703);
  cases.add((
    id: 'uncorrelated-low-confidence',
    audio: List<double>.generate(600, (_) => rng3.nextInt(9) == 0 ? 1.0 : 0.0),
    cue: List<double>.generate(600, (_) => rng3.nextInt(9) == 0 ? 1.0 : 0.0),
    binMs: 100,
    maxShiftMs: 2000,
  ));
  return cases;
}

// ── 逐窗 RMS（galgame 波形）────────────────────────────────────────────────────

typedef PcmCase = ({
  String id,
  Uint8List pcm,
  int sampleRate,
  int channels,
  int bitsPerSample,
  bool isFloat,
  int windowMs,
  double silenceDb,
});

/// 说话样的 PCM：正弦突发 + 静音 + 噪声，[frames] 帧、每帧 [channels] 个 [-1,1] 采样。
List<double> _speechSamples(VectorRng rng, int frames, int channels) {
  final List<double> out = List<double>.filled(frames * channels, 0.0);
  int f = 0;
  while (f < frames) {
    final int on = 200 + rng.nextInt(4000);
    final double amp = rng.nextDouble();
    final double step = 0.01 + rng.nextDouble() * 0.2;
    for (int k = 0; k < on && f + k < frames; k++) {
      for (int c = 0; c < channels; c++) {
        // 不用 sin（避免引入平台 libm 差异到输入里）：三角波 + 噪声。
        final double phase = ((f + k) * step) % 2.0;
        final double tri = phase < 1.0 ? phase * 2 - 1 : 3 - phase * 2;
        out[(f + k) * channels + c] =
            amp * tri * 0.8 + (rng.nextDouble() - 0.5) * 0.02 * amp;
      }
    }
    f += on;
    final int off = rng.nextInt(3000);
    f += off; // 留 0（纯静音）
  }
  return out;
}

Uint8List _int16(List<double> s) {
  final ByteData bd = ByteData(s.length * 2);
  for (int i = 0; i < s.length; i++) {
    bd.setInt16(
      i * 2,
      (s[i] * 32767).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return bd.buffer.asUint8List();
}

Uint8List _int32(List<double> s) {
  final ByteData bd = ByteData(s.length * 4);
  for (int i = 0; i < s.length; i++) {
    bd.setInt32(
      i * 4,
      (s[i] * 2147483647).round().clamp(-2147483648, 2147483647),
      Endian.little,
    );
  }
  return bd.buffer.asUint8List();
}

Uint8List _float32(List<double> s) {
  final ByteData bd = ByteData(s.length * 4);
  for (int i = 0; i < s.length; i++) {
    bd.setFloat32(i * 4, s[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

List<PcmCase> pcmCases() {
  final VectorRng rng = VectorRng(801);
  final Uint8List mono16 = _int16(_speechSamples(rng, 16000 * 3, 1));
  // 立体声 int16，末尾多 3 个字节（半帧）。
  final Uint8List st16Base = _int16(_speechSamples(rng, 44100 * 2, 2));
  final Uint8List st16 = Uint8List(st16Base.length + 3)
    ..setRange(0, st16Base.length, st16Base);
  final Uint8List mono32 = _int32(_speechSamples(rng, 48000 * 2, 1));
  final List<double> floatSamples = _speechSamples(rng, 48000 * 10, 2);
  // 越界与非有限值：> 1 的样本（db 夹到 0）、NaN / inf（整窗 NaN / inf）。
  floatSamples[1000] = 3.5;
  floatSamples[1001] = -4.25;
  for (int i = 200000; i < 200100; i++) {
    floatSamples[i] = 1.75;
  }
  floatSamples[300001] = double.nan;
  floatSamples[400002] = double.infinity;
  final Uint8List st32f = _float32(floatSamples);
  final Uint8List tiny = _int16(<double>[
    0.5,
    -0.5,
    0.25,
    0,
    0,
    0,
    1,
    -1,
    0.001,
  ]);
  return <PcmCase>[
    (
      id: 'int16-mono-16k',
      pcm: mono16,
      sampleRate: 16000,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
      windowMs: 20,
      silenceDb: -120.0,
    ),
    (
      id: 'int16-stereo-44k-partial-frame',
      pcm: st16,
      sampleRate: 44100,
      channels: 2,
      bitsPerSample: 16,
      isFloat: false,
      windowMs: 20,
      silenceDb: -120.0,
    ),
    (
      id: 'int32-mono-48k-window7',
      pcm: mono32,
      sampleRate: 48000,
      channels: 1,
      bitsPerSample: 32,
      isFloat: false,
      windowMs: 7,
      silenceDb: -120.0,
    ),
    (
      id: 'float32-stereo-48k-10s',
      pcm: st32f,
      sampleRate: 48000,
      channels: 2,
      bitsPerSample: 32,
      isFloat: true,
      windowMs: 20,
      silenceDb: -120.0,
    ),
    (
      id: 'float32-stereo-floor-90',
      pcm: st32f,
      sampleRate: 48000,
      channels: 2,
      bitsPerSample: 32,
      isFloat: true,
      windowMs: 33,
      silenceDb: -90.0,
    ),
    (
      id: 'int16-low-rate-one-frame-window',
      pcm: tiny,
      sampleRate: 100,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
      windowMs: 5,
      silenceDb: -120.0,
    ),
    (
      id: 'int16-tiny-window-larger-than-input',
      pcm: tiny,
      sampleRate: 8000,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
      windowMs: 20,
      silenceDb: -60.0,
    ),
    (
      id: 'empty',
      pcm: Uint8List(0),
      sampleRate: 48000,
      channels: 2,
      bitsPerSample: 16,
      isFloat: false,
      windowMs: 20,
      silenceDb: -120.0,
    ),
    (
      id: 'shorter-than-one-frame',
      pcm: Uint8List(3),
      sampleRate: 48000,
      channels: 2,
      bitsPerSample: 16,
      isFloat: false,
      windowMs: 20,
      silenceDb: -120.0,
    ),
    (
      id: 'unsupported-24bit',
      pcm: Uint8List(600),
      sampleRate: 48000,
      channels: 1,
      bitsPerSample: 24,
      isFloat: false,
      windowMs: 20,
      silenceDb: -120.0,
    ),
    (
      id: 'unsupported-float16',
      pcm: Uint8List(600),
      sampleRate: 48000,
      channels: 1,
      bitsPerSample: 16,
      isFloat: true,
      windowMs: 20,
      silenceDb: -120.0,
    ),
    (
      id: 'channels-zero',
      pcm: Uint8List(600),
      sampleRate: 48000,
      channels: 0,
      bitsPerSample: 16,
      isFloat: false,
      windowMs: 20,
      silenceDb: -120.0,
    ),
    (
      id: 'window-zero',
      pcm: mono16,
      sampleRate: 16000,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
      windowMs: 0,
      silenceDb: -120.0,
    ),
    (
      id: 'rate-zero',
      pcm: mono16,
      sampleRate: 0,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
      windowMs: 20,
      silenceDb: -120.0,
    ),
  ];
}

// ── ffmpeg ametadata 逐帧 RMS 日志解析 ─────────────────────────────────────────

typedef LogCase = ({String id, Uint8List bytes, double silenceDb});

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

List<LogCase> logCases() {
  const String key = 'lavfi.astats.Overall.RMS_level';
  final StringBuffer big = StringBuffer();
  final VectorRng rng = VectorRng(901);
  for (int i = 0; i < 60000; i++) {
    big..write(
      'frame:$i    pts:${i * 160}  pts_time:${(i * 0.02).toStringAsFixed(2)}\n',
    );
    if (rng.nextInt(40) == 0) {
      big.write('$key=-inf\n');
    } else {
      big.write('$key=${(-90 + rng.nextDouble() * 85).toStringAsFixed(6)}\n');
    }
  }
  final String hugeDigits = '9' * 400;
  return <LogCase>[
    (id: 'empty', bytes: Uint8List(0), silenceDb: -120.0),
    (
      id: 'no-match',
      bytes: _utf8('Stream #0:0: Audio: aac\nsize=N/A time=00:00:01\n'),
      silenceDb: -120.0,
    ),
    (
      id: 'typical-pairs',
      bytes: _utf8(
        'frame:0    pts:0       pts_time:0\n$key=-30.123456\n'
        'frame:1    pts:800     pts_time:0.1\n$key=-22.500000\n'
        'frame:2    pts:1600    pts_time:0.2\n$key=-inf\n',
      ),
      silenceDb: -120.0,
    ),
    (
      id: 'edge-forms',
      bytes: _utf8(
        '$key=inf\n$key = -12.5\n$key\t=\t-3\n$key=1.\n$key=-0\n$key=-0.0\n'
        '$key=0001.2500\n$key=$hugeDigits\n$key=-$hugeDigits.5\n$key=- 5\n$key=--3\n'
        '${key}X=3\n$key=nan\n$key=.5\n$key=1e5\n$key=$key=7.25\n$key=\r\n-4\r\n'
        'xx$key=-1.5yy\n$key=12.\n$key=-inff\n$key=infinity\n',
      ),
      silenceDb: -99.5,
    ),
    (
      id: 'unicode-whitespace',
      bytes: _utf8(
        '$key =　-1.25\n$key﻿= -2.5\n$key = -3.75\n'
        '$key\u0085=-9\n$key​=-8\n$key =\u000b\u000c-4.5\n'
        '日本語のログ $key=-6.5 終わり\n$key=\u{1F600}-1\n',
      ),
      silenceDb: -120.0,
    ),
    (id: 'big-60k-frames', bytes: _utf8(big.toString()), silenceDb: -120.0),
    (
      id: 'invalid-utf8',
      bytes: Uint8List.fromList(<int>[
        ...utf8.encode('$key=-1.5\n'),
        0xff,
        0xfe,
        ...utf8.encode('$key=-2\n'),
      ]),
      silenceDb: -120.0,
    ),
    (
      id: 'overlong-utf8',
      bytes: Uint8List.fromList(<int>[
        ...utf8.encode('$key='),
        0xc0,
        0xad,
        0x31,
      ]),
      silenceDb: -120.0,
    ),
    (
      id: 'surrogate-utf8',
      bytes: Uint8List.fromList(<int>[
        ...utf8.encode('$key=-1\n'),
        0xed,
        0xa0,
        0x80,
      ]),
      silenceDb: -120.0,
    ),
    (
      id: 'truncated-utf8',
      bytes: Uint8List.fromList(<int>[...utf8.encode('$key=-1\n'), 0xe3, 0x81]),
      silenceDb: -120.0,
    ),
    (
      id: 'bom',
      bytes: Uint8List.fromList(<int>[
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('$key=-1\n'),
      ]),
      silenceDb: -120.0,
    ),
  ];
}

// ── 能量包络降采样 ─────────────────────────────────────────────────────────────

typedef DownsampleCase = ({
  String id,
  List<double> frames,
  int targetBuckets,
  double percentile,
});

List<DownsampleCase> downsampleCases() {
  final VectorRng rng = VectorRng(1001);
  // 20 分钟 @20ms 的 dB 包络：语音段 −35..−10，静音段 −120 / −75..−60 底噪，偶发爆音 0。
  final List<double> big = List<double>.filled(60000, -120.0);
  int i = 0;
  while (i < big.length) {
    final int on = 10 + rng.nextInt(150);
    for (int k = i; k < i + on && k < big.length; k++) {
      big[k] = -35 + rng.nextDouble() * 25;
    }
    i += on;
    final int off = 5 + rng.nextInt(60);
    for (int k = i; k < i + off && k < big.length; k++) {
      big[k] = rng.nextInt(3) == 0 ? -120.0 : -75 + rng.nextDouble() * 15;
    }
    i += off;
  }
  for (int k = 0; k < 30; k++) {
    big[rng.nextInt(big.length)] = 0.0;
  }
  final List<double> withNan = List<double>.of(big.sublist(0, 5000));
  withNan[17] = double.nan;
  withNan[2500] = double.nan;
  withNan[2501] = double.infinity;
  withNan[2502] = double.negativeInfinity;
  return <DownsampleCase>[
    (id: 'empty', frames: <double>[], targetBuckets: 100, percentile: 0.99),
    (
      id: 'buckets-zero',
      frames: <double>[-10, -20],
      targetBuckets: 0,
      percentile: 0.99,
    ),
    (
      id: 'buckets-negative',
      frames: <double>[-10, -20],
      targetBuckets: -5,
      percentile: 0.99,
    ),
    (
      id: 'single-frame',
      frames: <double>[-42.0],
      targetBuckets: 100,
      percentile: 0.99,
    ),
    (
      id: 'three-frames-one-bucket',
      frames: <double>[-30, -20, -10],
      targetBuckets: 1,
      percentile: 0.99,
    ),
    (
      id: 'three-frames-three-buckets',
      frames: <double>[-30, -20, -10],
      targetBuckets: 3,
      percentile: 0.99,
    ),
    (
      id: 'all-silence',
      frames: <double>[-120, -120, -120, -120],
      targetBuckets: 2,
      percentile: 0.99,
    ),
    (id: 'big-1', frames: big, targetBuckets: 1, percentile: 0.99),
    (id: 'big-7', frames: big, targetBuckets: 7, percentile: 0.99),
    (id: 'big-600', frames: big, targetBuckets: 600, percentile: 0.99),
    (id: 'big-1366', frames: big, targetBuckets: 1366, percentile: 0.99),
    (id: 'big-4000-p50', frames: big, targetBuckets: 4000, percentile: 0.5),
    (id: 'big-4000-p100', frames: big, targetBuckets: 4000, percentile: 1.0),
    (id: 'big-4000-p0', frames: big, targetBuckets: 4000, percentile: 0.0),
    (
      id: 'big-4000-p-clamp-high',
      frames: big,
      targetBuckets: 4000,
      percentile: 1.5,
    ),
    (
      id: 'big-4000-p-clamp-low',
      frames: big,
      targetBuckets: 4000,
      percentile: -0.3,
    ),
    (
      id: 'big-600-p-nan',
      frames: big,
      targetBuckets: 600,
      percentile: double.nan,
    ),
    (id: 'big-59999', frames: big, targetBuckets: 59999, percentile: 0.99),
    (id: 'big-60000', frames: big, targetBuckets: 60000, percentile: 0.99),
    (id: 'big-over', frames: big, targetBuckets: 100000, percentile: 0.99),
    (
      id: 'non-finite-300',
      frames: withNan,
      targetBuckets: 300,
      percentile: 0.99,
    ),
    (
      id: 'non-finite-5000',
      frames: withNan,
      targetBuckets: 5000,
      percentile: 0.99,
    ),
  ];
}
