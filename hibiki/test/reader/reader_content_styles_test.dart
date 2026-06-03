import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';

Future<ReaderSettings> _defaultSettings() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  return settings;
}

void main() {
  group('ReaderContentStyles.styleTag', () {
    test('wraps css in style tag', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String tag = ReaderContentStyles.styleTag(settings: settings);
      expect(tag, startsWith('<style>'));
      expect(tag, endsWith('</style>'));
    });
  });

  group('ReaderContentStyles.css with default settings', () {
    late String css;

    setUp(() async {
      final ReaderSettings settings = await _defaultSettings();
      css = ReaderContentStyles.css(settings: settings);
    });

    test('contains body selector', () {
      expect(css, contains('body'));
    });

    test('sets writing-mode to vertical-rl by default', () {
      expect(css, contains('vertical-rl'));
    });

    test('sets font-size from default (22)', () {
      expect(css, contains('22px'));
    });

    test('sets line-height from default (1.65)', () {
      expect(css, contains('1.65'));
    });

    test('contains image sizing constraints', () {
      expect(css, contains('img'));
    });

    test('contains furigana rt rule', () {
      expect(css, contains('rt'));
    });

    test('contains light theme background by default', () {
      expect(css, contains('#fff'));
    });
  });

  group('ReaderContentStyles.css theme overrides', () {
    test('dark-theme sets dark background', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'dark-theme',
      );
      expect(css, contains('#121212'));
    });

    test('ecru-theme sets ecru background', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'ecru-theme',
      );
      expect(css, contains('#f7f6eb'));
    });

    test('black-theme sets pure black background', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'black-theme',
      );
      expect(css, contains('#000'));
    });

    test('custom-theme uses custom colors', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'custom-theme',
        customBg: '#FF0000',
        customFg: '#00FF00',
      );
      expect(css, contains('#FF0000'));
      expect(css, contains('#00FF00'));
    });
  });

  group('ReaderContentStyles.css with custom settings', () {
    test('horizontal writing mode produces horizontal-tb', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('horizontal-tb'));
      expect(css, isNot(contains('text-orientation')));
    });

    test('continuous mode produces different layout', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('overflow'));
    });

    test('custom font faces are injected', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        fontFaces: '@font-face { font-family: "TestFont"; }',
        fontFamily: '"TestFont"',
      );
      expect(css, contains('@font-face'));
      expect(css, contains('TestFont'));
    });

    test('selection color override appears in css', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        selectionColor: 'rgba(255,0,0,0.5)',
      );
      expect(css, contains('rgba(255,0,0,0.5)'));
    });
  });

  group('ReaderContentStyles furigana modes', () {
    test('default mode shows furigana', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      // Default furigana mode is 'show' → rt { font-size: 0.45em; }
      expect(css, contains('rt'));
      expect(css, contains('0.45em'));
    });

    test('hide furigana mode via themeOverride still renders rt rule',
        () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setFuriganaMode('hide');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('rt'));
      expect(css, contains('display: none'));
    });
  });

  group('ReaderLayoutDefaults', () {
    test('constants are consistent', () {
      expect(ReaderLayoutDefaults.fontSizePx, 22);
      expect(ReaderLayoutDefaults.bottomOverlapPx,
          ReaderLayoutDefaults.fontSizePx);
      expect(ReaderLayoutDefaults.imageWidthViewportRatio, 0.95);
    });
  });

  group('ReaderContentStyles chrome inset CSS variables', () {
    test('paginated layout contains --chrome-top-inset in padding-top',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      // Default is paginated mode
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('--chrome-top-inset'));
      expect(css, contains('padding-top:'));
    });

    test('paginated layout contains --chrome-bottom-inset in padding-bottom',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('--chrome-bottom-inset'));
      expect(css, contains('padding-bottom:'));
    });

    test('paginated layout padding-top uses calc with vh and var fallback 0px',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'padding-top: calc(${settings.marginTop}vh + var(--chrome-top-inset, 0px))'));
    });

    test(
        'paginated layout padding-bottom uses calc with vh, fontSize, and var fallback 0px',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'padding-bottom: calc(${settings.marginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px))'));
    });

    test('continuous layout contains --chrome-top-inset in padding-top',
        () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('--chrome-top-inset'));
      expect(css, contains('padding-top:'));
    });

    test('continuous layout contains --chrome-bottom-inset in padding-bottom',
        () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('--chrome-bottom-inset'));
      expect(css, contains('padding-bottom:'));
    });

    test(
        'continuous layout padding-bottom includes fontSize and chrome-bottom-inset',
        () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'padding-bottom: calc(${settings.marginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px))'));
    });

    // Regression: in vertical writing mode the page-turn axis is scrollTop, so
    // the column-gap (the inter-page period) must reserve the chrome insets too.
    // Otherwise the column pitch (pageSize + gap) is shorter than the viewport
    // by (chromeTop + chromeBottom) and the previous page's tail bleeds into the
    // top notch strip of the current page.
    test('vertical paginated column-gap includes both chrome insets', () async {
      final ReaderSettings settings = await _defaultSettings();
      // Default writing-mode is vertical-rl.
      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'column-gap: calc(${settings.marginTop}vh + ${settings.marginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-top-inset, 0px) + var(--chrome-bottom-inset, 0px))'));
    });

    test('horizontal paginated column-gap excludes chrome insets', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'column-gap: calc(${settings.marginLeft}vw + ${settings.marginRight}vw + ${settings.fontSize.round()}px)'));
      // The horizontal page-turn axis is scrollLeft; chrome insets live in
      // padding-top/bottom (perpendicular), so they must not enter the gap.
      expect(
          css,
          isNot(contains(
              'column-gap: calc(${settings.marginLeft}vw + ${settings.marginRight}vw + ${settings.fontSize.round()}px + var(--chrome-top-inset')));
    });
  });

  group('ReaderContentStyles negative margin clamping', () {
    test('negative margins are clamped to 0 in padding CSS', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setMarginTop(-5);
      await settings.setMarginBottom(-3);
      await settings.setMarginLeft(-2);
      await settings.setMarginRight(-4);

      final String css = ReaderContentStyles.css(settings: settings);
      // Negative values must not appear in padding declarations
      expect(css, isNot(contains('padding: -')));
      expect(css, isNot(contains('padding-top: calc(-')));
      expect(css, isNot(contains('padding-bottom: calc(-')));
      // Column-gap must not go negative either (0vh + 0vh + fontSize for vertical)
      expect(css, contains('calc(0.0vh + 0.0vh'));
    });

    test('overflow-wrap: anywhere is present in body', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('overflow-wrap: anywhere'));
    });
  });

  group('ReaderHibikiSource live settings callbacks', () {
    test('style setting writes trigger the live callback', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      ReaderHibikiSource.readerSettings = settings;
      addTearDown(() => ReaderHibikiSource.readerSettings = null);

      int calls = 0;
      ReaderHibikiSource.onSettingsChangedLive = () => calls++;
      addTearDown(() => ReaderHibikiSource.onSettingsChangedLive = null);

      await ReaderHibikiSource.instance.setTtuFontSize(25);
      await ReaderHibikiSource.instance.setTtuPrioritizeReaderStyles(true);
      await ReaderHibikiSource.instance.addCustomFont(name: 'Test Font');

      expect(calls, 3);
    });
  });

  group('ReaderContentStyles vertical-only CSS probes (T1)', () {
    Future<ReaderSettings> verticalSettings() async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('vertical-rl');
      return settings;
    }

    Future<ReaderSettings> horizontalSettings() async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');
      return settings;
    }

    test('vertical upright orientation emits text-orientation: upright',
        () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setVerticalTextOrientation('upright');
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('text-orientation: upright;'));
      expect(css, isNot(contains('text-orientation: mixed;')));
    });

    test('vertical mixed orientation emits text-orientation: mixed', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setVerticalTextOrientation('mixed');
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('text-orientation: mixed;'));
      expect(css, isNot(contains('text-orientation: upright;')));
    });

    test('vertical kerning ON emits font-kerning: normal', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableVerticalFontKerning(true);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('font-kerning: normal !important;'));
    });

    test('vertical kerning OFF omits font-kerning declaration', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableVerticalFontKerning(false);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('font-kerning')));
    });

    test('vertical VPAL ON emits font-feature-settings vpal 1', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableFontVPAL(true);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains("font-feature-settings: 'vpal' 1 !important;"));
    });

    test('vertical VPAL OFF omits vpal feature setting', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableFontVPAL(false);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('vpal')));
    });

    test('horizontal-tb gates out all three even with every toggle ON',
        () async {
      final ReaderSettings settings = await horizontalSettings();
      await settings.setVerticalTextOrientation('upright');
      await settings.setEnableVerticalFontKerning(true);
      await settings.setEnableFontVPAL(true);

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('horizontal-tb'));
      expect(css, isNot(contains('text-orientation')));
      expect(css, isNot(contains('font-kerning')));
      expect(css, isNot(contains('vpal')));
    });
  });
}
