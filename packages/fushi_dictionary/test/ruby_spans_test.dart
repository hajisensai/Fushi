import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// 原文振假名随查词交给引擎（排序本身在 native/fushidicts，见
/// `native/fushidicts/tests/ruby_reading_lookup_test.cpp`）。这里钉 Dart 侧的三件事：
/// wire 解析、查询串清洗后的坐标平移与缓存键、UTF-16 → 码点的 FFI 封送。
void main() {
  test('listFromWire 丢掉畸形项、读音去空白，listToWire 互逆', () {
    final List<FushiRubySpan> spans = FushiRubySpan.listFromWire(<Object?>[
      <String, Object?>{'s': 0, 'e': 1, 'r': ' せわ '},
      <String, Object?>{'s': 1, 'e': 1, 'r': 'x'},
      <String, Object?>{'s': 0, 'e': 1, 'r': ''},
      <String, Object?>{'s': -1, 'e': 1, 'r': 'x'},
      <String, Object?>{'s': 'a', 'e': 1, 'r': 'x'},
      'junk',
    ]);
    expect(spans, const <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 1, reading: 'せわ'),
    ]);
    expect(FushiRubySpan.listFromWire(FushiRubySpan.listToWire(spans)), spans);
    expect(FushiRubySpan.listFromWire(null), isEmpty);
  });

  test('shiftRubySpans 按句首剥离长度平移，越界的丢弃', () {
    expect(
      shiftRubySpans(
        const <FushiRubySpan>[
          FushiRubySpan(start: 1, end: 2, reading: 'せわ'),
          FushiRubySpan(start: 0, end: 1, reading: 'x'),
          FushiRubySpan(start: 4, end: 9, reading: 'y'),
        ],
        leadingStrip: 1,
        length: 4,
      ),
      const <FushiRubySpan>[FushiRubySpan(start: 0, end: 1, reading: 'せわ')],
    );
  });

  test('无 ruby 时缓存键后缀为空（旧键逐字不变），有 ruby 时单独成键', () {
    expect(rubySpansCacheSuffix(const <FushiRubySpan>[]), '');
    expect(
      rubySpansCacheSuffix(const <FushiRubySpan>[
        FushiRubySpan(start: 0, end: 1, reading: 'せわ'),
      ]),
      '/ruby:0-1=2.せわ',
    );
  });

  test('UTF-16 区间换成码点偏移：代理对算一个码点，切开代理对 / 越界 / 含分隔符的段丢弃', () {
    // 𠮟 是代理对（2 个 UTF-16 码元、1 个码点）。
    const String text = '𠮟る忙しい';
    final ({List<int> bounds, String readings}) out =
        rubySpansToCodePointBounds(text, const <FushiRubySpan>[
          FushiRubySpan(start: 0, end: 2, reading: 'しか'),
          FushiRubySpan(start: 3, end: 4, reading: 'せわ'),
          FushiRubySpan(start: 1, end: 2, reading: '切开代理对'),
          FushiRubySpan(start: 5, end: 9, reading: '越界'),
          FushiRubySpan(start: 3, end: 4, reading: 'a\u001fb'),
        ]);
    expect(out.bounds, <int>[0, 1, 2, 3]);
    expect(out.readings, 'しか\u001fせわ');
    expect(
      rubySpansToCodePointBounds(text, const <FushiRubySpan>[]).bounds,
      isEmpty,
    );
  });
}
