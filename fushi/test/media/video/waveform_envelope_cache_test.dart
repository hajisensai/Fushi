import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/waveform_envelope_cache.dart';

/// TODO-1244：字幕对轴波形包络缓存的命中 / 失效 / 只缓存非空结果 单测。
void main() {
  group('WaveformEnvelopeCache', () {
    test('同 key 第二次命中缓存，不再调用 load（波形不每次重新生成）', () async {
      final WaveformEnvelopeCache cache = WaveformEnvelopeCache();
      int calls = 0;
      Future<List<double>> load() async {
        calls++;
        return <double>[-30, -10, -20];
      }

      final List<double> first = await cache.resolve('videoA|0', load);
      final List<double> second = await cache.resolve('videoA|0', load);

      expect(calls, 1); // 只抽一次
      expect(first, <double>[-30, -10, -20]);
      expect(identical(first, second), isTrue); // 命中返回同一实例
      expect(cache.hasCached('videoA|0'), isTrue);
    });

    test('换 key（切视频 / 切音轨）miss → 重抽，不返回旧音频波形', () async {
      final WaveformEnvelopeCache cache = WaveformEnvelopeCache();
      final List<List<double>> outputs = <List<double>>[
        <double>[-30, -10],
        <double>[-5, -50, -12],
        <double>[-7, -8],
      ];
      int calls = 0;
      Future<List<double>> load() async => outputs[calls++];

      final List<double> a = await cache.resolve('videoA|0', load);
      final List<double> b = await cache.resolve('videoB|0', load); // 换视频
      final List<double> c = await cache.resolve('videoA|1', load); // 换音轨（同视频）

      expect(calls, 3); // 每个新 key 各抽一次
      expect(a, <double>[-30, -10]);
      expect(b, <double>[-5, -50, -12]);
      // 换 key 覆盖旧槽：旧 key 不再命中（单槽有界）。
      expect(cache.hasCached('videoA|0'), isFalse);
      expect(cache.hasCached('videoA|1'), isTrue);
      expect(c, isNotEmpty);
    });

    test('空包络（移动端降级 / 超时）不缓存，下次同 key 仍重试', () async {
      final WaveformEnvelopeCache cache = WaveformEnvelopeCache();
      int calls = 0;
      final List<List<double>> outputs = <List<double>>[
        const <double>[], // 首次降级
        <double>[-40, -8], // 下次成功
      ];
      Future<List<double>> load() async => outputs[calls++];

      final List<double> first = await cache.resolve('videoA|0', load);
      expect(first, isEmpty);
      expect(cache.hasCached('videoA|0'), isFalse); // 空不缓存

      final List<double> second = await cache.resolve('videoA|0', load);
      expect(calls, 2); // 空结果没钉死降级态，允许重试
      expect(second, <double>[-40, -8]);
      expect(cache.hasCached('videoA|0'), isTrue);
    });

    test('clear() 丢弃缓存', () async {
      final WaveformEnvelopeCache cache = WaveformEnvelopeCache();
      await cache.resolve('k', () async => <double>[-1, -2]);
      expect(cache.hasCached('k'), isTrue);
      cache.clear();
      expect(cache.hasCached('k'), isFalse);
    });
  });
}
