// ffc_signal_* 回归测试：冻结向量 test/fixtures/signal_vectors.json 由删除前的纯 Dart 实现
// （fushi 的 subtitle_auto_align / galgame_waveform / audio_energy_probe，2026-10-18，Windows x64）
// 对 signal_vector_inputs.dart 生成的输入算出。cue 能量吸附那段已随算法迁到上游 fushi-subtitles
// （packages/asr_subtitles/test/fixtures/cue_post_vectors.json）。
//
// 互相关、日志解析是纯整数 / 四则运算：逐位比对（≤ 64 个元素比 IEEE 位模式，
// 更长的比整段小端字节的 SHA-256）。
// 例外（说明见 native/fushi_compute/src/signal.rs 文件头）：逐窗 RMS（`log`）与降采样（`pow`）
// 调 libm。Dart VM 的 `pow` 不是 Rust 能调到的那一份（Windows 上 dart.exe 静态链接自己那版
// CRT：60000 个 dB 值里 11 个与 ucrtbase 的 `pow` 差 1 ULP，与 Rust 静态链 CRT 差 97 个；
// Flutter 引擎又是另一份），旧实现的输出本身就随宿主变化，所以这两类按 ULP 容差比。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

import 'signal_vector_inputs.dart';

String _hex(double v) {
  final ByteData bd = ByteData(8)..setFloat64(0, v);
  return bd.getUint32(0).toRadixString(16).padLeft(8, '0') +
      bd.getUint32(4).toRadixString(16).padLeft(8, '0');
}

double _fromHex(String hex) {
  final ByteData bd = ByteData(8)
    ..setUint32(0, int.parse(hex.substring(0, 8), radix: 16))
    ..setUint32(4, int.parse(hex.substring(8), radix: 16));
  return bd.getFloat64(0);
}

