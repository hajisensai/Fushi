import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_fbank.dart';
import 'package:fushi/src/asr/asr_fbank_workers.dart';
import 'package:fushi/src/asr/asr_types.dart';

Float32List _tone(int samples, int seed) {
  final math.Random rng = math.Random(seed);
  final Float32List x = Float32List(samples);
  final double f = 200.0 + seed * 37;
  for (int i = 0; i < samples; i++) {
    x[i] = 0.3 * math.sin(2 * math.pi * f * i / kAsrSampleRate) +
        0.05 * (rng.nextDouble() * 2 - 1);
  }
  return x;
}

void main() {
  const AsrFbank fbank = AsrFbank();

  test('isolate 池的结果与同步 compute 逐元素相同、顺序一致（段数多于 worker）', () async {
    final List<Float32List> samples = <Float32List>[
      for (int i = 0; i < 11; i++) _tone(kAsrSampleRate * (1 + i % 4) ~/ 2, i),
    ];
    final AsrFbankWorkers workers = AsrFbankWorkers(workers: 3);
    final List<Float32List> got = await workers.computeAll(samples);
    expect(got.length, samples.length);
    for (int i = 0; i < samples.length; i++) {
      final Float32List want = fbank.compute(samples[i]);
      expect(got[i].length, want.length, reason: '第 $i 段长度');
      expect(got[i], want, reason: '第 $i 段内容');
    }
  });

  test('段数少于 worker / 单段 / 空列表', () async {
    final AsrFbankWorkers workers = AsrFbankWorkers(workers: 4);
    final List<Float32List> two = <Float32List>[_tone(8000, 1), _tone(3000, 2)];
    final List<Float32List> got = await workers.computeAll(two);
    expect(got[0], fbank.compute(two[0]));
    expect(got[1], fbank.compute(two[1]));
    final List<Float32List> one = await workers.computeAll(<Float32List>[
      _tone(5000, 3),
    ]);
    expect(one.single, fbank.compute(_tone(5000, 3)));
    expect(await workers.computeAll(const <Float32List>[]), isEmpty);
  });

  test('balancedGroups：连续切片、每组至少一项、总量尽量均衡', () {
    expect(AsrFbankWorkers.balancedGroups(<int>[5, 5, 5, 5], 2), <List<int>>[
      <int>[0, 1],
      <int>[2, 3],
    ]);
    expect(AsrFbankWorkers.balancedGroups(<int>[9, 1, 1, 1], 2), <List<int>>[
      <int>[0],
      <int>[1, 2, 3],
    ]);
    expect(AsrFbankWorkers.balancedGroups(<int>[1, 1], 4), <List<int>>[
      <int>[0],
      <int>[1],
    ]);
    expect(AsrFbankWorkers.balancedGroups(<int>[3], 4), <List<int>>[
      <int>[0],
    ]);
    // 每项都被分到且只分到一组。
    final List<int> weights = List<int>.generate(23, (int i) => 1 + i * 7 % 5);
    final List<List<int>> groups = AsrFbankWorkers.balancedGroups(weights, 4);
    expect(groups.length, 4);
    expect(groups.expand((List<int> g) => g).toList(),
        List<int>.generate(23, (int i) => i));
  });

  test('worker 数至少 1；默认按逻辑核数取 1~4', () {
    expect(() => AsrFbankWorkers(workers: 0), throwsArgumentError);
    expect(defaultAsrFbankWorkerCount(), inInclusiveRange(1, 4));
  });
}
