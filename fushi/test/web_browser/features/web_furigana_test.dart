import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/web_browser/features/furigana/web_furigana_annotator.dart';
import 'package:fushi/src/web_browser/features/furigana/web_furigana_script.dart';

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

  test('encodeWebFuriganaToken 两种形态', () {
    expect(encodeWebFuriganaToken((text: 'は', ruby: null)), <Object>['は']);
    expect(
      encodeWebFuriganaToken((
        text: '食べた',
        ruby: <WebRubyPart>[(base: '食', ruby: 'た'), (base: 'べた', ruby: '')],
      )),
      <Object>[
        '食べた',
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

    WebFuriganaAnnotator annotator() => WebFuriganaAnnotator(
      tokenizer: (List<String> texts) async {
        tokenizeCalls++;
        return <List<({String text, String reading})>>[
          for (final String t in texts) dict[t]!,
        ];
      },
    );

    setUp(() {
      tokenizeCalls = 0;
    });

    test('一批 = 一次分词；纯文本合并', () async {
      final List<List<List<Object>>> out = await annotator().annotate(<String>[
        '猫は漢字',
        'あいう',
      ]);
      expect(tokenizeCalls, 1);
      expect(out[0], <List<Object>>[
        <Object>[
          '猫',
          <String>['猫', 'ねこ'],
        ],
        <Object>['は'],
        <Object>[
          '漢字',
          <String>['漢字', 'かんじ'],
        ],
      ]);
      expect(out[1], <List<Object>>[
        <Object>['あいう'],
      ]);
    });

    test('超长段不分词、回空列表', () async {
      final String huge = '猫' * (kWebFuriganaMaxItemChars + 1);
      final List<List<List<Object>>> out = await annotator().annotate(<String>[
        huge,
      ]);
      expect(tokenizeCalls, 0);
      expect(out.single, isEmpty);
    });
  });

  group('页内脚本拼装', () {
    test('配置调用带安装体（幂等守卫）与配置 JSON', () {
      final String js = webFuriganaConfigureInvocation(enabled: true);
      expect(js, contains('if (window.__fushiFurigana) return;'));
      expect(js, contains("'$kWebFuriganaHandler'"));
      expect(js, contains('BATCH_ITEMS = $kWebFuriganaPageBatchItems'));
      expect(js, contains('"enabled":true'));
      expect(js, isNot(contains('highlight')));
      expect(js.trimRight(), endsWith(');'));
    });

    test('parseWebFuriganaRequest 校验形状与批大小', () {
      expect(
        parseWebFuriganaRequest(<dynamic>[
          <String, Object>{
            'texts': <String>['猫'],
          },
        ]),
        <String>['猫'],
      );
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
