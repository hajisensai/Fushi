// Anki 搜索语法子集：解析（照 rslib search/parser.rs 的用例）、求值（照
// sqlwriter.rs 的语义）、Yomitan 查重实际发出的查询串、不支持语法明确报错。
import 'package:fushi_srs/src/search/anki_search.dart';
import 'package:test/test.dart';

class _Card implements SrsSearchSubject {
  _Card({
    this.deckName = 'Default',
    this.noteTypeName = 'Basic',
    this.fields = const <String, String>{},
    this.tags = const <String>[],
    this.isNew = false,
    this.isLearn = false,
    this.isReview = false,
    this.isDue = false,
    this.isSuspended = false,
    this.noteId = 1,
    this.cardId = 1,
    this.addedDayIndex = 100,
    this.todayDayIndex = 100,
    this.flag = 0,
    this.isBuried = false,
    this.cardOrdinal = 1,
    this.templateName = 'Card 1',
    this.intervalDays = 0,
    this.dueInDays,
    this.reps = 0,
    this.lapses = 0,
    this.stability,
    this.difficulty,
    this.editedDayIndex = 100,
  });

  @override
  final String deckName;
  @override
  final String noteTypeName;
  @override
  final Map<String, String> fields;
  @override
  final List<String> tags;
  @override
  final bool isNew;
  @override
  final bool isLearn;
  @override
  final bool isReview;
  @override
  final bool isDue;
  @override
  final bool isSuspended;
  @override
  final int noteId;
  @override
  final int cardId;
  @override
  final int addedDayIndex;
  @override
  final int todayDayIndex;
  @override
  final int flag;
  @override
  final bool isBuried;
  @override
  final int cardOrdinal;
  @override
  final String templateName;
  @override
  final int intervalDays;
  @override
  final int? dueInDays;
  @override
  final int reps;
  @override
  final int lapses;
  @override
  final double? stability;
  @override
  final double? difficulty;
  @override
  final int editedDayIndex;
}

bool m(String query, _Card card) =>
    matchesAnkiSearch(parseAnkiSearch(query), card);

Matcher throwsSearch(SrsSearchErrorKind kind) => throwsA(
  isA<SrsSearchUnsupported>().having(
    (SrsSearchUnsupported e) => e.kind,
    'kind',
    kind,
  ),
);

