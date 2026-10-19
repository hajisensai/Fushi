// 搜索求值从 Dart RegExp 换成 Rust regex（native/fushi_fsrs/src/search.rs）后**有意**以 Anki
// （rslib 同样用 Rust regex）为准的行为差异，逐条钉死。每条注释写明旧 Dart 实现的结果
// （efb95b0aef 上用 Dart 3.47.6 的 RegExp 实测）。固定向量回归见 search_parity_test.dart。
@TestOn('vm')
library;

import 'package:fushi_srs/src/ffi/fushi_fsrs_library.dart';
import 'package:fushi_srs/src/search/anki_search.dart';
import 'package:test/test.dart';

import 'search_test_support.dart';

class _Card implements SrsSearchSubject {
  _Card(this.fields, {this.tags = const <String>[]});

  @override
  final Map<String, String> fields;
  @override
  final List<String> tags;
  @override
  Object get noteKey => this;
  @override
  String get deckName => 'Default';
  @override
  String get noteTypeName => 'Basic';
  @override
  bool get isNew => false;
  @override
  bool get isLearn => false;
  @override
  bool get isReview => false;
  @override
  bool get isDue => false;
  @override
  bool get isSuspended => false;
  @override
  bool get isBuried => false;
  @override
  int get noteId => 1;
  @override
  int get cardId => 2;
  @override
  int get addedDayIndex => 0;
  @override
  int get todayDayIndex => 0;
  @override
  int get flag => 0;
  @override
  int get cardOrdinal => 1;
  @override
  String get templateName => 'Card 1';
  @override
  int get intervalDays => 0;
  @override
  int? get dueInDays => null;
  @override
  int get reps => 0;
  @override
  int get lapses => 0;
  @override
  double? get stability => null;
  @override
  double? get difficulty => null;
  @override
  int get editedDayIndex => 0;
}

void main() {
  final FushiFsrs lib = requireSearchLibrary();

  bool hit(
    String query,
    String front, {
    List<String> tags = const <String>[],
  }) => SrsSearchCorpus(<SrsSearchSubject>[
    _Card(<String, String>{'Front': front}, tags: tags),
  ], library: lib).match(parseAnkiSearch(query), query: query).isNotEmpty;

  group('re: 字符类按 Unicode（旧 Dart：\\w \\d \\b 只认 ASCII）', () {
    test(r'\w 匹配假名（Dart false）', () => expect(hit(r're:\w', 'あ'), isTrue));
    test(r'\d 匹配全角数字（Dart false）', () => expect(hit(r're:\d', '１'), isTrue));
    test(r'\b 两侧是假名时不是词界（Dart true）', () {
      expect(hit(r're:\bcat\b', 'あcatあ'), isFalse);
      expect(hit(r're:\bcat\b', 'a cat.'), isTrue);
    });
    test(r'\s：U+0085 是空白（Dart false），U+FEFF 不是（Dart true）', () {
      expect(hit(r're:a\sb', 'a\u0085b'), isTrue);
      expect(hit(r're:a\sb', 'a﻿b'), isFalse);
    });
  });

  test('re: 的 . 只排除 \\n（Dart 还排除 \\r、U+2028、U+2029）', () {
    expect(hit('re:a.b', 'a\rb'), isTrue);
    expect(hit('re:a.b', 'a b'), isTrue);
    expect(hit('re:a.b', 'a\nb'), isFalse);
  });

  group('re: 语法：Rust regex 不支持的（Dart 接受）→ 语法错误', () {
    for (final String q in <String>[
      '"re:a(?=b)"',
      '"re:a(?!b)"',
      '"re:(?<=a)b"',
      r'"re:(a)\1"',
      r'"re:(?<n>a)\k<n>"',
      '"re:[^]"',
    ]) {
      test(q, () {
        expect(() => hit(q, 'ab'), throwsSearch(SrsSearchErrorKind.syntax));
      });
    }
  });

  group('re: 语法：Rust regex 支持的（Dart 报语法错误）', () {
    test('中途的内联标志（Dart: Invalid group）', () {
      expect(hit('"re:(?-i)a(?i)b"', 'aB'), isTrue);
      expect(hit('"re:(?-i)a(?i)b"', 'AB'), isFalse);
    });
    test('POSIX 字符类 / 无花括号的 Unicode 类别（Dart: 语法错误）', () {
      expect(hit('re:[[:alpha:]]', 'x'), isTrue);
      expect(hit(r're:\pL', 'x'), isTrue);
    });
    test(r'转义 ASCII 标点 \:（Dart unicode 模式: Invalid escape）', () {
      expect(hit(r're:a\:b', 'a:b'), isTrue);
    });
  });

  test('re: 字符类里的 && 是交集（Dart 当成字面量 &）', () {
    expect(hit('re:[a-c&&b]', 'b'), isTrue);
    expect(hit('re:[a-c&&b]', '&'), isFalse);
  });

  test('未限定字段的 re: 对 0x1f 连接的字段求值（rslib n.flds；旧 Dart 用空串连接）', () {
    final SrsSearchCorpus c = SrsSearchCorpus(<SrsSearchSubject>[
      _Card(<String, String>{'Front': 'a', 'Back': 'b'}),
    ], library: lib);
    expect(c.match(parseAnkiSearch('re:ab')), isEmpty);
    expect(c.match(parseAnkiSearch(r're:a\x1fb')), <int>[0]);
  });

  test(r'标签通配的 \S：U+FEFF 算非空白（Dart false），U+0085 算空白（Dart true）', () {
    expect(hit('tag:a_b', '', tags: <String>['a﻿b']), isTrue);
    expect(hit('tag:a_b', '', tags: <String>['a\u0085b']), isFalse);
  });

  test('去 HTML 的正则按 Unicode 折叠大小写：<ſtyle> 当成 style 块（Anki 同；Dart 只剥标签）', () {
    expect(hit('Front:x', '<ſtyle>x</style>'), isFalse);
    expect(hit('Front:x', '<i>x</i>'), isTrue);
  });

  test('代理区数字实体解成 U+FFFD（Dart 得到孤立代理）', () {
    expect(srsDupeNormBatch(<String>['&#55296;'], library: lib), <String>['�']);
  });

  test('空查询（全部）不经原生库', () {
    expect(
      SrsSearchCorpus(<SrsSearchSubject>[
        _Card(<String, String>{'Front': 'x'}),
      ]).match(const SrsSearchAll()),
      <int>[0],
    );
  });
}
