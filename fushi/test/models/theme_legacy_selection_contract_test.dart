// HBK-AUDIT-035 回归：换主题键前把旧主题键兜底读出的明暗 / 纯黑固化成独立偏好
// （ThemeNotifier._setAppThemeKeyKeepingEffective）。由 Codex 第六轮复现
// theme_legacy_selection_contract_repro.dart 迁来，另加「重启后仍成立」与「已显式存过的不改写」。
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/theme_notifier.dart';

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

  test(
    'legacy pure-black preference stays enabled when changing only seed',
    () async {
      await db.setPrefs(<String, String>{
        'app_theme_key': PrefCodec.encode('black-theme'),
        'brightness_mode': PrefCodec.encode('dark'),
      });
      await notifier.refreshFromDb();
      expect(notifier.pureBlackDark, isTrue);
      expect(notifier.buildColorScheme(Brightness.dark).surface, Colors.black);

      await notifier.setAppThemeKey('m3-teal');
      expect(notifier.brightnessMode, 'dark');
      expect(
        notifier.pureBlackDark,
        isTrue,
        reason:
            'Changing a seed must preserve the independent pure-black '
            'setting already shown as enabled for the migrated user.',
      );
      expect(notifier.buildColorScheme(Brightness.dark).surface, Colors.black);
    },
  );

  test(
    'legacy implicit dark mode survives selection of a new color preset',
    () async {
      await db.setPrefs(<String, String>{
        'app_theme_key': PrefCodec.encode('custom-theme'),
        'custom_theme_dark': PrefCodec.encode(true),
      });
      await notifier.refreshFromDb();
      expect(notifier.brightnessMode, 'dark');
      expect(notifier.isDarkMode, isTrue);

      await notifier.setAppThemeKey('m3-blue');
      expect(
        notifier.brightnessMode,
        'dark',
        reason:
            'The supported legacy fallback is the active brightness '
            'before selection; changing only the seed must keep it.',
      );
      expect(notifier.isDarkMode, isTrue);
    },
  );

  test(
    'control: explicit dark and pure-black choices survive seed changes',
    () async {
      await notifier.setBrightnessMode('dark');
      await notifier.setPureBlackDark(true);
      await notifier.setAppThemeKey('m3-teal');
      expect(notifier.brightnessMode, 'dark');
      expect(notifier.pureBlackDark, isTrue);
      expect(notifier.buildColorScheme(Brightness.dark).surface, Colors.black);
    },
  );

  test('补写的明暗 / 纯黑已落库：重新加载后仍成立', () async {
    await db.setPrefs(<String, String>{
      'app_theme_key': PrefCodec.encode('black-theme'),
      'brightness_mode': PrefCodec.encode('dark'),
    });
    await notifier.refreshFromDb();
    await notifier.setAppThemeKey('m3-teal');

    final ThemeNotifier reloaded = ThemeNotifier(db, () => const TextTheme());
    await reloaded.refreshFromDb();
    expect(reloaded.appThemeKey, 'm3-teal');
    expect(reloaded.brightnessMode, 'dark');
    expect(reloaded.pureBlackDark, isTrue);
    reloaded.dispose();
  });

  test('已显式存过的明暗 / 纯黑不被旧主题兜底改写', () async {
    await db.setPrefs(<String, String>{
      'app_theme_key': PrefCodec.encode('black-theme'),
      'brightness_mode': PrefCodec.encode('light'),
      'pure_black_dark': PrefCodec.encode(false),
    });
    await notifier.refreshFromDb();
    await notifier.setAppThemeKey('m3-blue');
    expect(notifier.brightnessMode, 'light');
    expect(notifier.pureBlackDark, isFalse);
  });
}
