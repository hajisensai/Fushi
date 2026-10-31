import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/ruby_markup.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;

void main() {
  // 文本：「彼は忙しい毎日」 忙(2) 毎日(5..7)
  const List<RubySpan> spans = <RubySpan>[
    RubySpan(start: 2, length: 1, ruby: 'せわ'),
    RubySpan(start: 5, length: 2, ruby: 'まいにち'),
    RubySpan(start: 0, length: 1, ruby: ''),
    RubySpan(start: 1, length: 1, ruby: 'ア'),
  ];

  test('整行区间平移到查询串坐标，空读音忽略，片假名原样', () {
    expect(rubySpansForQuery(spans, 1, 6), const <FushiRubySpan>[
      FushiRubySpan(start: 1, end: 2, reading: 'せわ'),
      FushiRubySpan(start: 4, end: 6, reading: 'まいにち'),
      FushiRubySpan(start: 0, end: 1, reading: 'ア'),
    ]);
  });

  test('基字被查询起点截断的丢弃', () {
    expect(rubySpansForQuery(spans, 6, 1), isEmpty);
  });

  test('基字被查询终点截断的丢弃', () {
    expect(rubySpansForQuery(spans, 2, 4), const <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 1, reading: 'せわ'),
    ]);
  });

  test('空输入', () {
    expect(rubySpansForQuery(const <RubySpan>[], 0, 5), isEmpty);
    expect(rubySpansForQuery(spans, 0, 0), isEmpty);
  });
}
