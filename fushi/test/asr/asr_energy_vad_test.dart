import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/asr/asr_vad.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

/// 合成信号：按 [segments] 依次拼接 (秒数, 幅度) 的正弦/静音，叠加 [noise] 幅度的
/// 确定性伪随机白噪声。
Float32List _synth(List<(double, double)> segments, {double noise = 0}) {
  final int total = segments.fold<int>(
    0,
    (int a, (double, double) s) => a + (s.$1 * kAsrSampleRate).round(),
  );
  final Float32List out = Float32List(total);
  final math.Random rng = math.Random(7);
  int pos = 0;
  for (final (double sec, double amp) in segments) {
    final int n = (sec * kAsrSampleRate).round();
    for (int i = 0; i < n; i++) {
      final double t = (pos + i) / kAsrSampleRate;
      out[pos + i] =
          amp * math.sin(2 * math.pi * 220 * t) +
          noise * (rng.nextDouble() * 2 - 1);
    }
    pos += n;
  }
  return out;
}

Future<List<AsrSpeechSegment>> _run(
  AsrVadSegmenter seg,
  Float32List audio, {
  int chunk = 16000,
}) async {
  final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
  for (int i = 0; i < audio.length; i += chunk) {
    final int end = math.min(audio.length, i + chunk);
    out.addAll(
      await seg.feed(
        AsrPcmChunk(
          startSample: i,
          samples: Float32List.sublistView(audio, i, end),
        ),
      ),
    );
  }
  out.addAll(await seg.flush());
  return out;
}

void main() {
  group('EnergyVadScorer', () {
    test('windowDb：全零 = 静音底，满幅正弦约 -3 dBFS', () {
      expect(
        EnergyVadScorer.windowDb(Float32List(512)),
        EnergyVadScorer.silenceFloorDb,
      );
      final Float32List sine = Float32List(512);
      for (int i = 0; i < 512; i++) {
        sine[i] = math.sin(2 * math.pi * 440 * i / kAsrSampleRate);
      }
      expect(EnergyVadScorer.windowDb(sine), closeTo(-3.0, 0.2));
    });

    test('数字静音下门限落在下限，语音窗口概率接近 1、静音接近 0', () async {
      final EnergyVadScorer scorer = EnergyVadScorer();
      final Float32List loud = Float32List(512);
      for (int i = 0; i < 512; i++) {
        loud[i] = 0.1 * math.sin(2 * math.pi * 300 * i / kAsrSampleRate);
      }
      final Float64List probs = await scorer.score(<Float32List>[
        Float32List(512),
        Float32List(512),
        loud,
      ]);
      expect(scorer.lastThresholdDb, -55);
      expect(probs[0], lessThan(0.01));
      expect(probs[2], greaterThan(0.99));
    });

    test('噪声底抬高时门限跟着抬（自适应）', () async {
      final EnergyVadScorer scorer = EnergyVadScorer();
      final math.Random rng = math.Random(3);
      final List<Float32List> windows = List<Float32List>.generate(200, (_) {
        final Float32List w = Float32List(512);
        for (int i = 0; i < 512; i++) {
          w[i] = 0.02 * (rng.nextDouble() * 2 - 1); // ≈ -39 dBFS 的噪声
        }
        return w;
      });
      final Float64List probs = await scorer.score(windows);
      // 噪声底约 -39 dB，+12 dB = -27 → 夹到上限 -30。
      expect(scorer.lastThresholdDb, -30);
      // 噪声本身低于门限：全部判静音。
      expect(probs.every((double p) => p < 0.05), isTrue);
    });
  });

  group('AsrVadSegmenter + EnergyVadScorer', () {
    test('静音-语音-静音-语音-静音 → 两段，边界在 ±1 窗口 + pad 内', () async {
      final Float32List audio = _synth(<(double, double)>[
        (1.0, 0),
        (2.0, 0.3),
        (1.5, 0),
        (1.0, 0.3),
        (3.0, 0),
      ]);
      final AsrVadSegmenter seg = AsrVadSegmenter(
        scorer: EnergyVadScorer(),
        speechPadMs: 200,
      );
      final List<AsrSpeechSegment> segs = await _run(seg, audio);
      expect(segs, hasLength(2));
      const int win = kAsrVadWindowSamples;
      const int pad = 200 * kAsrSampleRate ~/ 1000;
      // 第一段：语音 [1.0 s, 3.0 s)。
      expect(segs[0].startSample, closeTo(kAsrSampleRate - pad, win));
      expect(segs[0].endSample, closeTo(3 * kAsrSampleRate + pad, win));
      // 第二段：语音 [4.5 s, 5.5 s)。
      expect(segs[1].startSample, closeTo(4.5 * kAsrSampleRate - pad, win));
      expect(segs[1].endSample, closeTo(5.5 * kAsrSampleRate + pad, win));
    });

    test('带低电平底噪照样切出两段（门限自适应）', () async {
      final Float32List audio = _synth(<(double, double)>[
        (1.0, 0),
        (2.0, 0.3),
        (1.5, 0),
        (1.0, 0.3),
        (3.0, 0),
      ], noise: 0.003);
      final AsrVadSegmenter seg = AsrVadSegmenter(scorer: EnergyVadScorer());
      final List<AsrSpeechSegment> segs = await _run(seg, audio, chunk: 7000);
      expect(segs, hasLength(2));
    });

    test('不给 session 也不给 scorer 时默认能量打分器；两个都给报错', () {
      expect(AsrVadSegmenter(), isA<AsrVadSegmenter>());
      expect(
        () => AsrVadSegmenter(
          scorer: EnergyVadScorer(),
          session: _NeverSession(),
        ),
        throwsArgumentError,
      );
    });
  });
}

class _NeverSession implements OnnxSession {
  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}