void main() {
  final _Card taberu = _Card(
    deckName: 'Japanese::Mining',
    noteTypeName: 'Lapis',
    fields: const <String, String>{
      'Expression': '<b>食べる</b>',
      'ExpressionReading': 'たべる',
      'Sentence': 'パンを<span class="hl">食べる</span>。',
      'Meaning': 'to eat',
    },
    tags: const <String>['n5', 'verb::ichidan', 'fushi'],
    noteId: 1700000000001,
    cardId: 1700000000002,
  );

  group('结构 / 优先级（parser.rs parsing）', () {
    test('空串与纯空白 = 整个集合', () {
      expect(parseAnkiSearch(''), isA<SrsSearchAll>());
      expect(parseAnkiSearch('  \t\n'), isA<SrsSearchAll>());
      expect(m('', taberu), isTrue);
    });

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

    test('AND 比 OR 绑得紧；and / or / AND / Or 都认', () {
      final _Card a = _Card(fields: const <String, String>{'F': 'a'});
      expect(m('a b or a', a), isTrue); // (a AND b) OR a
      expect(m('a and b OR x', a), isFalse);
      expect(m('x Or a', a), isTrue);
      expect(m('a AND (b or a)', a), isTrue);
      expect(m('-a', a), isFalse);
      expect(m('-x', a), isTrue);
      expect(m('-(x or y)', a), isTrue);
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

  group('裸词全文', () {
    test('包含匹配、不区分大小写、* 与 _', () {
      expect(m('食べ', taberu), isTrue);
      expect(m('TO', taberu), isTrue);
      expect(m('t*eat', taberu), isTrue);
      expect(m('to_eat', taberu), isTrue);
      expect(m('to__eat', taberu), isFalse);
      expect(m('飲む', taberu), isFalse);
      // 裸词匹配字段原文（与 Anki 一样不去 HTML）。
      expect(m('class=', taberu), isTrue);
    });

    test(r'\* \_ \\ 是字面量', () {
      final _Card c = _Card(
        fields: const <String, String>{'F': r'a*b c_d e\f', 'G': 'axb'},
      );
      expect(m(r'a\*b', c), isTrue);
      expect(m(r'x\*b', c), isFalse);
      expect(m(r'c\_d', c), isTrue);
      expect(m(r'e\\f', c), isTrue);
      final _Card d = _Card(fields: const <String, String>{'F': 'cxd'});
      expect(m(r'c\_d', d), isFalse);
      expect(m('c_d', d), isTrue);
    });

    test('带空格的短语', () {
      final _Card c = _Card(
        fields: const <String, String>{'F': 'to eat bread'},
      );
      expect(m('"eat bread"', c), isTrue);
      expect(m('"bread eat"', c), isFalse);
    });
  });

  group('字段搜索', () {
    test('整值匹配、字段名不区分大小写、比较时去 HTML', () {
      expect(m('expression:食べる', taberu), isTrue);
      expect(m('EXPRESSION:食べる', taberu), isTrue);
      expect(m('expression:食べ', taberu), isFalse, reason: '不是包含匹配');
      expect(m('expression:食べ*', taberu), isTrue);
      expect(m('expression:*べ*', taberu), isTrue);
      expect(m('"meaning:TO EAT"', taberu), isTrue);
      expect(m('sentence:パンを食べる。', taberu), isTrue);
      expect(m('nosuchfield:食べる', taberu), isFalse);
    });

    test('字段名支持通配；值可为空', () {
      expect(m('expr*:食べる', taberu), isTrue);
      expect(m('"*:to eat"', taberu), isTrue);
      final _Card c = _Card(fields: const <String, String>{'A': '', 'B': 'x'});
      expect(m('a:', c), isTrue);
      expect(m('b:', c), isFalse);
      expect(m('a:_*', c), isFalse);
      expect(m('b:_*', c), isTrue);
    });

    test('通配转正则时其它字符被转义', () {
      final _Card c = _Card(
        fields: const <String, String>{'F': 'a.c (x) [y] {z} ^\$ | + ?'},
      );
      expect(m(r'"f:a.c (x) [y] {z} ^$ | + ?"', c), isTrue);
      expect(m('f:abc', c), isFalse);
      final _Card d = _Card(fields: const <String, String>{'F': 'abc'});
      expect(m('f:a.c', d), isFalse, reason: '. 不是通配');
    });

    test('实体解码后比较', () {
      final _Card c = _Card(
        fields: const <String, String>{'F': 'Tom&nbsp;&amp;&nbsp;Jerry'},
      );
      expect(m('"f:Tom & Jerry"', c), isTrue);
    });
  });

  group('deck: / note: / tag:', () {
    test('deck 匹配自身与全部子牌组，支持通配，不跨前缀', () {
      expect(m('deck:Japanese', taberu), isTrue);
      expect(m('deck:japanese::mining', taberu), isTrue);
      expect(m('"deck:Japanese::Mining"', taberu), isTrue);
      expect(m('deck:Japanese::Min', taberu), isFalse);
      expect(m('deck:Japan', taberu), isFalse);
      expect(m('deck:Jap*', taberu), isTrue);
      expect(m('deck:*', taberu), isTrue);
      expect(m('deck:Mining', taberu), isFalse, reason: '只从根开始匹配');
      final _Card spaced = _Card(deckName: 'My Deck::Sub');
      expect(m('"deck:My Deck"', spaced), isTrue);
      expect(m('deck:"My Deck"', spaced), isTrue);
    });

    test('note', () {
      expect(m('note:lapis', taberu), isTrue);
      expect(m('note:Lap*', taberu), isTrue);
      expect(m('note:Basic', taberu), isFalse);
      expect(
        m(
          '"note:Basic (and reversed card)"',
          _Card(noteTypeName: 'Basic (and reversed card)'),
        ),
        isTrue,
      );
    });

    test('tag：层级、通配、none、*', () {
      expect(m('tag:n5', taberu), isTrue);
      expect(m('tag:N5', taberu), isTrue);
      expect(m('tag:verb', taberu), isTrue, reason: '父标签命中子标签');
      expect(m('tag:verb::ichidan', taberu), isTrue);
      expect(m('tag:ichidan', taberu), isFalse);
      expect(m('tag:ver', taberu), isFalse);
      expect(m('tag:v*', taberu), isTrue);
      expect(m('tag:n_', taberu), isTrue);
      expect(m('tag:fu*i', taberu), isTrue);
      expect(m('tag:*', taberu), isTrue);
      expect(m('tag:none', taberu), isFalse);
      expect(m('tag:none', _Card()), isTrue);
      expect(m('-tag:n5', taberu), isFalse);
      expect(m('"tag:a b"', taberu), isFalse);
    });
  });

  group('is: / nid: / cid: / added:', () {
    test('卡片状态', () {
      expect(m('is:new', _Card(isNew: true)), isTrue);
      expect(m('is:new', _Card()), isFalse);
      expect(m('is:due', _Card(isDue: true)), isTrue);
      expect(m('is:suspended', _Card(isSuspended: true)), isTrue);
      expect(m('is:review', _Card(isReview: true)), isTrue);
      expect(m('is:learn', _Card(isLearn: true)), isTrue);
      expect(m('is:learn -is:suspended', _Card(isLearn: true)), isTrue);
    });

    test('nid / cid（53 位整数）', () {
      expect(m('nid:1700000000001', taberu), isTrue);
      expect(m('nid:1,2,1700000000001', taberu), isTrue);
      expect(m('nid:1,2', taberu), isFalse);
      expect(m('cid:1700000000002', taberu), isTrue);
      expect(m('cid:1700000000001', taberu), isFalse);
      expect(
        m('nid:9007199254740991', _Card(noteId: 9007199254740991)),
        isTrue,
      );
    });

    test('added:N 含今天往回 N 天；0 当 1', () {
      _Card at(int day) => _Card(addedDayIndex: day, todayDayIndex: 100);
      expect(m('added:1', at(100)), isTrue);
      expect(m('added:1', at(99)), isFalse);
      expect(m('added:0', at(100)), isTrue);
      expect(m('added:0', at(99)), isFalse);
      expect(m('added:3', at(98)), isTrue);
      expect(m('added:3', at(97)), isFalse);
    });
  });

  group('Yomitan 实际发出的查询（anki-connect.js _getNoteQuery）', () {
    // Yomitan 的 _escapeQuery 只删掉双引号，其余字符原样拼进 "key:value"；
    // 字段名 toLowerCase。
    test('deck 范围 + 首字段', () {
      expect(m('"deck:Japanese::Mining" "expression:食べる"', taberu), isTrue);
      expect(m('"deck:Japanese" "expression:食べる"', taberu), isTrue);
      expect(m('"deck:Other" "expression:食べる"', taberu), isFalse);
      expect(m('"expression:食べる"', taberu), isTrue);
      expect(m('"expression:飲む"', taberu), isFalse);
    });

    test('并集查询与 nid 候选过滤', () {
      const String union =
          '("deck:Japanese::Mining" "expression:飲む") or ("expression:食べる")';
      expect(m(union, taberu), isTrue);
      expect(m('nid:1700000000001,5 ("expression:食べる")', taberu), isTrue);
      expect(m('nid:5 ("expression:食べる")', taberu), isFalse);
    });

    test('值里的冒号、括号、空格、横杠', () {
      final _Card c = _Card(
        fields: const <String, String>{'Expression': '12:30 (笑) to be-or not'},
      );
      expect(m('"expression:12:30 (笑) to be-or not"', c), isTrue);
      final _Card d = _Card(
        fields: const <String, String>{'Expression': '-ing'},
      );
      expect(m('"expression:-ing"', d), isTrue);
    });

    test('值里的 * 与 _ 按 Anki 当通配（Yomitan 不转义，这是 Anki 的实际行为）', () {
      final _Card star = _Card(fields: const <String, String>{'Word': 'a*b'});
      final _Card other = _Card(fields: const <String, String>{'Word': 'aXYb'});
      expect(m('"word:a*b"', star), isTrue);
      expect(m('"word:a*b"', other), isTrue);
      final _Card under = _Card(fields: const <String, String>{'Word': 'a_c'});
      final _Card abc = _Card(fields: const <String, String>{'Word': 'abc'});
      expect(m('"word:a_c"', under), isTrue);
      expect(m('"word:a_c"', abc), isTrue);
    });

    test('值里的反斜杠：Anki 报非法转义，这里同样报错而不是当没命中', () {
      expect(
        () => parseAnkiSearch(r'"expression:a\b"'),
        throwsSearch(SrsSearchErrorKind.syntax),
      );
      // 合法转义序列照 Anki 解释。
      final _Card c = _Card(
        fields: const <String, String>{'Expression': r'a\b'},
      );
      expect(m(r'"expression:a\\b"', c), isTrue);
    });

    test('被删掉双引号后的值', () {
      // 原值 「"quoted" text」，Yomitan 删引号后发 quoted text。
      final _Card c = _Card(
        fields: const <String, String>{'Expression': 'quoted text'},
      );
      expect(m('"expression:quoted text"', c), isTrue);
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

  group('浏览页补的语法：flag / card / edited / is:buried / prop / re', () {
    final _Card c = _Card(
      fields: const <String, String>{
        'Front': '<b>Tokyo</b> 東京',
        'Back': 'capital42',
      },
      flag: 3,
      isBuried: true,
      cardOrdinal: 2,
      templateName: 'Reverse',
      intervalDays: 12,
      dueInDays: 3,
      reps: 7,
      lapses: 2,
      stability: 15.5,
      difficulty: 8.2, // (8.2 - 1) / 9 = 0.8
      editedDayIndex: 98,
    );

    test('flag:N', () {
      expect(m('flag:3', c), isTrue);
      expect(m('flag:0', c), isFalse);
      expect(m('-flag:0', c), isTrue);
      expect(
        () => parseAnkiSearch('flag:8'),
        throwsSearch(SrsSearchErrorKind.syntax),
      );
      expect(
        () => parseAnkiSearch('flag:x'),
        throwsSearch(SrsSearchErrorKind.syntax),
      );
    });

    test('card:序号 / card:模板名', () {
      expect(m('card:2', c), isTrue);
      expect(m('card:1', c), isFalse);
      expect(m('card:reverse', c), isTrue);
      expect(m('card:Rev*', c), isTrue);
      expect(m('card:Front', c), isFalse);
      // rslib：card:0 与 card:1 同义。
      expect(m('card:0', _Card()), isTrue);
    });

    test('edited:N', () {
      expect(m('edited:3', c), isTrue); // 98 > 100 - 3
      expect(m('edited:2', c), isFalse);
      expect(
        () => parseAnkiSearch('edited:x'),
        throwsSearch(SrsSearchErrorKind.syntax),
      );
    });

    test('is:buried', () {
      expect(m('is:buried', c), isTrue);
      expect(m('is:buried-manually', c), isTrue);
      expect(m('is:buried', _Card()), isFalse);
    });

    test('prop: 整数属性', () {
      expect(m('prop:ivl>=12', c), isTrue);
      expect(m('prop:ivl>12', c), isFalse);
      expect(m('prop:ivl!=12', c), isFalse);
      expect(m('prop:due=3', c), isTrue);
      expect(m('prop:due<0', c), isFalse);
      expect(m('prop:reps=7', c), isTrue);
      expect(m('prop:lapses<=2', c), isTrue);
      expect(m('prop:lapses<2', c), isFalse);
      // 新卡没有到期日：任何 prop:due 都不命中。
      expect(m('prop:due>-1000', _Card()), isFalse);
      expect(m('prop:due!=5', _Card()), isFalse);
      expect(
        () => parseAnkiSearch('prop:ivl>3.5'),
        throwsSearch(SrsSearchErrorKind.syntax),
      );
    });

    test('prop: FSRS 稳定性 / 难度（难度按 Anki 的 0–1 口径）', () {
      expect(m('prop:s>15', c), isTrue);
      expect(m('prop:s>15.5', c), isFalse);
      expect(m('prop:d=0.8', c), isTrue);
      expect(m('prop:d>0.7', c), isTrue);
      expect(m('prop:d>0.9', c), isFalse);
      expect(m('prop:d>0', _Card()), isFalse, reason: '没有记忆状态不命中');
      expect(
        () => parseAnkiSearch('prop:foo=1'),
        throwsSearch(SrsSearchErrorKind.syntax),
      );
      expect(
        () => parseAnkiSearch('prop:d=x'),
        throwsSearch(SrsSearchErrorKind.syntax),
      );
    });

    test('re: 全字段正则（不锚定、默认不区分大小写、看原文）', () {
      expect(m(r're:capital\d+', c), isTrue);
      expect(m('re:TOKYO', c), isTrue);
      expect(m('"re:(?-i)TOKYO"', c), isFalse);
      expect(m('re:<b>', c), isTrue, reason: 're: 搜原文，不去 HTML');
      expect(m('re:^capital', c), isFalse, reason: '不是多行模式：^ 只锚整串开头');
      expect(
        () => parseAnkiSearch('re:(abc'),
        throwsSearch(SrsSearchErrorKind.syntax),
      );
    });

    test('字段名:re:正则', () {
      expect(m(r'back:re:\d{2}$', c), isTrue);
      expect(m(r'front:re:\d', c), isFalse);
      expect(m('f*:re:東', c), isTrue);
      expect(
        m(
          r'"front:re:a\"b"',
          _Card(fields: const <String, String>{'Front': 'a"b'}),
        ),
        isTrue,
      );
    });
  });
}
