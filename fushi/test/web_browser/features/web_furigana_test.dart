import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/web_browser/features/furigana/web_furigana_annotator.dart';
import 'package:fushi/src/web_browser/features/furigana/web_furigana_script.dart';
import 'package:fushi/src/web_browser/features/furigana/web_known_word_lookup.dart';

List<({String base, String ruby})>? align(String s, String r) =>
    alignFurigana(s, r);

void main() {
  group('alignFurigana', () {
    test('整词：汉字段吃读音、假名段按字面', () {
      expect(align('漢字', 'かんじ'), <WebRubyPart>[(base: '漢字', ruby: 'かんじ')]);
      expect(align('見送る', 'みおくる'), <WebRubyPart>[
        (base: '見送', ruby: 'みおく'),
        (base: 'る', ruby: ''),
      ]);
      expect(align('お茶', 'おちゃ'), <WebRubyPart>[
        (base: 'お', ruby: ''),
        (base: '茶', ruby: 'ちゃ'),
      ]);
    });

    test('片假名读音按平假名比对、按平假名注', () {
      expect(align('東京', 'トウキョウ'), <WebRubyPart>[(base: '東京', ruby: 'とうきょう')]);
    });

    test('活用形：词典形读音 + 活用尾', () {
      expect(align('食べた', 'たべる'), <WebRubyPart>[
        (base: '食', ruby: 'た'),
        (base: 'べた', ruby: ''),
      ]);
      expect(align('美しかった', 'うつくしい'), <WebRubyPart>[
        (base: '美', ruby: 'うつく'),
        (base: 'しかった', ruby: ''),
      ]);
    });

    test('对不上就不注（宁缺毋错）', () {
      expect(align('来た', 'くる'), isNull);
      expect(align('書いた', 'かく'), isNull);
      expect(align('ひらがな', 'ひらがな'), isNull);
      expect(align('漢字', ''), isNull);
    });
  });

  test('isKnownWordCandidate：含汉字或 ≥2 字片假名、且引擎认得', () {
    expect(isKnownWordCandidate('猫', 'ねこ'), isTrue);
    expect(isKnownWordCandidate('テレビ', 'てれび'), isTrue);
    expect(isKnownWordCandidate('は', 'は'), isFalse);
    expect(isKnownWordCandidate('ある', 'ある'), isFalse);
    expect(isKnownWordCandidate('猫', ''), isFalse);
  });

  group('splitWebFuriganaBatches', () {
    test('按段数切', () {
      expect(
        splitWebFuriganaBatches(<int>[10, 10, 10, 10, 10], maxItems: 2),
        <List<int>>[
          <int>[0, 1],
          <int>[2, 3],
          <int>[4],
        ],
      );
    });

    test('按字数切；超长段独占一组', () {
      expect(
        splitWebFuriganaBatches(<int>[6000, 6000, 1], maxChars: 12000),
        <List<int>>[
          <int>[0, 1],
          <int>[2],
        ],
      );
      expect(
        splitWebFuriganaBatches(<int>[20000, 5], maxChars: 12000),
        <List<int>>[
          <int>[0],
          <int>[1],
        ],
      );
      expect(splitWebFuriganaBatches(<int>[]), isEmpty);
    });
  });

  test('encodeWebFuriganaToken 三种形态', () {
    expect(
      encodeWebFuriganaToken((
        text: 'は',
        status: WebKnownWordStatus.none,
        ruby: null,
      )),
      <Object>['は'],
    );
    expect(
      encodeWebFuriganaToken((
        text: '猫',
        status: WebKnownWordStatus.unknown,
        ruby: null,
      )),
      <Object>['猫', 1],
    );
    expect(
      encodeWebFuriganaToken((
        text: '食べた',
        status: WebKnownWordStatus.learning,
        ruby: <WebRubyPart>[(base: '食', ruby: 'た'), (base: 'べた', ruby: '')],
      )),
      <Object>[
        '食べた',
        2,
        <String>['食', 'た', 'べた', ''],
      ],
    );
  });

  group('WebFuriganaAnnotator', () {
    final Map<String, List<({String text, String reading})>> dict =
        <String, List<({String text, String reading})>>{
          '猫は漢字': <({String text, String reading})>[
            (text: '猫', reading: 'ねこ'),
            (text: 'は', reading: 'は'),
            (text: '漢字', reading: 'かんじ'),
          ],
          'あいう': <({String text, String reading})>[
            (text: 'あ', reading: ''),
            (text: 'い', reading: ''),
            (text: 'う', reading: ''),
          ],
        };
    int tokenizeCalls = 0;
    final List<Set<String>> lookups = <Set<String>>[];

    WebFuriganaAnnotator annotator() => WebFuriganaAnnotator(
      tokenizer: (List<String> texts) async {
        tokenizeCalls++;
        return <List<({String text, String reading})>>[
          for (final String t in texts) dict[t]!,
        ];
      },
      knownWords: (Set<String> s) async {
        lookups.add(s);
        return <String, WebKnownWordStatus>{'猫': WebKnownWordStatus.known};
      },
    );

    setUp(() {
      tokenizeCalls = 0;
      lookups.clear();
    });

    test('一批 = 一次分词 + 一次已知词查询；纯文本合并', () async {
      final List<List<List<Object>>> out = await annotator().annotate(
        <String>['猫は漢字', 'あいう'],
        furigana: true,
        highlight: true,
      );
      expect(tokenizeCalls, 1);
      expect(lookups, <Set<String>>[
        <String>{'猫', '漢字'},
      ]);
      expect(out[0], <List<Object>>[
        <Object>[
          '猫',
          3,
          <String>['猫', 'ねこ'],
        ],
        <Object>['は'],
        <Object>[
          '漢字',
          1,
          <String>['漢字', 'かんじ'],
        ],
      ]);
      expect(out[1], <List<Object>>[
        <Object>['あいう'],
      ]);
    });

    test('关高亮不查复习库；关注音不带 ruby', () async {
      final List<List<List<Object>>> out = await annotator().annotate(
        <String>['猫は漢字'],
        furigana: false,
        highlight: false,
      );
      expect(lookups, isEmpty);
      expect(out.single, <List<Object>>[
        <Object>['猫は漢字'],
      ]);
    });

    test('超长段不分词、回空列表', () async {
      final String huge = '猫' * (kWebFuriganaMaxItemChars + 1);
      final List<List<List<Object>>> out = await annotator().annotate(
        <String>[huge],
        furigana: true,
        highlight: true,
      );
      expect(tokenizeCalls, 0);
      expect(out.single, isEmpty);
    });
  });

  test('webKnownWordStatusOf：有未暂停的学习中卡 = 学习中，否则已知', () {
    expect(
      webKnownWordStatusOf(<({SrsQueue queue, bool suspended})>[
        (queue: SrsQueue.review, suspended: false),
        (queue: SrsQueue.newCard, suspended: false),
      ]),
      WebKnownWordStatus.learning,
    );
    expect(
      webKnownWordStatusOf(<({SrsQueue queue, bool suspended})>[
        (queue: SrsQueue.learning, suspended: true),
        (queue: SrsQueue.review, suspended: false),
      ]),
      WebKnownWordStatus.known,
    );
  });

  group('页内脚本拼装', () {
    test('配置调用带安装体（幂等守卫）与配置 JSON', () {
      final String js = webFuriganaConfigureInvocation(
        const WebFuriganaPageConfig(
          furigana: true,
          highlight: false,
          unknownColor: '#112233',
        ),
      );
      expect(js, contains('if (window.__fushiFurigana) return;'));
      expect(js, contains("'$kWebFuriganaHandler'"));
      expect(js, contains('BATCH_ITEMS = $kWebFuriganaPageBatchItems'));
      expect(js, contains('"furigana":true'));
      expect(js, contains('"highlight":false'));
      expect(js, contains('"unknownColor":"#112233"'));
      expect(js.trimRight(), endsWith(');'));
    });

    test('parseWebFuriganaRequest 校验形状与批大小', () {
      final ({List<String> texts, bool furigana, bool highlight})? ok =
          parseWebFuriganaRequest(<dynamic>[
            <String, Object>{
              'texts': <String>['猫'],
              'furigana': true,
            },
          ]);
      expect(ok?.texts, <String>['猫']);
      expect(ok?.furigana, isTrue);
      expect(ok?.highlight, isFalse);
      expect(parseWebFuriganaRequest(<dynamic>[]), isNull);
      expect(
        parseWebFuriganaRequest(<dynamic>[
          <String, Object>{
            'texts': <Object>[1],
          },
        ]),
        isNull,
      );
      expect(
        parseWebFuriganaRequest(<dynamic>[
          <String, Object>{
            'texts': List<String>.filled(kWebFuriganaPageBatchItems + 1, 'a'),
          },
        ]),
        isNull,
      );
    });
  });
}
