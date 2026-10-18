// 有声书 / 阅读器匹配坐标系归一化的原生绑定（ffc_parse_fold_*）。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip。逐码点口径的全码点摘要钉在
// packages/fushi_audio/test/matching/audio_text_normalizer_native_test.dart 与
// native/fushi_compute/src/parse/fold.rs 里；这里只测绑定本身（暂存区扩容、拷贝语义）。
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      () => AudioTextFoldNative.instance,
      returnsNormally,
      reason: 'set $kFushiComputeLibEnv to the built fushi_compute library',
    );
  });

  test('fold：白名单 + 值折叠', () {
    final AudioTextFoldNative fold = AudioTextFoldNative.instance;
    expect(fold.fold(''), '');
    expect(fold.fold('、。'), '');
    expect(fold.fold('ｱイＡb'), 'あいab');
  });

  test('foldWithStarts：返回拷贝，暂存区扩容后结果不变', () {
    final AudioTextFoldNative fold = AudioTextFoldNative.instance;
    final ({String text, Uint32List starts}) small = fold.foldWithStarts(
      'ア、𠮷',
    );
    expect(small.text, 'あ𠮷');
    expect(small.starts, <int>[0, 2, 2]);
    // 远超初始容量（1024）的输入，迫使暂存区重新分配。
    final String big = 'ア、' * 5000;
    final ({String text, Uint32List starts}) large = fold.foldWithStarts(big);
    expect(large.text, 'あ' * 5000);
    expect(large.starts.length, 5000);
    expect(large.starts.last, 9998);
    expect(small.starts, <int>[0, 2, 2], reason: '先前返回的 starts 不能被复用区改写');
    expect(fold.fold('ﾝ'), 'ん');
  });
}