Map<String, Object?> _fixture() {
  final File file = File('test/fixtures/signal_vectors.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

Map<String, Map<String, Object?>> _byId(
  Object? list,
) => <String, Map<String, Object?>>{
  for (final Object? e in list! as List<Object?>)
    (e! as Map<String, Object?>)['id']! as String: e as Map<String, Object?>,
};

/// IEEE 位模式按数值排序后的整数（相邻 double 差 1；±0 都是 0）。
int _ordered(double v) {
  final int bits = (ByteData(8)..setFloat64(0, v)).getInt64(0);
  return bits >= 0 ? bits : -(bits & 0x7fffffffffffffff);
}

/// 依赖 libm `pow` 的输出允许的 ULP 偏差上限（见文件头）。
const int _libmMaxUlp = 64;

/// 比 [actual] 与冻结的 [expected]。默认逐位（≤ 64 个元素比位模式，更长的比 SHA-256）；
/// [libmDependent] 时逐个元素比 ULP 距离（≤ [_libmMaxUlp]，NaN 对 NaN），元素取自全量
/// `values` / `b64`，太长的只存了 64 个抽样点。
void _expectDoubles(
  List<double> actual,
  Map<String, Object?> expected, {
  bool libmDependent = false,
}) {
  expect(actual.length, expected['length'], reason: 'length');
  final Float64List list = Float64List.fromList(actual);
  final Object? values = expected['values'];
  if (!libmDependent) {
    if (values is List<Object?>) {
      expect(<String>[for (final double v in list) _hex(v)], values);
    } else {
      expect(ffcSha256Bytes(list.buffer.asUint8List()), expected['sha256']);
    }
    return;
  }
  final List<(int, double)> want = <(int, double)>[];
  final Object? b64 = expected['b64'];
  if (values is List<Object?>) {
    for (int i = 0; i < values.length; i++) {
      want.add((i, _fromHex(values[i]! as String)));
    }
  } else if (b64 is String) {
    final Float64List all = Uint8List.fromList(
      base64.decode(b64),
    ).buffer.asFloat64List();
    for (int i = 0; i < all.length; i++) {
      want.add((i, all[i]));
    }
  } else {
    for (final Object? pair in expected['sample']! as List<Object?>) {
      final List<Object?> p = pair! as List<Object?>;
      want.add((p[0]! as int, _fromHex(p[1]! as String)));
    }
  }
  for (final (int index, double w) in want) {
    final double got = list[index];
    if (w.isNaN || got.isNaN) {
      expect(got.isNaN, w.isNaN, reason: 'index $index: $got vs $w');
      continue;
    }
    final int ulps = (_ordered(got) - _ordered(w)).abs();
    expect(
      ulps,
      lessThanOrEqualTo(_libmMaxUlp),
      reason: 'index $index: $got vs $w ($ulps ULP)',
    );
  }
}

void main() {
  final Map<String, Object?> fixture = _fixture();

  group('ffcXcorrBestShift（字幕自动对轴互相关）', () {
    final Map<String, Map<String, Object?>> want = _byId(fixture['xcorr']);
    for (final XcorrCase c in xcorrCases()) {
      test(c.id, () {
        final ({int shiftBins, double confidence})? r = ffcXcorrBestShift(
          c.audio,
          c.cue,
          binMs: c.binMs,
          maxShiftMs: c.maxShiftMs,
        );
        final Map<String, Object?> w = want[c.id]!;
        if (w['status'] == 'noData') {
          expect(r, isNull);
          return;
        }
        expect(r, isNotNull);
        expect(r!.shiftBins * c.binMs, w['offsetMs']);
        expect(_hex(r.confidence), w['confidence']);
        // 状态门限（0.15）在 Dart 侧：这里核对冻结的状态与置信度一致。
        expect(r.confidence >= 0.15 ? 'aligned' : 'lowConfidence', w['status']);
      });
    }
    test(
      '用例集完整',
      () => expect(
        want.keys,
        unorderedEquals(xcorrCases().map((XcorrCase c) => c.id)),
      ),
    );
  });

  group('ffcPcmRmsDb（galgame 波形逐窗 RMS）', () {
    final Map<String, Map<String, Object?>> want = _byId(fixture['pcm']);
    for (final PcmCase c in pcmCases()) {
      test(c.id, () {
        final Float64List out = ffcPcmRmsDb(
          c.pcm,
          sampleRate: c.sampleRate,
          channels: c.channels,
          bitsPerSample: c.bitsPerSample,
          isFloat: c.isFloat,
          windowMs: c.windowMs,
          silenceDb: c.silenceDb,
        );
        _expectDoubles(out, want[c.id]!, libmDependent: true);
      });
    }
  });

  group('ffcParseRmsLog（ffmpeg 逐帧 RMS 日志）', () {
    final Map<String, Map<String, Object?>> want = _byId(fixture['log']);
    for (final LogCase c in logCases()) {
      test(c.id, () {
        final Map<String, Object?> w = want[c.id]!;
        if (w['error'] == true) {
          expect(
            () => ffcParseRmsLog(c.bytes, silenceDb: c.silenceDb),
            throwsFormatException,
          );
          return;
        }
        _expectDoubles(ffcParseRmsLog(c.bytes, silenceDb: c.silenceDb), w);
      });
    }
  });

  group('FfcEnergyEnvelope.downsample（波形桶）', () {
    final Map<String, Map<String, Object?>> want = _byId(fixture['downsample']);
    for (final DownsampleCase c in downsampleCases()) {
      test(c.id, () {
        final FfcEnergyEnvelope env = FfcEnergyEnvelope.fromDb(c.frames);
        expect(env.length, c.frames.length);
        _expectDoubles(
          env.downsample(c.targetBuckets, percentile: c.percentile),
          want[c.id]!,
          libmDependent: true,
        );
      });
    }
    test('同一包络反复降采样结果稳定（缓存的振幅不被改写）', () {
      final DownsampleCase c = downsampleCases().firstWhere(
        (DownsampleCase c) => c.id == 'big-1366',
      );
      final FfcEnergyEnvelope env = FfcEnergyEnvelope.fromDb(c.frames);
      final Float64List first = env.downsample(1366);
      env.downsample(600);
      env.downsample(59999);
      expect(env.downsample(1366), first);
    });
  });
}
