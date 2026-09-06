import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_fbank.dart';

/// 黄金数据由 `fixtures/gen_fbank_golden.py`（kaldi-native-fbank 1.22.3，
/// sherpa-onnx 默认 fbank 选项）生成；本测试断言 Dart 实现与 knf 逐值一致。
void main() {
  late Map<String, Object?> golden;
  setUpAll(() {
    golden = jsonDecode(
      File('test/asr/fixtures/fbank_golden.json').readAsStringSync(),
    ) as Map<String, Object?>;
  });

  group('AsrFbank.frameCount', () {
    test('snip_edges=false：(n + shift/2) ~/ shift', () {
      expect(AsrFbank.frameCount(0), 0);
      expect(AsrFbank.frameCount(79), 0);
      expect(AsrFbank.frameCount(80), 1);
      expect(AsrFbank.frameCount(160), 1);
      expect(AsrFbank.frameCount(240), 2);
      expect(AsrFbank.frameCount(6400), 40);
      expect(AsrFbank.frameCount(16000), 100);
    });
  });

  group('AsrFbank.compute', () {
    test('与 kaldi-native-fbank 黄金特征逐值一致（|diff| < 1e-3）', () {
      final Float32List samples = Float32List.fromList(
        (golden['samples']! as List<Object?>)
            .map((Object? v) => (v as num).toDouble())
            .toList(),
      );
      final List<double> expected = (golden['features']! as List<Object?>)
          .map((Object? v) => (v as num).toDouble())
          .toList();
      final int frames = golden['frames']! as int;

      final Float32List actual = const AsrFbank().compute(samples);

      expect(AsrFbank.frameCount(samples.length), frames);
      expect(actual.length, frames * 80);
      expect(expected.length, frames * 80);
      double maxDiff = 0;
      int worst = -1;
      for (int i = 0; i < expected.length; i++) {
        final double d = (actual[i] - expected[i]).abs();
        if (d > maxDiff) {
          maxDiff = d;
          worst = i;
        }
      }
      expect(
        maxDiff,
        lessThan(1e-3),
        reason: '最大偏差 $maxDiff 在帧 ${worst ~/ 80} bin ${worst % 80}：'
            'dart=${actual[worst]} knf=${expected[worst]}',
      );
    });

    test('空输入返回空特征', () {
      expect(const AsrFbank().compute(Float32List(0)), isEmpty);
    });

    test('全零输入落到 log(float epsilon) 下限', () {
      final Float32List out = const AsrFbank().compute(Float32List(1600));
      expect(out.length, 10 * 80);
      // ln(1.1920929e-7) ≈ -15.9424
      for (final double v in out) {
        expect(v, closeTo(-15.9424, 1e-3));
      }
    });
  });
}
