import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/cjk_font_families.dart';
import 'package:fushi/src/models/content_font_chain.dart';

/// 断言 [chain] 里 [first] 出现在 [second] 之前（两者都必须存在）。
///
/// 字体链的正确性几乎全在**顺序**上：链首决定拉丁归谁管，繁简谁在前决定
/// 「门/門」怎么显示。只断言「包含」的测试对调换顺序的回归是瞎的。
void expectOrdered(List<String> chain, String first, String second) {
  final int a = chain.indexOf(first);
  final int b = chain.indexOf(second);
  expect(a, isNonNegative, reason: '$first 不在链里: $chain');
  expect(b, isNonNegative, reason: '$second 不在链里: $chain');
  expect(a, lessThan(b), reason: '$first 应排在 $second 之前: $chain');
}

void main() {
  group('cjkScriptForLanguageTag', () {
    test('识别常见写法与大小写/分隔符变体', () {
      expect(cjkScriptForLanguageTag('ja'), CjkScript.japanese);
      expect(cjkScriptForLanguageTag('JA-JP'), CjkScript.japanese);
      expect(cjkScriptForLanguageTag('jpn'), CjkScript.japanese);
      expect(cjkScriptForLanguageTag('ko'), CjkScript.korean);
      // EPUB 的 dc:language 常见 `zh_CN` 这种下划线写法。
      expect(cjkScriptForLanguageTag('zh_CN'), CjkScript.simplifiedChinese);
      expect(cjkScriptForLanguageTag('  ja  '), CjkScript.japanese);
    });

    test('繁简分流：script 子标签优先于地区', () {
      expect(cjkScriptForLanguageTag('zh'), CjkScript.simplifiedChinese);
      expect(cjkScriptForLanguageTag('zh-Hant'), CjkScript.traditionalChinese);
      expect(cjkScriptForLanguageTag('zh-TW'), CjkScript.traditionalChinese);
      expect(cjkScriptForLanguageTag('zh-HK'), CjkScript.traditionalChinese);
      expect(
          cjkScriptForLanguageTag('zh-Hans-TW'), CjkScript.simplifiedChinese);
      // 粤语默认繁体，但显式 Hans 要尊重。
      expect(cjkScriptForLanguageTag('yue'), CjkScript.traditionalChinese);
      expect(cjkScriptForLanguageTag('yue-Hans'), CjkScript.simplifiedChinese);
    });

    test('非 CJK 与空值返回 null（调用方据此决定不猜）', () {
      expect(cjkScriptForLanguageTag('en'), isNull);
      expect(cjkScriptForLanguageTag('fr-CA'), isNull);
      expect(cjkScriptForLanguageTag(''), isNull);
      expect(cjkScriptForLanguageTag('   '), isNull);
      expect(cjkScriptForLanguageTag(null), isNull);
    });
  });

  group('contentFontFamilies', () {
    test('语言未知且无自定义字体 → 空链（不接管拉丁排版）', () {
      // 这是整个设计的核心不变式：CSS font-family 列表里第一个含该字形的 face
      // 就胜出，而拉丁字母几乎每个 CJK face 都有。链首放 CJK face = 把西文排版
      // 也交给它。语言真的未知时宁可什么都不写。
      expect(
        contentFontFamilies(
          languageTag: null,
          platform: TargetPlatform.windows,
        ),
        isEmpty,
      );
      expect(
        contentFontFamilies(
          languageTag: 'en',
          platform: TargetPlatform.windows,
        ),
        isEmpty,
      );
    });

    test('fallbackWhenUnknown 打开时给受控顺序，日文在最前', () {
      final List<String> chain = contentFontFamilies(
        languageTag: null,
        platform: TargetPlatform.windows,
        fallbackWhenUnknown: true,
      );
      expect(chain, isNotEmpty);
      // 日文家族必须排在中文家族之前，否则「无信息时」又回到中文字形。
      expectOrdered(chain, 'Yu Gothic UI', 'Microsoft YaHei UI');
    });

    test('已知语言时该语言排在其余 CJK 兜底之前', () {
      final List<String> chain = contentFontFamilies(
        languageTag: 'zh-Hant',
        platform: TargetPlatform.windows,
      );
      // 繁体是内容语言 → 必须压过兜底段里排第一的日文。只断言「包含繁体家族」
      // 会漏掉「繁体被日文挤到后面」这种真回归。
      expectOrdered(chain, 'Microsoft JhengHei UI', 'Yu Gothic UI');
      expectOrdered(chain, 'Microsoft JhengHei UI', 'Microsoft YaHei UI');
    });

    test('用户自定义字体永远在系统字体之前', () {
      final List<String> chain = contentFontFamilies(
        languageTag: 'ja',
        platform: TargetPlatform.windows,
        customFamilies: <String>['My Font', '  ', 'Second Font'],
      );
      expect(chain.first, 'My Font');
      expectOrdered(chain, 'Second Font', 'Yu Gothic UI');
      // 空白项被丢弃，不产生空家族名。
      expect(chain.contains(''), isFalse);
    });

    test('自定义字体让「未知语言」也不再返回空链', () {
      final List<String> chain = contentFontFamilies(
        languageTag: null,
        platform: TargetPlatform.windows,
        customFamilies: <String>['My Font'],
      );
      // 用户显式选了字体 = 有主字体 = 追加 CJK 兜底不会伤到拉丁。
      expect(chain.first, 'My Font');
      expect(chain.length, greaterThan(1));
    });

    test('去重且保序（用户手动加了同名系统字体时）', () {
      final List<String> chain = contentFontFamilies(
        languageTag: 'ja',
        platform: TargetPlatform.windows,
        customFamilies: <String>['Meiryo'],
      );
      expect(chain.first, 'Meiryo');
      expect(
        chain.where((String f) => f == 'Meiryo').length,
        1,
        reason: '同一家族名不该在链里出现两次: $chain',
      );
    });

    test('serif 风格给明朝体/宋体，不是黑体', () {
      final List<String> serif = contentFontFamilies(
        languageTag: 'ja',
        platform: TargetPlatform.windows,
        style: CjkFontStyle.serif,
      );
      expect(serif, contains('Yu Mincho'));
      expect(serif.contains('Yu Gothic UI'), isFalse,
          reason: 'serif 链里混进黑体说明取表取错了: $serif');
    });

    test('按平台取各自存在的家族名', () {
      expect(
        contentFontFamilies(
          languageTag: 'ja',
          platform: TargetPlatform.macOS,
        ),
        contains('Hiragino Sans'),
      );
      expect(
        contentFontFamilies(
          languageTag: 'ja',
          platform: TargetPlatform.android,
        ),
        contains('Noto Sans CJK JP'),
      );
      // Windows 的家族名不该出现在 Apple 平台的链里。
      expect(
        contentFontFamilies(
          languageTag: 'ja',
          platform: TargetPlatform.macOS,
        ).contains('Yu Gothic UI'),
        isFalse,
      );
    });
  });

  group('contentFontFamilyCss', () {
    test('空链 → 空串（调用方据此整条声明都不写）', () {
      expect(
        contentFontFamilyCss(
          languageTag: null,
          platform: TargetPlatform.windows,
        ),
        isEmpty,
      );
    });

    test('家族名加引号并以 generic family 收尾', () {
      final String css = contentFontFamilyCss(
        languageTag: 'ja',
        platform: TargetPlatform.windows,
      );
      expect(css, startsWith('"Yu Gothic UI"'));
      expect(css, endsWith(', sans-serif'));
      final String serifCss = contentFontFamilyCss(
        languageTag: 'ja',
        platform: TargetPlatform.windows,
        style: CjkFontStyle.serif,
      );
      expect(serifCss, endsWith(', serif'));
    });

    test('用户字体名里的引号/反斜杠被转义（CSS 注入防线）', () {
      final String css = contentFontFamilyCss(
        languageTag: 'ja',
        platform: TargetPlatform.windows,
        customFamilies: <String>['Evil", monospace; color: red; x: "'],
      );
      // 未转义的话这里会出现一个提前闭合的引号，把后面的内容变成新声明。
      expect(css, contains(r'\"'));
      expect(css.contains('color: red;'), isTrue, reason: '文本本身仍在，只是被转义进了字符串里');
      expect(
        RegExp(r'(?<!\\)"').allMatches(css).length.isEven,
        isTrue,
        reason: '未转义的引号必须成对，否则说明字符串被提前闭合: $css',
      );
    });
  });
}
