import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-049 wiring guard (source scan, sibling of reader_live_settings_guard).
///
/// The three font targets are independent ONLY if each renderer reads its own
/// source list. A future refactor that re-points one of them back at the shared
/// `customFonts`/body list would silently re-couple them (no compile error,
/// hard to catch at runtime across 5 platforms). These static assertions pin the
/// data source of each renderer so any such regression turns this test red.
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('app-wide UI font is resolved from the appUiFonts target', () {
    final String src = read('lib/src/models/app_model.dart');
    // Both the live refresh and the init path must feed appUiFonts to the loader.
    // refresh resolves appUi + videoSubtitle; init resolves appUi + videoSubtitle
    // => four AppFontLoader call sites total (TODO-864).
    expect(
      'AppFontLoader.resolveAndLoad('.allMatches(src).length,
      greaterThanOrEqualTo(4),
      reason: 'expected the four AppFontLoader call sites '
          '(refresh appUi+videoSub, init appUi+videoSub)',
    );
    expect(src.contains('resolveAndLoad(settings.appUiFonts)'), isTrue);
    expect(src.contains('resolveAndLoad(readerSettings.appUiFonts)'), isTrue);
    // It must NOT be fed the body list any more.
    expect(src.contains('resolveAndLoad(settings.customFonts)'), isFalse);
    expect(src.contains('resolveAndLoad(readerSettings.customFonts)'), isFalse);
  });

  test('video subtitle font is resolved from the videoSubtitleFonts target',
      () {
    final String src = read('lib/src/models/app_model.dart');
    // Both the live refresh and the init path must feed videoSubtitleFonts.
    expect(src.contains('resolveAndLoad(settings.videoSubtitleFonts)'), isTrue);
    expect(src.contains('resolveAndLoad(readerSettings.videoSubtitleFonts)'),
        isTrue);
    // app_model exposes the dedicated family getter.
    expect(src.contains('String? get subtitleFontFamily'), isTrue);
  });

  test('video subtitle overlay binds to subtitleFontFamily, not appFontFamily',
      () {
    final String src =
        read('lib/src/pages/implementations/video_hibiki/layout.part.dart');
    // The overlay font source must be the subtitle target (TODO-864); a future
    // refactor pointing it back at appFontFamily silently re-couples them.
    expect(src.contains('fontFamily: appModel.subtitleFontFamily'), isTrue);
    expect(src.contains('fontFamily: appModel.appFontFamily'), isFalse);
  });

  test('dictionary popup injects the dictionaryFonts target', () {
    // TODO-895 moved the dictionary-font injection out of the in-app WebView
    // file into the shared single source of truth popup_settings_injection.dart
    // (dictionaryFontStyleJs / buildPopupSettingsJs), which the in-app popup
    // (dictionary_popup_webview.dart) and the app-outside global-lookup window
    // both call. Pin the wiring at the source-of-truth builder so the
    // dictionaryFonts target stays wired.
    final String src =
        read('lib/src/pages/implementations/popup_settings_injection.dart');
    expect(src.contains('DictionaryFontCss.build('), isTrue);
    expect(src.contains('settings.dictionaryFonts'), isTrue);
    // The injected style element id is the contract popup.css/JS keys off.
    expect(src.contains("'hoshi-dict-font'"), isTrue);
    // The in-app WebView path must feed through the shared builder (not a
    // re-introduced local copy that could drift from the app-outside window).
    final String webview =
        read('lib/src/pages/implementations/dictionary_popup_webview.dart');
    expect(webview.contains('buildPopupSettingsJs('), isTrue);
  });

  test('structured dictionary page injects the dictionaryFonts target', () {
    final String src = read(
        'lib/src/pages/implementations/dictionary_structured_content_page.dart');
    expect(src.contains('DictionaryFontCss.build('), isTrue);
    expect(src.contains('settings.dictionaryFonts'), isTrue);
  });

  test('reader body CSS still uses the legacy body customFonts list', () {
    final String src = read('lib/src/reader/reader_content_styles.dart');
    expect(src.contains('settings.buildCustomFontCss()'), isTrue);
    final String settings = read('lib/src/reader/reader_settings.dart');
    // buildCustomFontCss must stay bound to the BODY target (legacy key).
    expect(
      settings.contains(
          'buildCustomFontCss() =>\n      customFontCssForEntries(customFonts)'),
      isTrue,
    );
  });

  test('settings exposes one font catalog entry with four row targets', () {
    final String schema =
        read('lib/src/settings/settings_schema_appearance.dart');
    expect(schema.contains("'appearance.font_catalog'"), isTrue);
    expect(schema.contains('t.custom_fonts_catalog_title'), isTrue);
    expect(schema.contains("'appearance.fonts_app_ui'"), isFalse);
    expect(schema.contains("'appearance.fonts_body'"), isFalse);
    expect(schema.contains("'appearance.fonts_dictionary'"), isFalse);

    final String page =
        read('lib/src/pages/implementations/custom_fonts_page.dart');
    expect(page.contains('for (final FontTarget target in FontTarget.values)'),
        isTrue);
    expect(page.contains('customFontCatalogRowsFromState'), isTrue);
    expect(page.contains('customFontCatalogStateFromRows'), isTrue);
    expect(page.contains('ReaderSettings.fontCatalogKey'), isTrue);
    expect(page.contains('ReaderSettings.fontTargetsKey'), isTrue);
    expect(page.contains('customFontLegacyListsFromRows'), isTrue);
  });

  test('the legacy body key is never renamed (backward-compat ironclad)', () {
    final String src = read('lib/src/reader/reader_settings.dart');
    expect(src.contains("fontKeyBody = 'custom_fonts'"), isTrue);
    expect(src.contains("fontKeyAppUi = 'app_ui_fonts'"), isTrue);
    expect(src.contains("fontKeyDictionary = 'dict_fonts'"), isTrue);
    // TODO-864: video subtitle font key is equally ironclad (backward-compat).
    expect(src.contains("fontKeyVideoSubtitle = 'video_sub_fonts'"), isTrue);
  });
}
