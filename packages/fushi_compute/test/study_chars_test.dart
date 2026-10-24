// 学习字数口径的原生实现（ffc_parse_study_*）。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip。库按 FushiCompute.instance 的默认
// 规则定位（本地跑时用环境变量 FUSHI_COMPUTE_LIB 指向 cargo 产物）。
@TestOn('vm')
library;

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 旧 Dart 正则实现（Unicode 属性正则逐码点判定）对 0..0x10FFFF 每个码点的类字节做
/// 32 位 FNV-1a 的结果；删 Dart 实现前用它生成，钉死表与旧口径逐码点一致。
const int _oldDartClassTableFnv1a = 0xf7c9b378;

int _count(String text) {
  final ({int count, bool inWord}) r = StudyCharsNative.instance.add(
    text,
    0,
    false,
  );
  return r.count + (r.inWord ? 1 : 0);
}

void main() {
  setUpAll(() {
    // 硬依赖：库不可用时 instance 抛 FushiComputeUnavailableError，整组失败。
    expect(
      () => StudyCharsNative.instance,
      returnsNormally,
      reason: 'set $kFushiComputeLibEnv to the built fushi_compute library',
    );
  });

  test(
    'class table matches the old Dart regex caliber code point by code point',
    () {
      final StudyCharsNative native = StudyCharsNative.instance;
      int hash = 0x811c9dc5;
      for (int cp = 0; cp < 0x110000; cp++) {
        hash ^= native.classOf(cp);
        hash = (hash * 0x01000193) & 0xffffffff;
      }
      expect(hash, _oldDartClassTableFnv1a);
    },
  );

  test('representative samples', () {
    expect(_count(''), 0);
    expect(_count('「こんにちは」'), 5);
    expect(_count("I don't know"), 3);
    expect(_count('café'), 1);
    expect(_count("rock 'n' roll"), 3);
    expect(_count('〇一二'), 3);
    expect(_count('ラーメン々'), 5);
    expect(_count('abc漢字def'), 4);
    expect(_count('𠮷野家'), 3);
    expect(_count('１２３ＡＢＣ'), 1);
  });

  test('resumable state equals counting the concatenation', () {
    final StudyCharsNative native = StudyCharsNative.instance;
    ({int count, bool inWord}) state = (count: 0, inWord: false);
    for (final String part in <String>['ab', 'cd', ' ', '漢', 'e']) {
      state = native.add(part, state.count, state.inWord);
    }
    expect(state.count + (state.inWord ? 1 : 0), _count('abcd 漢e'));
  });

  test('lone surrogates break words like String.runes', () {
    expect(_count('a\uD800b\uDC00c'), 3);
    // 跨两次 add 的代理对按两个孤立代理处理。
    final StudyCharsNative native = StudyCharsNative.instance;
    final ({int count, bool inWord}) first = native.add('\uD842', 0, false);
    final ({int count, bool inWord}) second = native.add(
      '\uDFB7',
      first.count,
      first.inWord,
    );
    expect(second.count, 0);
    expect(_count('𠮷'), 1);
  });

  test('large input grows the scratch buffer', () {
    final String big = 'あ' * 300000;
    expect(_count(big), 300000);
    expect(_count('x'), 1);
  });

  test('prefixTotals equals counting each prefix (one FFI call)', () {
    const String text = '猫が魚。 Hello world! 𠮷野家 rock\'n\'roll';
    final List<int> offsets = <int>[0, 3, 4, 8, 11, 17, 21, 25, text.length];
    expect(
      StudyCharsNative.instance.prefixTotals(text, offsets),
      <int>[for (final int o in offsets) _count(text.substring(0, o))],
    );
    expect(StudyCharsNative.instance.prefixTotals(text, const <int>[]), isEmpty);
    expect(
      () => StudyCharsNative.instance.prefixTotals(text, const <int>[5, 2]),
      throwsStateError,
    );
  });

  test('out-of-range code points classify as breaker', () {
    expect(StudyCharsNative.instance.classOf(-1), 0);
    expect(StudyCharsNative.instance.classOf(0x110000), 0);
  });
}
