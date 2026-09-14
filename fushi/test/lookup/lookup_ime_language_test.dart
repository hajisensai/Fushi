import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_ime_language.dart';

void main() {
  group('lookupImeLocaleOf', () {
    test('纯语言码', () {
      expect(lookupImeLocaleOf('ja'), const Locale('ja'));
      expect(lookupImeLocaleOf('ko'), const Locale('ko'));
      expect(lookupImeLocaleOf('en'), const Locale('en'));
    });

    test('带脚本子标签——中文简繁必须能区分', () {
      expect(
        lookupImeLocaleOf('zh-Hans'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      );
      expect(
        lookupImeLocaleOf('zh-Hant'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      );
    });

    test('带地区、以及脚本+地区', () {
      expect(
        lookupImeLocaleOf('ja-JP'),
        Locale.fromSubtags(languageCode: 'ja', countryCode: 'JP'),
      );
      expect(
        lookupImeLocaleOf('zh-Hans-CN'),
        Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'CN',
        ),
      );
    });

    test('大小写与下划线分隔都归一化', () {
      expect(
        lookupImeLocaleOf('ZH_hans_cn'),
        Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'CN',
        ),
      );
      expect(lookupImeLocaleOf('  ja  '), const Locale('ja'));
    });

    test('未设置 / 空值 = 无偏好', () {
      expect(lookupImeLocaleOf(null), isNull);
      expect(lookupImeLocaleOf(''), isNull);
      expect(lookupImeLocaleOf('   '), isNull);
    });

    test('认不出的标签一律作废，绝不猜', () {
      // 猜错会把用户键盘切成另一种语言，比不切更糟。
      expect(lookupImeLocaleOf('j'), isNull);
      expect(lookupImeLocaleOf('japanese'), isNull);
      expect(lookupImeLocaleOf('123'), isNull);
      expect(lookupImeLocaleOf('ja-JP-x-private'), isNull);
      expect(lookupImeLocaleOf('zh-Hans-Hant'), isNull);
      expect(lookupImeLocaleOf('ja-JP-US'), isNull);
    });
  });

  group('lookupImeLanguageMatches', () {
    // 这条规则必须和三端原生实现一致，否则设置页会说「装了」而原生侧找不到。
    test('主语言相同就算，地区不挑', () {
      expect(lookupImeLanguageMatches('ja', 'ja-JP'), isTrue);
      expect(lookupImeLanguageMatches('en', 'en-GB'), isTrue);
      expect(lookupImeLanguageMatches('ko', 'ko-KR'), isTrue);
    });

    test('主语言不同一律不匹配', () {
      expect(lookupImeLanguageMatches('ja', 'en-US'), isFalse);
      expect(lookupImeLanguageMatches('ja', ''), isFalse);
      expect(lookupImeLanguageMatches('', 'ja'), isFalse);
    });

    test('中文要分简繁——装了拼音打不出繁体', () {
      expect(lookupImeLanguageMatches('zh-Hans', 'zh-Hans-CN'), isTrue);
      expect(lookupImeLanguageMatches('zh-Hans', 'zh-CN'), isTrue);
      expect(lookupImeLanguageMatches('zh-Hans', 'zh-Hant-TW'), isFalse);
      expect(lookupImeLanguageMatches('zh-Hant', 'zh-TW'), isTrue);
      expect(lookupImeLanguageMatches('zh-Hant', 'zh-HK'), isTrue);
    });

    test('裸 zh 不挑简繁', () {
      expect(lookupImeLanguageMatches('zh', 'zh-Hans-CN'), isTrue);
      expect(lookupImeLanguageMatches('zh', 'zh-Hant-TW'), isTrue);
    });
  });

  group('lookupImeHintLocalesOf', () {
    test('有值时是单元素列表', () {
      expect(lookupImeHintLocalesOf('ja'), <Locale>[const Locale('ja')]);
    });

    test('没设过返回 null 而不是空列表', () {
      // Flutter 契约：空 list = 「明确不要任何提示」，会压掉输入法自己的语言记忆；
      // null 才是「用户没表达偏好」。
      expect(lookupImeHintLocalesOf(null), isNull);
      expect(lookupImeHintLocalesOf('nonsense'), isNull);
    });
  });
}
