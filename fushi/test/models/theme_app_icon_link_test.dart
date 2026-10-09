import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/accent_logo_image.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';

/// 「主题色跟随图标」与「图标跟随主题色」两个开关的 ThemeNotifier 行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory scratch;
  late FushiDatabase database;
  late ThemeNotifier notifier;
  late Map<String, int> seedsByPath;
  late List<String> extracted;
  final Future<int?> Function(String) originalExtractor =
      ThemeNotifier.appIconSeedExtractor;

  File writeIcon(String name, List<int> bytes) =>
      File('${scratch.path}/$name')..writeAsBytesSync(bytes);

  ThemeNotifier build(Map<String, String> prefs) =>
      ThemeNotifier(database, () => const TextTheme())
        ..loadFromPrefsSnapshot(<String, String>{
          'design_system': PrefCodec.encode('material'),
          'app_theme_key': PrefCodec.encode('m3-baseline'),
          'brightness_mode': PrefCodec.encode('light'),
          ...prefs,
        });

  Color primary() => notifier.buildColorScheme(Brightness.light).primary;

  double hueOf(Color c) => Hct.fromInt(c.toARGB32()).hue;

  double hueDistance(double a, double b) {
    final double d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('fushi-icon-accent-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    seedsByPath = <String, int>{};
    extracted = <String>[];
    ThemeNotifier.appIconSeedExtractor = (String path) async {
      extracted.add(path);
      return seedsByPath[path];
    };
    currentAppIconSelection.value = const AppIconSelection(
      presetKey: 'default',
    );
    appLogoFollowsAccent.value = false;
  });

  tearDown(() async {
    notifier.dispose();
    ThemeNotifier.appIconSeedExtractor = originalExtractor;
    currentAppIconSelection.value = const AppIconSelection(
      presetKey: 'default',
    );
    appLogoFollowsAccent.value = false;
    await database.close();
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  group('主题色跟随图标', () {
    test('默认关：有自定义图标也不取色、不改主题', () async {
      final File icon = writeIcon('a.png', <int>[1, 2, 3]);
      seedsByPath[icon.path] = 0xFF2E7D32;
      currentAppIconSelection.value = AppIconSelection(
        presetKey: customIconKey,
        customPath: icon.path,
      );
      notifier = build(const <String, String>{});
      final Color baseline = primary();
      await notifier.refreshAppIconSeed();
      expect(notifier.followAppIconAccent, isFalse);
      expect(notifier.appIconAccentSeed, isNull);
      expect(extracted, isEmpty);
      expect(primary(), baseline);
    });

    test('开 → 主题色取自图标；关 → 恢复原主题，主题偏好从未被改写', () async {
      final File icon = writeIcon('a.png', <int>[1, 2, 3]);
      seedsByPath[icon.path] = 0xFF2E7D32; // 绿
      currentAppIconSelection.value = AppIconSelection(
        presetKey: customIconKey,
        customPath: icon.path,
      );
      notifier = build(const <String, String>{});
      final Color baseline = primary();

      await notifier.setFollowAppIconAccent(true);
      expect(notifier.appIconAccentSeed, const Color(0xFF2E7D32));
      expect(
        hueDistance(hueOf(primary()), hueOf(const Color(0xFF2E7D32))),
        lessThan(10),
      );
      expect(notifier.activeSeedColor, const Color(0xFF2E7D32));
      expect(notifier.appThemeKey, 'm3-baseline');

      await notifier.setFollowAppIconAccent(false);
      expect(notifier.appIconAccentSeed, isNull);
      expect(primary(), baseline);
      expect(notifier.appThemeKey, 'm3-baseline');
    });

    test('开着时换自定义图标：即时重取色', () async {
      final File first = writeIcon('a.png', <int>[1, 2, 3]);
      final File second = writeIcon('b.png', <int>[4, 5, 6, 7]);
      seedsByPath[first.path] = 0xFF2E7D32; // 绿
      seedsByPath[second.path] = 0xFFC62828; // 红
      currentAppIconSelection.value = AppIconSelection(
        presetKey: customIconKey,
        customPath: first.path,
      );
      notifier = build(const <String, String>{});
      await notifier.setFollowAppIconAccent(true);
      expect(notifier.appIconAccentSeed, const Color(0xFF2E7D32));

      int notified = 0;
      notifier.addListener(() => notified++);
      currentAppIconSelection.value = AppIconSelection(
        presetKey: customIconKey,
        customPath: second.path,
        revision: 1,
      );
      await notifier.refreshAppIconSeed();
      expect(notifier.appIconAccentSeed, const Color(0xFFC62828));
      expect(
        hueDistance(hueOf(primary()), hueOf(const Color(0xFFC62828))),
        lessThan(15),
      );
      expect(notified, greaterThan(0));
      expect(extracted, contains(second.path));
    });

    test('开着时换回预设图标：回到原主题（开关保持开）', () async {
      final File icon = writeIcon('a.png', <int>[1, 2, 3]);
      seedsByPath[icon.path] = 0xFF2E7D32;
      currentAppIconSelection.value = AppIconSelection(
        presetKey: customIconKey,
        customPath: icon.path,
      );
      notifier = build(const <String, String>{});
      final Color baseline = primary();
      await notifier.setFollowAppIconAccent(true);
      expect(primary(), isNot(baseline));

      currentAppIconSelection.value = const AppIconSelection(
        presetKey: 'default',
        revision: 1,
      );
      await notifier.refreshAppIconSeed();
      expect(notifier.followAppIconAccent, isTrue);
      expect(notifier.appIconAccentSeed, isNull);
      expect(primary(), baseline);
    });

    test('取色结果按文件修改时间缓存：同一张图重启后不重取、首帧即用缓存色', () async {
      final File icon = writeIcon('a.png', <int>[1, 2, 3]);
      seedsByPath[icon.path] = 0xFF2E7D32;
      currentAppIconSelection.value = AppIconSelection(
        presetKey: customIconKey,
        customPath: icon.path,
      );
      notifier = build(const <String, String>{});
      await notifier.setFollowAppIconAccent(true);
      expect(extracted, hasLength(1));
      final Map<String, String> persisted = await database.getAllPrefs();
      notifier.dispose();

      // 模拟冷启动：偏好快照里已有开关与缓存。
      notifier = build(persisted);
      // 同步：加载快照当下就已经用上缓存色（不闪原主题）。
      expect(notifier.appIconAccentSeed, const Color(0xFF2E7D32));
      await notifier.refreshAppIconSeed();
      expect(extracted, hasLength(1), reason: '文件没变，不重取');
    });

    test('墨水屏优先：开着也不覆盖黑白配色', () async {
      final File icon = writeIcon('a.png', <int>[1, 2, 3]);
      seedsByPath[icon.path] = 0xFFC62828;
      currentAppIconSelection.value = AppIconSelection(
        presetKey: customIconKey,
        customPath: icon.path,
      );
      notifier = build(<String, String>{'eink_mode': PrefCodec.encode(true)});
      await notifier.setFollowAppIconAccent(true);
      final Color p = primary();
      expect(Hct.fromInt(p.toARGB32()).chroma, lessThan(5));
    });
  });

  group('图标跟随主题色（logo 换色开关）', () {
    test('默认关，加载偏好时发布到全局开关', () {
      appLogoFollowsAccent.value = true; // 上一会话残留值必须被偏好覆盖
      notifier = build(const <String, String>{});
      expect(notifier.tintAppLogo, isFalse);
      expect(appLogoFollowsAccent.value, isFalse);
    });

    test('打开后持久化并即时发布；偏好里是开的则加载即开', () async {
      notifier = build(const <String, String>{});
      await notifier.setTintAppLogo(true);
      expect(appLogoFollowsAccent.value, isTrue);
      final Map<String, String> persisted = await database.getAllPrefs();
      expect(
        persisted[ThemeNotifier.tintAppLogoPrefKey],
        PrefCodec.encode(true),
      );
      notifier.dispose();
      appLogoFollowsAccent.value = false;
      notifier = build(persisted);
      expect(appLogoFollowsAccent.value, isTrue);
    });
  });
}
