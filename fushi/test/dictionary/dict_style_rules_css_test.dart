import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/dictionary/dict_style_rules.dart';
import 'package:fushi/src/reader/dictionary_style_css.dart';

void main() {
  group('DictStylePart 选择器契约', () {
    test('每个部位都有非空选择器，且互不重复', () {
      final Set<String> seen = <String>{};
      for (final DictStylePart part in DictStylePart.values) {
        final String selector = dictStylePartSelector(part);
        expect(selector, isNotEmpty, reason: '$part 没有选择器');
        expect(seen.add(selector), isTrue, reason: '$part 的选择器与别人撞了');
      }
    });

    test('只有释义系部位可以 per-dictionary', () {
      // 作用域锚点 [data-dictionary] 只包住释义子树；词头/频率/音调/词典名行
      // 都在它外面，per-dict 对它们无从谈起。
      final Set<DictStylePart> perDict = DictStylePart.values
          .where(dictStylePartSupportsPerDictionary)
          .toSet();
      expect(perDict, <DictStylePart>{
        DictStylePart.glossaryContent,
        DictStylePart.glossaryTag,
      });
    });
  });

  group('编解码', () {
    test('空表编码成空串，不留空数组残骸', () {
      expect(encodeDictStyleRules(const <DictStyleRule>[]), '');
    });

    test('空属性的规则不落盘', () {
      final String raw = encodeDictStyleRules(<DictStyleRule>[
        const DictStyleRule(part: DictStylePart.expression),
      ]);
      expect(raw, '');
    });

    test('往返保真', () {
      final List<DictStyleRule> original = <DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.expression,
          props: DictStyleProps(textColor: 0xFFEE3333, bold: true),
        ),
        const DictStyleRule(
          part: DictStylePart.glossaryContent,
          dictionaryName: '三省堂',
          props: DictStyleProps(backgroundColor: 0x80FFFF00, fontScale: 1.2),
        ),
      ];
      final List<DictStyleRule> back = decodeDictStyleRules(
        encodeDictStyleRules(original),
      );
      expect(back.length, 2);
      expect(back[0].part, DictStylePart.expression);
      expect(back[0].props.textColor, 0xFFEE3333);
      expect(back[0].props.bold, isTrue);
      expect(back[1].dictionaryName, '三省堂');
      expect(back[1].props.fontScale, 1.2);
    });

    test('坏数据一律回空表，不抛', () {
      expect(decodeDictStyleRules(''), isEmpty);
      expect(decodeDictStyleRules('not json'), isEmpty);
      expect(decodeDictStyleRules('{"a":1}'), isEmpty);
      expect(decodeDictStyleRules('[1,2,3]'), isEmpty);
    });

    test('未知部位名被跳过，不退化成 entryCard', () {
      // firstWhere 的 orElse 是防御性兜底，不该成为「未知名字静默变成词条卡」
      // 的入口——那会让一条用户没设过的规则凭空生效。
      final List<DictStyleRule> rules = decodeDictStyleRules(
        '[{"part":"nonexistentPart","props":{"bold":true}}]',
      );
      expect(rules, isEmpty);
    });

    test('非法组合在解码期被抹平：非释义部位不保留词典名', () {
      final List<DictStyleRule> rules = decodeDictStyleRules(
        '[{"part":"expression","dictionaryName":"三省堂","props":{"bold":true}}]',
      );
      expect(rules.single.dictionaryName, isNull);
    });
  });

  group('全局 CSS 编译', () {
    test('每条声明都带 !important', () {
      // 词典自带 styles.css 是同特异度（甚至更高），不加 !important 就是设了没反应。
      final String css = buildGlobalDictStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.expression,
          props: DictStyleProps(
            textColor: 0xFFEE3333,
            backgroundColor: 0xFFFFFF88,
            bold: true,
            italic: false,
            underline: true,
            fontScale: 1.25,
          ),
        ),
      ]);
      final List<String> decls = css
          .substring(css.indexOf('{') + 1, css.lastIndexOf('}'))
          .split(';')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      expect(decls, isNotEmpty);
      for (final String d in decls) {
        expect(d, contains('!important'), reason: '$d 少了 !important');
      }
    });

    test('选择器正确且颜色走 rgba', () {
      final String css = buildGlobalDictStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.glossaryContent,
          props: DictStyleProps(textColor: 0xFF102030),
        ),
      ]);
      expect(css, startsWith('.glossary-content {'));
      expect(css, contains('color: rgba(16, 32, 48, 1) !important'));
    });

    test('半透明背景 alpha 正确', () {
      final String css = buildGlobalDictStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.glossaryTag,
          props: DictStyleProps(backgroundColor: 0x80FF0000),
        ),
      ]);
      expect(css, contains('rgba(255, 0, 0, 0.502)'));
    });

    test('bool false 生成显式复位值，不是省略', () {
      // 「取消加粗」必须真的写 normal——省略等于继承词典自己的 bold，用户会看到
      // 关掉开关没反应。
      final String css = buildGlobalDictStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.expression,
          props: DictStyleProps(bold: false, italic: false, underline: false),
        ),
      ]);
      expect(css, contains('font-weight: normal !important'));
      expect(css, contains('font-style: normal !important'));
      expect(css, contains('text-decoration: none !important'));
    });

    test('圆角连带 inline-block，否则 inline 元素上看不见', () {
      final String css = buildGlobalDictStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.expressionTag,
          props: DictStyleProps(cornerRadius: 4),
        ),
      ]);
      expect(css, contains('border-radius: 4px !important'));
      expect(css, contains('display: inline-block !important'));
    });

    test('浮点尾巴被裁掉', () {
      final String css = buildGlobalDictStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.ruby,
          props: DictStyleProps(fontScale: 1.0),
        ),
      ]);
      expect(css, contains('font-size: 1em !important'));
      expect(css, isNot(contains('1.000em')));
    });

    test('per-dict 规则不出现在全局产物里', () {
      final String css = buildGlobalDictStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.glossaryContent,
          dictionaryName: '三省堂',
          props: DictStyleProps(bold: true),
        ),
      ]);
      expect(css, isEmpty);
    });

    test('空规则表产出空串', () {
      expect(buildGlobalDictStyleCss(const <DictStyleRule>[]), isEmpty);
    });
  });

  group('per-dictionary CSS 编译', () {
    test('不自己加 [data-dictionary] 前缀（下发链已经会加一次）', () {
      // 自己再加一次会变成 [data-dictionary="X"] [data-dictionary="X"] .foo，
      // 一条都命中不了。作用域由 assets/popup/dict-media.js 的 constructDictCss 负责。
      final String css = buildPerDictionaryStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.glossaryContent,
          dictionaryName: '三省堂',
          props: DictStyleProps(bold: true),
        ),
      ], '三省堂');
      expect(css, startsWith('.glossary-content {'));
      expect(css, isNot(contains('data-dictionary')));
    });

    test('只挑本词典的规则', () {
      final List<DictStyleRule> rules = <DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.glossaryContent,
          dictionaryName: '三省堂',
          props: DictStyleProps(bold: true),
        ),
        const DictStyleRule(
          part: DictStylePart.glossaryTag,
          dictionaryName: '大辞林',
          props: DictStyleProps(italic: true),
        ),
      ];
      expect(
        buildPerDictionaryStyleCss(rules, '三省堂'),
        contains('font-weight: bold'),
      );
      expect(
        buildPerDictionaryStyleCss(rules, '三省堂'),
        isNot(contains('font-style: italic')),
      );
    });

    test('第二道闸：直接构造的非法组合也被挡', () {
      // 绕过 decode 直接构造对象（测试 / 未来的导入路径）不该能产出一条
      // 打不中任何东西的规则。
      final String css = buildPerDictionaryStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.expression,
          dictionaryName: '三省堂',
          props: DictStyleProps(bold: true),
        ),
      ], '三省堂');
      expect(css, isEmpty);
    });

    test('空词典名产出空串', () {
      expect(
        buildPerDictionaryStyleCss(<DictStyleRule>[
          const DictStyleRule(
            part: DictStylePart.glossaryContent,
            dictionaryName: '',
            props: DictStyleProps(bold: true),
          ),
        ], ''),
        isEmpty,
      );
    });

    test('dictionariesWithStyleRules 只收合法的 per-dict 词典名', () {
      final Set<String> names = dictionariesWithStyleRules(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.glossaryContent,
          dictionaryName: '三省堂',
          props: DictStyleProps(bold: true),
        ),
        const DictStyleRule(
          part: DictStylePart.expression,
          dictionaryName: '大辞林',
          props: DictStyleProps(bold: true),
        ),
        const DictStyleRule(
          part: DictStylePart.glossaryTag,
          props: DictStyleProps(bold: true),
        ),
      ]);
      expect(names, <String>{'三省堂'});
    });
  });

  group('非 Dart 消费方的产物缓存', () {
    test('全空返回空串，消费方一个 if 就能短路', () {
      expect(encodeCompiledDictStyleCss(const <DictStyleRule>[]), '');
    });

    test('同时带上全局与单典两份', () {
      // 只存全局的话，per-dict 规则会在 Android 独立弹窗里静默失效。
      final String raw = encodeCompiledDictStyleCss(<DictStyleRule>[
        const DictStyleRule(
          part: DictStylePart.expression,
          props: DictStyleProps(bold: true),
        ),
        const DictStyleRule(
          part: DictStylePart.glossaryContent,
          dictionaryName: '三省堂',
          props: DictStyleProps(italic: true),
        ),
      ]);
      final Map<String, dynamic> decoded =
          jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['global'], contains('.expression {'));
      final Map<String, dynamic> byDict =
          decoded['byDictionary'] as Map<String, dynamic>;
      expect(byDict.keys, <String>['三省堂']);
      expect(byDict['三省堂'], contains('font-style: italic'));
      // 单典段不能自带前缀——消费方把它塞进 custom_dict_css，下游还会再加一次。
      expect(byDict['三省堂'], isNot(contains('data-dictionary')));
    });

    test('只有全局规则时 byDictionary 为空对象而非缺字段', () {
      final Map<String, dynamic> decoded = jsonDecode(
        encodeCompiledDictStyleCss(<DictStyleRule>[
          const DictStyleRule(
            part: DictStylePart.pitch,
            props: DictStyleProps(bold: true),
          ),
        ]),
      ) as Map<String, dynamic>;
      expect(decoded['byDictionary'], isEmpty);
      expect(decoded.containsKey('byDictionary'), isTrue);
    });
  });

  group('与手写 CSS 拼接', () {
    test('产物在前、手写在后（手写优先）', () {
      final String merged = mergeGeneratedAndAuthoredCss(
        '.expression { color: red !important; }',
        '.expression { color: blue !important; }',
      );
      expect(
        merged.indexOf('red'),
        lessThan(merged.indexOf('blue')),
        reason: '手写必须在后，才能覆盖可视化面板设的值',
      );
    });

    test('任一侧为空时原样返回另一侧', () {
      expect(mergeGeneratedAndAuthoredCss('', '.a{}'), '.a{}');
      expect(mergeGeneratedAndAuthoredCss('.a{}', ''), '.a{}');
      expect(mergeGeneratedAndAuthoredCss('   ', '.a{}'), '.a{}');
    });
  });
}
