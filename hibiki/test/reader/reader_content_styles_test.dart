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
  await settings.ready;
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
      await settings.ready;
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
      await settings.ready;
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
      await settings.ready;
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

  group('ReaderHibikiSource live settings callbacks', () {
    test('style setting writes trigger the live callback', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.ready;
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
}
