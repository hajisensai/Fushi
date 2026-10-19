// Anki 搜索搬进 Rust（native/fushi_fsrs/src/search.rs）之后的回归门：
//
// 1. 固定向量（test/search/fixtures/search_parity_vectors.json.gz）由**删除前的 Dart 实现**生成
//    （test/search/fixtures/gen_search_parity.dart.txt，在 efb95b0aef 上运行）：随机 + 真实形态的搜索式 × 卡片集的命中位图、
//    AnkiConnect 查重规范形。Rust 版必须逐位一致。
//    唯一有意改动的一处已在生成时折进期望值：未限定字段的 `re:` 按 Anki 对 0x1f 连接的字段求值
//    （旧 Dart 用空串连接，向量里留了 legacyHits 对照）。
// 2. 正则引擎差异（Dart RegExp ↔ Rust regex）逐条写成用例，以 Anki（Rust regex）的行为为准。
//
// 要真实原生库（FUSHI_FSRS_LIB，缺省本仓 prebuilt/）；库加载失败直接判红，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_srs/src/ffi/fushi_fsrs_library.dart';
import 'package:fushi_srs/src/search/anki_search.dart';
import 'package:test/test.dart';

import 'search_test_support.dart';

class _FixtureCard implements SrsSearchSubject {
  _FixtureCard(this.m);
  final Map<String, Object?> m;
  @override
  Object get noteKey => m['noteKey']!;
  @override
  String get deckName => m['deck']! as String;
  @override
  String get noteTypeName => m['noteType']! as String;
  @override
  late final Map<String, String> fields = (m['fields']! as Map<String, Object?>)
      .cast<String, String>();
  @override
  List<String> get tags => (m['tags']! as List<Object?>).cast<String>();
  int get _s => m['state']! as int;
  @override
  bool get isNew => _s & 1 != 0;
  @override
  bool get isLearn => _s & 2 != 0;
  @override
  bool get isReview => _s & 4 != 0;
  @override
  bool get isDue => _s & 8 != 0;
  @override
  bool get isSuspended => _s & 16 != 0;
  @override
  bool get isBuried => _s & 32 != 0;
  @override
  int get noteId => m['noteId']! as int;
  @override
  int get cardId => m['cardId']! as int;
  @override
  int get addedDayIndex => m['added']! as int;
  @override
  int get todayDayIndex => m['today']! as int;
  @override
  int get flag => m['flag']! as int;
  @override
  int get cardOrdinal => m['ord']! as int;
  @override
  String get templateName => m['template']! as String;
  @override
  int get intervalDays => m['ivl']! as int;
  @override
  int? get dueInDays => m['due'] as int?;
  @override
  int get reps => m['reps']! as int;
  @override
  int get lapses => m['lapses']! as int;
  @override
  double? get stability => (m['s'] as num?)?.toDouble();
  @override
  double? get difficulty => (m['d'] as num?)?.toDouble();
  @override
  int get editedDayIndex => m['edited']! as int;
}

String _bits(List<int> hits, int n) {
  final List<bool> v = List<bool>.filled(n, false);
  for (final int i in hits) {
    v[i] = true;
  }
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < n; i += 4) {
    int x = 0;
    for (int k = 0; k < 4 && i + k < n; k++) {
      if (v[i + k]) x |= 1 << k;
    }
    b.write(x.toRadixString(16));
  }
  return b.toString();
}

void main() {
  final FushiFsrs lib = requireSearchLibrary();
  final Map<String, Object?> fixture =
      (jsonDecode(
                utf8.decode(
                  gzip.decode(
                    File(
                      'test/search/fixtures/search_parity_vectors.json.gz',
                    ).readAsBytesSync(),
                  ),
                ),
              )
              as Map)
          .cast<String, Object?>();
  final List<_FixtureCard> cards = <_FixtureCard>[
    for (final Object? c in fixture['cards']! as List<Object?>)
      _FixtureCard((c! as Map).cast<String, Object?>()),
  ];

  test('固定向量：搜索命中位图与旧 Dart 实现逐位一致', () {
    final SrsSearchCorpus corpus = SrsSearchCorpus(cards, library: lib);
    final List<Object?> vectors = fixture['queries']! as List<Object?>;
    final List<String> mismatches = <String>[];
    int withHits = 0;
    for (final Object? raw in vectors) {
      final Map<Object?, Object?> v = raw! as Map<Object?, Object?>;
      final String q = v['q']! as String;
      final String expected = v['hits']! as String;
      if (expected.contains(RegExp('[1-9a-f]'))) withHits++;
      final String got;
      try {
        got = _bits(corpus.match(parseAnkiSearch(q), query: q), cards.length);
      } on SrsSearchUnsupported catch (e) {
        mismatches.add('$q -> threw $e');
        continue;
      }
      if (got != expected) mismatches.add('$q\n  want $expected\n  got  $got');
    }
    expect(vectors.length, greaterThan(3000));
    expect(withHits, greaterThan(1000), reason: '向量要有足够多的命中才有意义');
    expect(mismatches, isEmpty, reason: mismatches.take(20).join('\n'));
    corpus.dispose();
  });

  test('固定向量：旧 Dart 拒收的正则（语法不同）在 Rust 侧的去向', () {
    final SrsSearchCorpus corpus = SrsSearchCorpus(cards, library: lib);
    for (final Object? raw
        in fixture['regexRejectedByDart']! as List<Object?>) {
      final String q = (raw! as Map<Object?, Object?>)['q']! as String;
      final SrsSearchNode node = parseAnkiSearch(q);
      // 生成器只产出两边语义相同的构造，Dart 拒收的只能是 Rust 同样拒收的。
      expect(
        () => corpus.match(node, query: q),
        throwsSearch(SrsSearchErrorKind.syntax),
        reason: q,
      );
    }
  });

  test('固定向量：AnkiConnect 查重规范形逐串一致', () {
    final List<Object?> dupes = fixture['dupeNorm']! as List<Object?>;
    final List<String> inputs = <String>[
      for (final Object? d in dupes)
        (d! as Map<Object?, Object?>)['in']! as String,
    ];
    final List<String> got = srsDupeNormBatch(inputs, library: lib);
    for (int i = 0; i < dupes.length; i++) {
      expect(
        got[i],
        (dupes[i]! as Map<Object?, Object?>)['out'],
        reason: jsonEncode(inputs[i]),
      );
    }
    expect(dupes.length, greaterThanOrEqualTo(1000));
  });
}
