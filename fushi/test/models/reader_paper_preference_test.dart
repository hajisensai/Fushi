// 拍板台 vJSj4RsKFt：阅读器纸色（羊皮纸 / 护眼 / 深灰等）可直接选，与 app 主题
// 种子色无关；默认跟随 app 主题，显式选择覆盖；存量 app_theme_key 里的旧纸色 id
// 照旧生效。
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderThemeColors, kReaderPaperPresets, resolveReaderThemeColors;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late ThemeNotifier notifier;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    notifier = ThemeNotifier(db, () => const TextTheme());
    await notifier.refreshFromDb();
  });

  tearDown(() async {
    notifier.dispose();
    await db.close();
  });

  ReaderThemeColors resolved() => resolveReaderThemeColors(
    themeKey: notifier.readerThemeKey,
    presetMap: kReaderPaperPresets,
    scheme: notifier.buildColorScheme(
      notifier.isDarkMode ? Brightness.dark : Brightness.light,
    ),
  );

  test('selectable paper ids match the render-layer presets by brightness', () {
    for (final String key in ThemeNotifier.readerLightPaperKeys) {
      expect(kReaderPaperPresets[key]?.dark, isFalse, reason: key);
    }
    for (final String key in ThemeNotifier.readerDarkPaperKeys) {
      expect(kReaderPaperPresets[key]?.dark, isTrue, reason: key);
    }
    expect(<String>{
      ...ThemeNotifier.readerLightPaperKeys,
      ...ThemeNotifier.readerDarkPaperKeys,
    }, kReaderPaperPresets.keys.toSet());
  });

  test('default follows the app theme key', () async {
    await notifier.setBrightnessMode('light');
    await notifier.setAppThemeKey('m3-teal');
    expect(notifier.readerPaperFor(dark: false), isNull);
    expect(notifier.readerPaperFor(dark: true), isNull);
    expect(notifier.readerThemeKey, 'm3-teal');
  });

  test(
    'explicit light paper overrides the app theme in light mode only',
    () async {
      await notifier.setAppThemeKey('m3-teal');
      await notifier.setBrightnessMode('light');
      await notifier.setReaderPaper(dark: false, key: 'ecru-theme');

      expect(notifier.readerThemeKey, 'ecru-theme');
      expect(resolved().bg, kReaderPaperPresets['ecru-theme']!.bg);

      // 深色下这份浅纸不生效，深色那份没选 → 跟随 app 主题。
      await notifier.setBrightnessMode('dark');
      expect(notifier.readerThemeKey, 'm3-teal');
      expect(resolved().dark, isTrue);

      await notifier.setReaderPaper(dark: true, key: 'gray-theme');
      expect(notifier.readerThemeKey, 'gray-theme');
      expect(resolved().bg, kReaderPaperPresets['gray-theme']!.bg);

      // 跟随 = 清掉显式选择。
      await notifier.setReaderPaper(dark: true);
      expect(notifier.readerPaperFor(dark: true), isNull);
      expect(notifier.readerThemeKey, 'm3-teal');
    },
  );

  test(
    'explicit paper survives a restart and changing the app theme',
    () async {
      await notifier.setBrightnessMode('light');
      await notifier.setReaderPaper(dark: false, key: 'eyecare-theme');
      await notifier.setAppThemeKey('m3-blue');
      await notifier.refreshFromDb();
      expect(notifier.readerThemeKey, 'eyecare-theme');
    },
  );

  test(
    'stored legacy app theme paper ids keep working when following',
    () async {
      await db.setPrefs(<String, String>{
        'app_theme_key': PrefCodec.encode('ecru-theme'),
        'brightness_mode': PrefCodec.encode('light'),
      });
      await notifier.refreshFromDb();
      expect(notifier.readerThemeKey, 'ecru-theme');
      expect(resolved().bg, kReaderPaperPresets['ecru-theme']!.bg);
    },
  );

  test('a paper id from the other brightness is rejected', () async {
    await expectLater(
      notifier.setReaderPaper(dark: false, key: 'gray-theme'),
      throwsArgumentError,
    );
    await expectLater(
      notifier.setReaderPaper(dark: true, key: 'ecru-theme'),
      throwsArgumentError,
    );
  });

  test('an unknown stored value reads as follow', () async {
    await db.setPrefs(<String, String>{
      ThemeNotifier.readerPaperLightPrefKey: PrefCodec.encode('dark-theme'),
    });
    await notifier.refreshFromDb();
    expect(notifier.readerPaperFor(dark: false), isNull);
  });
}
