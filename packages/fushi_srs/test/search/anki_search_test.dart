// Anki 搜索语法的 Dart 解析器（search_parser.dart）：不合法语法报 syntax、合法但不支持的报 unsupported。
//
// 求值用例（裸词、字段、deck / tag / is: / prop: / re: …）以前经 Dart 整批求值包装 `SrsSearchCorpus` 跑；那层
// 包装生产不再用、已删（L-5），那些用例喂给内核的输入与内核的输出录成
// native/fushi_fsrs/tests/fixtures/search_kernel_vectors.json.zst，由 Rust 测试直接对拍。
@TestOn('vm')
library;

import 'package:fushi_srs/src/search/anki_search.dart';
import 'package:test/test.dart';

import 'search_test_support.dart';

void main() {
  group('结构 / 优先级（parser.rs parsing）', () {
    test('各种空白都当空格；隐式 AND', () {
      for (final String q in <String>[
        'foo bar',
        'foo\tbar',
        'foo\nbar',
        '  foo   bar  ',
        'foo　bar',
      ]) {
        final SrsSearchNode n = parseAnkiSearch(q);
        expect(n, isA<SrsSearchAnd>(), reason: q);
        expect((n as SrsSearchAnd).children, hasLength(2));
      }
      expect(parseAnkiSearch('(  t   t2  )'), isA<SrsSearchAnd>());
    });

    test(r'hello -(world and "foo:bar baz") OR test', () {
      final SrsSearchNode n = parseAnkiSearch(
        r'hello  -(world and "foo:bar baz") OR test',
      );
      expect(n, isA<SrsSearchOr>());
      final List<SrsSearchNode> ors = (n as SrsSearchOr).children;
      expect(ors, hasLength(2));
      final SrsSearchAnd left = ors[0] as SrsSearchAnd;
      expect((left.children[0] as SrsSearchText).text, 'hello');
      final SrsSearchNot not = left.children[1] as SrsSearchNot;
      final SrsSearchAnd inner = not.child as SrsSearchAnd;
      expect((inner.children[0] as SrsSearchText).text, 'world');
      final SrsSearchField field = inner.children[1] as SrsSearchField;
      expect(field.field, 'foo');
      expect(field.text, 'bar baz');
      expect((ors[1] as SrsSearchText).text, 'test');
    });

    test('转义与引号无关；解析器解掉 \\" \\: \\( \\) \\-', () {
      SrsSearchField f(String q) => parseAnkiSearch(q) as SrsSearchField;
      expect(f(r'"field:va\"lue"').text, 'va"lue');
      expect(f(r'field:"va\"lue"').text, 'va"lue');
      expect(f(r'field:va\"lue').text, 'va"lue');
      expect((parseAnkiSearch(r'\"\:\(\)\-') as SrsSearchText).text, r'":()-');
      // 通配转义留给匹配阶段。
      expect((parseAnkiSearch(r'\\\*\_') as SrsSearchText).text, r'\\\*\_');
      // 引号里括号可不转义；第一个冒号之后的冒号可不转义。
      expect(
        (parseAnkiSearch(r'"\)\("') as SrsSearchText).text,
        (parseAnkiSearch(r'")("') as SrsSearchText).text,
      );
      expect(f('field:val:ue').text, 'val:ue');
      expect(f(r'field:val\:ue').text, 'val:ue');
      expect(f('"field:val:ue"').text, 'val:ue');
      expect(f('field:"val:ue"').text, 'val:ue');
      // `-` 只有在可能被当成取反时才需要转义。
      expect((parseAnkiSearch('-') as SrsSearchText).text, '-');
      expect((parseAnkiSearch('A-') as SrsSearchText).text, 'A-');
      expect((parseAnkiSearch(r'\-A') as SrsSearchText).text, '-A');
      expect((parseAnkiSearch('"-A"') as SrsSearchText).text, '-A');
      expect(parseAnkiSearch('-A'), isA<SrsSearchNot>());
    });

    test('节点分隔清楚时可省空格', () {
      final SrsSearchAnd n = parseAnkiSearch('a"b"(c)') as SrsSearchAnd;
      expect(n.children, hasLength(3));
    });
  });

  group('不合法语法明确报错（parser.rs errors）', () {
    for (final String q in <String>[
      'foo and',
      'and foo',
      'and',
      'foo or',
      'or foo',
      'or',
      '()',
      '( )',
      '(foo () bar)',
      ')',
      'foo ) bar',
      '(foo) bar)',
      '(',
      'foo ( bar',
      '(foo (bar)',
      '""',
      'foo:""',
      ' " ',
      '" foo',
      r'"\',
      'foo:"bar',
      r'foo:"bar\',
      ':',
      ':foo',
      ':"foo"',
      r'\',
      r'\%',
      r'foo\',
      r'\foo',
      r'"\ "',
      'nid:1_2,3',
      'nid:1,2,x',
      'nid:,2,3',
      'nid:1,2,',
      'cid:1,2,x',
      'is:foo',
      'is:DUE',
      'is:New',
      'is:',
      '"is:learn "',
      'added:1.1',
      'added:-1',
      'added:',
      'added:foo',
      '-and',
    ]) {
      test(q, () {
        expect(
          () => parseAnkiSearch(q),
          throwsSearch(SrsSearchErrorKind.syntax),
        );
      });
    }
  });

  group('合法但不支持的语法明确报 unsupported', () {
    for (final String q in <String>[
      'prop:ease>2',
      'prop:pos=1',
      'prop:r<0.9',
      'prop:rated=1',
      'deck:A (expression:x or prop:ease=1)',
      '-rated:1',
      'rated:1',
      'resched:1',
      'introduced:1',
      'did:1',
      'mid:1',
      'nc:abc',
      'sc:abc',
      'w:abc',
      'dupe:1,abc',
      'has-cd:r',
      'preset:default',
      'front:nc:abc',
      'tag:re:abc',
      'tag:nc:abc',
      'deck:filtered',
      'deck:current',
      'is:buried-sibling',
      // 嵌在复合查询深处也必须冒出来。
    ]) {
      test(q, () {
        expect(
          () => parseAnkiSearch(q),
          throwsSearch(SrsSearchErrorKind.unsupported),
        );
      });
    }
  });

  group('求值用例里的解析断言（原样留在解析器测试里）', () {
    for (final String q in <String>[
      r'"expression:a\b"',
      'flag:8',
      'flag:x',
      'edited:x',
      'prop:ivl>3.5',
      'prop:foo=1',
      'prop:d=x',
      'prop:s>${'1' * 400}',
    ]) {
      test(q, () {
        expect(
          () => parseAnkiSearch(q),
          throwsSearch(SrsSearchErrorKind.syntax),
        );
      });
    }
  });
}
