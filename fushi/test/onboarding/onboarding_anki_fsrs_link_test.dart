import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:fushi/utils.dart' show AppLocale;

/// 新手引导 Anki 步骤的 FSRS 指引外链：中文界面给中文长文，其余语言给 Anki 官方
/// 手册。这条链接是「让用户自己去 Anki 里打开 FSRS」的唯一出口，选错语言等于把
/// 读不懂的页面推给用户。
void main() {
  test('中文界面走中文指引', () {
    expect(ankiFsrsGuideUrl(AppLocale.zhCn), kAnkiFsrsGuideUrlZh);
    expect(ankiFsrsGuideUrl(AppLocale.zhHk), kAnkiFsrsGuideUrlZh);
  });

  test('非中文界面走 Anki 官方手册', () {
    for (final AppLocale locale in AppLocale.values) {
      if (locale.languageCode == 'zh') {
        continue;
      }
      expect(
        ankiFsrsGuideUrl(locale),
        kAnkiFsrsGuideUrlEn,
        reason: '$locale 不该拿到中文页',
      );
    }
  });

  test('两条链接都是可用的 https 地址且互不相同', () {
    // 别用 `Uri.isAbsolute` 当「像不像个网址」的判据：Dart 里带 fragment 的 URI
    // 一律不是 absolute，官方手册那条正好锚在 `#fsrs` 上。真正要守的是 scheme
    // 和 host。
    for (final String url in <String>[
      kAnkiFsrsGuideUrlZh,
      kAnkiFsrsGuideUrlEn,
    ]) {
      final Uri parsed = Uri.parse(url);
      expect(parsed.scheme, 'https', reason: url);
      expect(parsed.host, isNotEmpty, reason: url);
      expect(parsed.hasEmptyPath, isFalse, reason: url);
    }
    expect(kAnkiFsrsGuideUrlZh, isNot(kAnkiFsrsGuideUrlEn));
  });
}
