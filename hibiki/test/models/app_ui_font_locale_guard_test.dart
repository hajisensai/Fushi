import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-068 guard: the app-wide UI [TextStyle] must follow the *display*
/// language ([appLocale]), not the pinned Japanese reading language
/// ([targetLanguage]).
///
/// The old `textStyle` hard-coded `fontFamily: appFontFamily ?? targetLanguage
/// .defaultFontFamily` (= 'NotoSansJP', a phantom family that is never bundled
/// or registered) and `locale: targetLanguage.locale` (= `ja`). On every
/// Material platform that forced Chinese (and all other) UI text through a
/// Japanese-locale font fallback, so Han ideographs rendered with Japanese
/// glyph variants (CJK unification) — visibly wrong to a Chinese reader, worst
/// on Windows where the `ja` hint pulls in Yu Gothic / Meiryo.
///
/// AppModel needs a live Drift database to instantiate, so the `textStyle`
/// getter cannot be unit-instantiated cheaply. A source-scan guard is the
/// strongest feasible layer to pin the wiring and stop a revert to the
/// Japanese pin.
void main() {
  late String textStyleSource;
  late String appLocaleGetterSource;
  late String primaryMaterialAppSource;

  setUpAll(() {
    final String source =
        File('lib/src/models/app_model.dart').readAsStringSync();
    // Anchor on the bare member name so the guard survives a getter-shape
    // change (`=> ...` vs `{ ... }`) and the red signal comes from the content
    // assertions below, not from the marker disappearing.
    textStyleSource = _functionSource(
      source,
      'get textStyle',
      // The next member after textStyle / its helper.
      'TextTheme get textTheme',
    );

    final String mainSource =
        File('lib/main.dart').readAsStringSync().replaceAll('\r\n', '\n');
    appLocaleGetterSource = _functionSource(
      mainSource,
      'Locale get locale',
      '}\n\n/// 按实验开关',
    );
    primaryMaterialAppSource = _functionSource(
      mainSource,
      'return TranslationProvider(\n      child: MaterialApp(',
      '\n  }\n\n  /// Responsible for managing global app-wide state.',
    );
  });

  test('textStyle.locale follows the display language (appLocale), not ja', () {
    expect(
      textStyleSource,
      contains('locale: uiLocale'),
      reason: 'textStyle must bind locale to the resolved appLocale',
    );
    expect(
      textStyleSource,
      contains('final Locale uiLocale = appLocale;'),
      reason: 'the UI locale must be appLocale, the display language',
    );
    expect(
      textStyleSource,
      isNot(contains('targetLanguage.locale')),
      reason: 'must NOT pin the UI locale to the Japanese reading language',
    );
  });

  test(
      'textStyle.fontFamily is the user custom font or system default (no '
      'Japanese pin)', () {
    expect(
      textStyleSource,
      contains('fontFamily: appFontFamily,'),
      reason: 'no custom font → null → platform resolves the UI-locale font',
    );
    expect(
      textStyleSource,
      isNot(contains('targetLanguage.defaultFontFamily')),
      reason: 'must NOT fall back to NotoSansJP for the whole UI',
    );
    expect(
      textStyleSource,
      isNot(contains('NotoSansJP')),
      reason: 'no hard-coded Japanese family in the app-chrome text style',
    );
  });

  test('textBaseline is derived from the UI locale, not pinned to Japanese',
      () {
    expect(
      textStyleSource,
      contains('_isIdeographicLocale(uiLocale)'),
      reason: 'CJK locales → ideographic, others → alphabetic baseline',
    );
    expect(
      textStyleSource,
      isNot(contains('targetLanguage.textBaseline')),
      reason: 'baseline must follow the UI locale, not the reading language',
    );
  });

  test('MaterialApp.locale follows display language for system back labels',
      () {
    expect(
      primaryMaterialAppSource,
      contains('locale: locale,'),
      reason:
          'the primary MaterialApp constructor must route localizations through '
          'the locale getter instead of bypassing it',
    );
    expect(
      primaryMaterialAppSource,
      isNot(contains('targetLanguage.locale')),
      reason:
          'MaterialApp.locale must not use the pinned Japanese reading language',
    );
    expect(
      RegExp(r'locale:\s*[^,\n]*targetLanguage\.locale')
          .hasMatch(primaryMaterialAppSource),
      isFalse,
      reason:
          'changing MaterialApp to locale: appModel.targetLanguage.locale must '
          'fail this guard',
    );
    expect(
      appLocaleGetterSource,
      contains('appModel.appLocale'),
      reason:
          'Material/Cupertino localizations must use the display language so '
          'zh-CN back tooltips read 返回 instead of Japanese 戻る',
    );
    expect(
      appLocaleGetterSource,
      isNot(contains('targetLanguage.locale')),
      reason:
          'targetLanguage is the pinned Japanese reading/dictionary language, '
          'not the app chrome locale',
    );
  });
}

/// Returns the substring of [source] from the first [start] marker up to the
/// next [end] marker — the same pattern the reader static guards use.
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
