import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/dictionary_language_css.dart';

/// 生成的 CSS 里 [first] 规则必须出现在 [second] 之前。
///
/// 三层规则（root / per-dictionary / :lang）特异性相同，**谁在后谁生效**。
/// 顺序就是优先级，所以顺序断言不是风格检查，是行为断言。
void expectRuleOrder(String css, String first, String second) {
  final int a = css.indexOf(first);
  final int b = css.indexOf(second);
  expect(a, isNonNegative, reason: '缺规则 $first:\n$css');
  expect(b, isNonNegative, reason: '缺规则 $second:\n$css');
  expect(a, lessThan(b), reason: '$first 必须写在 $second 之前:\n$css');
}

void main() {
  const List<DictionaryLanguageEntry> noDictionaries =
      <DictionaryLanguageEntry>[];

  group('dictionaryLanguageFontCss', () {
    test('总是产出根兜底链，即使没有词典也没有自定义字体', () {
      // 这正是 Discord 报的症状的修复点：popup.css 原本只写了 macOS 的 Hiragino，
      // Windows/Android 上一个存在的 CJK 家族都没有 → 掉进 sans-serif → 由系统
      // locale 决定 CJK 字形。兜底链与「用户是否配了字体」无关。
      final String css = dictionaryLanguageFontCss(
        customFamilies: const <String>[],
        dictionaries: noDictionaries,
        platform: TargetPlatform.windows,
      );
      expect(css, contains('html, body'));
      expect(css, contains('Yu Gothic UI'));
    });

    test('繁体规则必须写在简体之后（:lang(zh) 会前缀命中 zh-Hant）', () {
      // CSS `:lang(zh)` 按 BCP-47 前缀匹配，`lang="zh-Hant"` 的子树**同时**命中
      // :lang(zh) 和 :lang(zh-Hant)。两者特异性相同 → 后写的赢。写反了繁体子树
      // 就被简体链接管，而「门/門」这种字形差异用户一眼能看出来。
      final String css = dictionaryLanguageFontCss(
        customFamilies: const <String>[],
        dictionaries: noDictionaries,
        platform: TargetPlatform.windows,
      );
      expectRuleOrder(css, ':lang(zh)', ':lang(zh-Hant)');
    });

    test('节点级 :lang 规则排在词典级规则之后（作者标注更精确）', () {
      final String css = dictionaryLanguageFontCss(
        customFamilies: const <String>[],
        dictionaries: const <DictionaryLanguageEntry>[
          DictionaryLanguageEntry(name: '大辞林', glossaryLanguage: 'ja'),
        ],
        platform: TargetPlatform.windows,
      );
      expectRuleOrder(css, '[data-dictionary="大辞林"]', ':lang(ja)');
      // 根兜底又必须排在词典级之前，否则它会盖掉所有分流。
      expectRuleOrder(css, 'html, body', '[data-dictionary="大辞林"]');
    });

    test('日中词典的释义区按 targetLanguage 走中文链', () {
      final String css = dictionaryLanguageFontCss(
        customFamilies: const <String>[],
        dictionaries: const <DictionaryLanguageEntry>[
          DictionaryLanguageEntry(name: '日中辞典', glossaryLanguage: 'zh-Hans'),
        ],
        platform: TargetPlatform.windows,
      );
      final int start = css.indexOf('[data-dictionary="日中辞典"]');
      expect(start, isNonNegative);
      final String rule = css.substring(start, css.indexOf('}', start));
      // 中文黑体必须**排在**日文黑体之前。日文仍在链里是有意的（中文释义里夹
      // 日文例句时的缺字续接），所以这里不能断言「不含日文家族」——那会把正确的
      // 兜底段判成 bug。真正要守的是顺序：链首决定绝大多数字的字形。
      expect(rule.indexOf('Microsoft YaHei UI'), isNonNegative);
      expect(
        rule.indexOf('Microsoft YaHei UI'),
        lessThan(rule.indexOf('Yu Gothic UI')),
        reason: '中文释义区的链首不该是日文黑体: $rule',
      );
    });

    test('同语言的多本词典合并成一条选择器', () {
      final String css = dictionaryLanguageFontCss(
        customFamilies: const <String>[],
        dictionaries: const <DictionaryLanguageEntry>[
          DictionaryLanguageEntry(name: 'A', glossaryLanguage: 'ja'),
          DictionaryLanguageEntry(name: 'B', glossaryLanguage: 'ja'),
        ],
        platform: TargetPlatform.windows,
      );
      expect(css, contains('[data-dictionary="A"], [data-dictionary="B"]'));
    });

    test('语言未知或非 CJK 的词典不产生规则（落到兜底链）', () {
      final String css = dictionaryLanguageFontCss(
        customFamilies: const <String>[],
        dictionaries: const <DictionaryLanguageEntry>[
          DictionaryLanguageEntry(name: '未声明', glossaryLanguage: null),
          DictionaryLanguageEntry(name: '空串', glossaryLanguage: '  '),
          DictionaryLanguageEntry(name: '英英', glossaryLanguage: 'en'),
        ],
        platform: TargetPlatform.windows,
      );
      expect(css.contains('[data-dictionary="未声明"]'), isFalse);
      expect(css.contains('[data-dictionary="空串"]'), isFalse);
      expect(css.contains('[data-dictionary="英英"]'), isFalse,
          reason: '非 CJK 词典套 CJK 链只会把拉丁排版也换掉');
    });

    test('词典名里的引号被转义（词典名来自用户导入的包名）', () {
      final String css = dictionaryLanguageFontCss(
        customFamilies: const <String>[],
        dictionaries: const <DictionaryLanguageEntry>[
          DictionaryLanguageEntry(
            name: 'evil"] { display: none } [x="',
            glossaryLanguage: 'ja',
          ),
        ],
        platform: TargetPlatform.windows,
      );
      // 未转义的话属性选择器会被提前闭合，后面那段变成一条真规则。
      // 判据必须看**未转义**的引号：转义后的串里当然还含 `"] { display: none }`
      // 这个子串（它前面多了个反斜杠），拿裸子串判会把已修好的实现判成失败。
      // 精确断言转义结果：名字里的每个 `"` 都必须带反斜杠出现在选择器里。
      // （不要靠「切到第一个 `{`」再数引号——恶意名字里就有 `{`，切片会被它骗到，
      //  把已修好的实现判成失败。）
      expect(
        css,
        contains(r'[data-dictionary="evil\"] { display: none } [x=\""]'),
      );
      // 负向：未转义的原样选择器绝不能出现（那才是真被提前闭合）。
      expect(
        css.contains('[data-dictionary="evil"] { display: none } [x=""]'),
        isFalse,
        reason: '属性选择器被提前闭合了:\n$css',
      );
    });

    test('用户自定义字体进每一条规则的链首', () {
      final String css = dictionaryLanguageFontCss(
        customFamilies: const <String>['My Font'],
        dictionaries: const <DictionaryLanguageEntry>[
          DictionaryLanguageEntry(name: 'D', glossaryLanguage: 'ja'),
        ],
        platform: TargetPlatform.windows,
      );
      for (final String line in css.split('\n')) {
        if (!line.contains('font-family:')) continue;
        final int mine = line.indexOf('"My Font"');
        expect(mine, isNonNegative, reason: '每条规则都该带上用户字体: $line');
        if (line.contains('"Yu Gothic UI"')) {
          expect(
            mine,
            lessThan(line.indexOf('"Yu Gothic UI"')),
            reason: '用户字体必须压过系统字体: $line',
          );
        }
      }
    });
  });
}
