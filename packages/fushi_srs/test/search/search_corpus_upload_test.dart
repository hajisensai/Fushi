// 字段值按需上传与后台预备（SrsSearchCorpus.prepare）：只传查询要的列、未限定字段时整条笔记连续
// 上传、大文本分给多个 isolate 编码、大集合在后台 isolate 上预求值——命中结果都必须与「各自新语料
// 串行求值」一致。要真实原生库。
@TestOn('vm')
library;

import 'package:fushi_srs/src/ffi/fushi_fsrs_library.dart';
import 'package:fushi_srs/src/search/anki_search.dart';
import 'package:test/test.dart';

import 'search_test_support.dart';

class _Card implements SrsSearchSubject {
  _Card(this.note, this.fields, {this.tags = const <String>[]});

  final int note;
  @override
  final Map<String, String> fields;
  @override
  final List<String> tags;
  @override
  Object get noteKey => note;
  @override
  String get deckName => note.isEven ? 'Japanese::Mining' : 'Default';
  @override
  String get noteTypeName => fields.length == 3 ? 'Lapis' : 'Basic';
  @override
  bool get isNew => note % 3 == 0;
  @override
  bool get isLearn => false;
  @override
  bool get isReview => note % 3 != 0;
  @override
  bool get isDue => false;
  @override
  bool get isSuspended => false;
  @override
  bool get isBuried => false;
  @override
  int get noteId => note;
  @override
  int get cardId => note;
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

/// 孤立代理（U+D800）：Dart 字符串允许，UTF-8 编不出来。
final String _loneSurrogate = String.fromCharCode(0xD800);

/// 两种笔记类型混排；Glossary 带大段内联样式，让总文本超过并行编码的门槛（4 Mi 码元），
/// 卡数超过后台预求值的门槛（5000）。
List<_Card> _cards() {
  final String css = '.gloss li { color: #333; margin: 0 } /* 語 */\n' * 28;
  return <_Card>[
    for (int i = 0; i < 6000; i++)
      if (i % 5 == 4)
        _Card(i, <String, String>{
          'Front': 'front $i 😀',
          'Back': i % 10 == 9
              ? 'x${_loneSurrogate}y'
              : (i % 2 == 0 ? 'to eat' : 'to run'),
        })
      else
        _Card(i, <String, String>{
          'Expression': i % 7 == 0 ? '<b>食べる$i</b>' : '飲む$i',
          'Glossary':
              '<style>$css</style><ol><li>${i % 3 == 0 ? 'to eat' : 'to drink'}</li></ol>',
          'Sentence': 'あ\u{1F}い$i',
        }, tags: i % 4 == 0 ? <String>['n5'] : const <String>[]),
  ];
}

const List<String> _queries = <String>[
  'is:new',
  'deck:Japanese tag:n5',
  '"Expression:食べる*"',
  '"Glossary:*to eat*"',
  '"Back:to eat"',
  'Expression:re:^飲む\\d+\$',
  '食べ',
  'eat -run',
  're:li>to eat',
  r're:い\d+$',
  r're:\x1f',
  '😀',
  '"Glossary:*to eat*" OR 走る',
];

void main() {
  final FushiFsrs lib = requireSearchLibrary();
  final List<_Card> cards = _cards();

  List<List<int>> serialAll() {
    // 参照：每条查询都在新语料上串行求值（各自只传自己要的列）。
    return <List<int>>[
      for (final String q in _queries)
        SrsSearchCorpus(
          cards,
          library: lib,
        ).match(parseAnkiSearch(q), query: q),
    ];
  }

  test('文本量与卡数确实越过并行编码 / 预求值的门槛', () {
    int chars = 0;
    for (final _Card c in cards) {
      for (final String v in c.fields.values) {
        chars += v.length;
      }
    }
    expect(chars, greaterThan(4 << 20));
    expect(cards.length, greaterThanOrEqualTo(5000));
  });

  test('孤立代理按 utf8.encode 的口径编成 U+FFFD（串行与并行编码都是）', () async {
    const String q = '"Back:x\u{FFFD}y"';
    final SrsSearchCorpus c = SrsSearchCorpus(cards, library: lib);
    expect(c.match(parseAnkiSearch(q), query: q), hasLength(600));
    final SrsSearchCorpus d = SrsSearchCorpus(cards, library: lib);
    await d.prepare(parseAnkiSearch('食'), query: '食');
    expect(d.match(parseAnkiSearch(q), query: q), hasLength(600));
    c.dispose();
    d.dispose();
  });

  test('同一语料上依次查询（列逐步补传、最后整条笔记重传）与各自新语料一致', () {
    final List<List<int>> want = serialAll();
    final SrsSearchCorpus shared = SrsSearchCorpus(cards, library: lib);
    for (int i = 0; i < _queries.length; i++) {
      expect(
        shared.match(parseAnkiSearch(_queries[i]), query: _queries[i]),
        want[i],
        reason: _queries[i],
      );
    }
    // 倒着再来一遍：全部字段已传之后，限定字段查询仍一致。
    for (int i = _queries.length - 1; i >= 0; i--) {
      expect(
        shared.match(parseAnkiSearch(_queries[i]), query: _queries[i]),
        want[i],
        reason: _queries[i],
      );
    }
    shared.dispose();
  });

  test('prepare（多 isolate 编码 + 后台预求值）后的结果与串行一致', () async {
    final List<List<int>> want = serialAll();
    for (int i = 0; i < _queries.length; i++) {
      final SrsSearchCorpus c = SrsSearchCorpus(cards, library: lib);
      final SrsSearchNode node = parseAnkiSearch(_queries[i]);
      await c.prepare(node, query: _queries[i]);
      expect(c.match(node, query: _queries[i]), want[i], reason: _queries[i]);
      c.dispose();
    }
    final SrsSearchCorpus shared = SrsSearchCorpus(cards, library: lib);
    for (int i = 0; i < _queries.length; i++) {
      final SrsSearchNode node = parseAnkiSearch(_queries[i]);
      await shared.prepare(node, query: _queries[i]);
      expect(
        shared.match(node, query: _queries[i]),
        want[i],
        reason: _queries[i],
      );
    }
    // 预求值缓存的是上一条：换一条查询后再回到旧查询，结果不能串。
    for (int i = 0; i < _queries.length; i++) {
      final SrsSearchNode node = parseAnkiSearch(_queries[i]);
      expect(
        shared.match(node, query: _queries[i]),
        want[i],
        reason: _queries[i],
      );
    }
    shared.dispose();
  });

  test('上一条查询的后台预求值没算完又来一条：prepare 返回时后台已放锁，结果不串', () async {
    final List<List<int>> want = serialAll();
    final SrsSearchCorpus c = SrsSearchCorpus(cards, library: lib);
    // 先让全部字段上传完：下一条未限定字段的查询不再编码，直接开后台预求值。
    await c.prepare(parseAnkiSearch('食'), query: '食');
    expect(c.backgroundBusy, isFalse);
    const String slowQuery = 're:li>to eat';
    final SrsSearchNode slowNode = parseAnkiSearch(slowQuery);
    final Future<void> slow = c.prepare(slowNode, query: slowQuery);
    await Future<void>.delayed(Duration.zero);
    expect(c.backgroundBusy, isTrue, reason: '前一条查询的后台预求值此时应在跑（持着原生锁）');
    // 浏览页随后的同步 match 依赖这条不变式：prepare 返回 = 没有后台求值占着语料锁。
    // 只看状态 / 牌组的查询既不传字段也不开预求值，旧实现会立刻返回，留下后台持锁。
    const String fastQuery = 'deck:Japanese tag:n5';
    final SrsSearchNode fastNode = parseAnkiSearch(fastQuery);
    await c.prepare(fastNode, query: fastQuery);
    expect(c.backgroundBusy, isFalse, reason: 'prepare 返回前要等后台预求值退场');
    expect(
      c.match(fastNode, query: fastQuery),
      want[_queries.indexOf(fastQuery)],
    );
    await slow;
    expect(
      c.match(slowNode, query: slowQuery),
      want[_queries.indexOf(slowQuery)],
    );
    c.dispose();
  });

  test('prepare 期间 dispose：等后台预求值结束再释放，不崩', () async {
    final SrsSearchCorpus c = SrsSearchCorpus(cards, library: lib);
    final Future<void> pending = c.prepare(parseAnkiSearch('食'), query: '食');
    c.dispose();
    await pending;
    expect(() => c.match(parseAnkiSearch('食')), throwsStateError);
  });

  test('prepare 对不合法的正则报语法错误；释放后的 prepare 不做事', () async {
    final SrsSearchCorpus c = SrsSearchCorpus(cards, library: lib);
    await expectLater(
      c.prepare(parseAnkiSearch('"re:(abc"'), query: '"re:(abc"'),
      throwsA(
        isA<SrsSearchUnsupported>().having(
          (SrsSearchUnsupported e) => e.kind,
          'kind',
          SrsSearchErrorKind.syntax,
        ),
      ),
    );
    c.dispose();
    await c.prepare(parseAnkiSearch('食'));
  });
}
