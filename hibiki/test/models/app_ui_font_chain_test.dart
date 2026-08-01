import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_ui_font_chain.dart';

/// 界面字体回退链的行为契约。
///
/// 背景：字体本质是**有序回退链**，旧实现把它压成单值（`AppFontLoader` 只返回第一个
/// enabled 条目、无自定义字体时 fontFamily 为 null 完全交给引擎默认 fallback），
/// 由此产生三个用户可见症状：中文默认字体难看、日文 face 缺简中字时逐字乱回退、
/// 用户排在第 2 位的字体永远轮不到。本文件钉住修复后的链构造规则。
void main() {
  List<String> chain({
    List<String> custom = const <String>[],
    String locale = 'zh',
    String? country,
    String? script,
    TargetPlatform platform = TargetPlatform.windows,
  }) =>
      appUiFontChain(
        customFamilies: custom,
        locale: Locale.fromSubtags(
          languageCode: locale,
          scriptCode: script,
          countryCode: country,
        ),
        platform: platform,
      );

  group('显示语言决定链首（BUG-068：界面字形跟 appLocale，不跟日语阅读语言）', () {
    test('zh-CN 界面 → 简中字体打头，而不是日文字体', () {
      final List<String> windows = chain(locale: 'zh', country: 'CN');
      expect(windows.first, 'Microsoft YaHei UI');

      final List<String> android =
          chain(locale: 'zh', country: 'CN', platform: TargetPlatform.android);
      expect(android.first, 'Noto Sans CJK SC');

      final List<String> mac =
          chain(locale: 'zh', country: 'CN', platform: TargetPlatform.macOS);
      expect(mac.first, 'PingFang SC');
    });

    test('zh-HK / zh-TW → 繁体字形，不与简体共用一条链', () {
      // Han 统一码位下繁简字形对读者可见（门/門），共用一条链等于放弃字形正确性。
      expect(chain(locale: 'zh', country: 'HK').first, 'Microsoft JhengHei UI');
      expect(
        chain(locale: 'zh', country: 'TW', platform: TargetPlatform.macOS)
            .first,
        'PingFang TC',
      );
      // 显式 script 子标签优先于地区推断。
      expect(
        chain(locale: 'zh', script: 'Hant', country: 'CN').first,
        'Microsoft JhengHei UI',
      );
      expect(
        chain(locale: 'zh', script: 'Hans', country: 'TW').first,
        'Microsoft YaHei UI',
      );
    });

    test('ja / ko 界面各自打头', () {
      expect(chain(locale: 'ja').first, 'Yu Gothic UI');
      expect(chain(locale: 'ko').first, 'Malgun Gothic');
      expect(
        chain(locale: 'ja', platform: TargetPlatform.iOS).first,
        'Hiragino Sans',
      );
    });
  });

  group('非 CJK 界面语言不被接管（防「修 CJK 缺字反而毁拉丁排版」）', () {
    test('en 界面 + 无自定义字体 → 空链（保持平台默认，与改造前一致）', () {
      // fontFamily 为 null 时引擎把 fallback 首项当主字体，拉丁字形也归它管。
      // 此时强塞 CJK 链会让英文界面整体被 CJK 字体的拉丁部分接管。
      expect(chain(locale: 'en'), isEmpty);
      expect(chain(locale: 'fr', platform: TargetPlatform.macOS), isEmpty);
    });

    test('en 界面 + 有自定义字体 → 自定义打头，CJK 只做缺字兜底', () {
      final List<String> result =
          chain(custom: <String>['Inter'], locale: 'en');
      expect(result.first, 'Inter');
      // 主字体存在 → 链只在缺字时生效，不影响拉丁，可以放心追加 CJK。
      expect(result, contains('Yu Gothic UI'));
      expect(result, contains('Microsoft YaHei UI'));
    });
  });

  group('用户自定义列表整条进链（旧实现只取第一条，其余全丢）', () {
    test('多条自定义字体按用户顺序排在最前', () {
      final List<String> result = chain(
        custom: <String>['My Serif', 'My Gothic', 'My Mincho'],
        locale: 'zh',
        country: 'CN',
      );
      expect(result.take(3), <String>['My Serif', 'My Gothic', 'My Mincho']);
      // 用户字体之后才是显示语言的系统字体。
      expect(result[3], 'Microsoft YaHei UI');
    });

    test('空白名被跳过，重复项只保留第一次出现的位置', () {
      final List<String> result = chain(
        custom: <String>['My Gothic', '   ', 'My Gothic', 'Microsoft YaHei UI'],
        locale: 'zh',
        country: 'CN',
      );
      expect(result.take(2), <String>['My Gothic', 'Microsoft YaHei UI']);
      expect(
        result.where((String f) => f == 'My Gothic').length,
        1,
        reason: '重复家族名只会拖慢解析，且让「第几个生效」无法推理',
      );
      expect(result.where((String f) => f == 'Microsoft YaHei UI').length, 1,
          reason: '用户手动加的系统字体名不该在语言链里再出现一次');
      expect(result, isNot(contains('   ')));
      expect(result, isNot(contains('')));
    });

    test('自定义字体名两端空白被裁掉（否则引擎按原样比对家族名，永远解析不到）', () {
      expect(chain(custom: <String>['  My Gothic  '], locale: 'en').first,
          'My Gothic');
    });
  });

  group('缺字兜底覆盖全部 CJK 语言', () {
    test('中文界面下日文兜底排在其余 CJK 之前（本 app 内容以日文为主）', () {
      final List<String> result = chain(locale: 'zh', country: 'CN');
      final int yahei = result.indexOf('Microsoft YaHei UI');
      final int yuGothic = result.indexOf('Yu Gothic UI');
      expect(yahei, isNonNegative);
      expect(yuGothic, greaterThan(yahei), reason: '显示语言的字体必须排在兜底之前');
      // 弱断言「日文在显示语言之后」是废话——显示语言本来就在最前。真正要钉住的是
      // 日文在**兜底段内部**排第一：假名与日文专用汉字在中文字体里缺字率最高，把它
      // 挪到繁中/韩文之后，最常见的缺字就会先撞上两套不相干的 face。
      expect(yuGothic, lessThan(result.indexOf('Microsoft JhengHei UI')),
          reason: '日文兜底必须排在繁中之前');
      expect(yuGothic, lessThan(result.indexOf('Malgun Gothic')),
          reason: '日文兜底必须排在韩文之前');
    });

    test('日文界面链尾含简中字体（中文书名/界面文案的缺字兜底）', () {
      final List<String> result = chain(locale: 'ja');
      expect(result.first, 'Yu Gothic UI');
      expect(result, contains('Microsoft YaHei UI'));
    });

    test('四种 CJK 书写系统在任一 CJK 界面下都出现', () {
      for (final String lang in <String>['zh', 'ja', 'ko']) {
        final List<String> result = chain(locale: lang);
        expect(result, contains('Yu Gothic UI'), reason: '$lang 缺日文兜底');
        expect(result, contains('Microsoft YaHei UI'), reason: '$lang 缺简中兜底');
        expect(result, contains('Microsoft JhengHei UI'),
            reason: '$lang 缺繁中兜底');
        expect(result, contains('Malgun Gothic'), reason: '$lang 缺韩文兜底');
      }
    });

    test('每个平台只产出该平台的字体名，不混入别平台的家族', () {
      final List<String> windows = chain(locale: 'zh', country: 'CN');
      expect(windows, isNot(contains('PingFang SC')));
      expect(windows, isNot(contains('Noto Sans CJK SC')));

      final List<String> apple =
          chain(locale: 'zh', country: 'CN', platform: TargetPlatform.macOS);
      expect(apple, isNot(contains('Microsoft YaHei UI')));
      expect(apple, contains('Hiragino Sans'));

      final List<String> linux =
          chain(locale: 'zh', country: 'CN', platform: TargetPlatform.linux);
      expect(linux, isNot(contains('Microsoft YaHei UI')));
      expect(linux, contains('Noto Sans CJK JP'));
    });
  });

  test('链不可变（调用方拿到的是快照，不能就地改写共享常量）', () {
    final List<String> result = chain(locale: 'zh', country: 'CN');
    expect(() => result.add('X'), throwsUnsupportedError);
  });
}
