// TODO-960: 桌面切换 UI 语言不得重启进程（重启与 Windows 单实例互斥量竞态会
// 把 app 关掉且不重启）。改为热重建：LocaleSettings.setLocaleRaw + notifyListeners，
// 并由 main.dart 顶层一个随 locale 变化的 Key 强制整树重挂（让全局 Method A `t`
// 读取者也重算文案）。
//
// 覆盖两块：
//   1) 行为测试（在桌面测试运行时验证桌面分支）：setAppLocale 在桌面下绝不调
//      lifecycle.restartApp，且 notifyListeners 被触发、pref 已写入、LocaleSettings
//      已切换。
//   2) 源码守卫：setAppLocale 桌面分支存在且不重启；移动端仍走 restart 分支；
//      main.dart 顶层有随 locale 变化的 Key 兜底；data-root 迁移仍各自 restart。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/fake_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  group('setAppLocale behaviour (TODO-960)', () {
    late Directory pathProviderDir;
    setUpAll(() {
      // AppModel 的 DefaultCacheManager 在构造时经 path_provider 打开缓存目录。
      pathProviderDir =
          Directory.systemTemp.createTempSync('hibiki_path_provider_locale');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => pathProviderDir.path,
      );
    });
    tearDownAll(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (pathProviderDir.existsSync()) {
        pathProviderDir.deleteSync(recursive: true);
      }
    });

    late HibikiDatabase db;
    late PreferencesRepository prefs;
    late FakeLifecycleService lifecycle;
    late AppModel appModel;

    setUp(() async {
      db = HibikiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      // 即便 supportsRestart=true，桌面分支也必须先行短路、绝不调用 restartApp。
      lifecycle = FakeLifecycleService()..supportsRestartValue = true;
      appModel = AppModel(fakePlatformServices(lifecycle: lifecycle));
      appModel.wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: Directory.systemTemp.createTempSync('todo960'),
      );
      LocaleSettings.setLocaleRaw('en');
    });

    tearDown(() async {
      prefs.dispose();
      await db.close();
    });

    test(
        'desktop: switching language never restarts the process and notifies '
        'listeners', () async {
      // 该断言只在桌面测试运行时（Windows/Linux/macOS host）验证桌面分支。
      // 移动端分支由下方源码守卫覆盖。
      if (!isDesktopPlatform) {
        return;
      }
      int notifyCount = 0;
      appModel.addListener(() => notifyCount++);

      await appModel.setAppLocale('ja');

      expect(lifecycle.restartCalled, isFalse,
          reason: 'desktop locale switch must NOT restart (mutex race kills '
              'the app); it must hot-reload instead');
      expect(notifyCount, greaterThanOrEqualTo(1),
          reason: 'a hot locale switch must notify listeners so the watching '
              'root widget rebuilds');
      expect(prefs.getPref('app_locale'), 'ja',
          reason: 'the new locale must be persisted');
      expect(LocaleSettings.currentLocale.languageCode, 'ja',
          reason: 'LocaleSettings must reflect the new display language');
    });
  });

  group('setAppLocale + root remount source guards (TODO-960)', () {
    String readSource(String rel) {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: 'missing source file: $rel');
      return f.readAsStringSync();
    }

    test('setAppLocale short-circuits to a no-restart hot path on desktop', () {
      final String src = readSource('lib/src/models/app_model.dart');
      final int start = src.indexOf('Future<void> setAppLocale(');
      expect(start, isNonNegative, reason: 'setAppLocale must exist');
      final int end = src.indexOf('\n  }', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);

      // Persist + switch the in-process locale, unconditionally.
      expect(body.contains("_setPref('app_locale', localeTag)"), isTrue);
      expect(body.contains('LocaleSettings.setLocaleRaw(localeTag)'), isTrue);
      // Desktop branch: hot-reload (notifyListeners) and return BEFORE the
      // restart branch is ever considered.
      expect(body.contains('if (isDesktopPlatform)'), isTrue,
          reason: 'desktop must take a dedicated no-restart branch');
      final int desktopBranch = body.indexOf('if (isDesktopPlatform)');
      final int restartCall =
          body.indexOf('platformServices.lifecycle.restartApp()');
      expect(restartCall, greaterThan(desktopBranch),
          reason: 'the desktop branch must precede (and short-circuit) the '
              'restart call so desktop never restarts');
      // Mobile keeps the native restart path.
      expect(body.contains('platformServices.lifecycle.restartApp()'), isTrue,
          reason: 'mobile (Android/iOS) still restarts via the plugin');
    });

    test('main.dart remounts the app subtree on a locale change', () {
      final String src = readSource('lib/main.dart');
      // A locale-keyed Key on the root TranslationProvider forces a full
      // remount when the display language changes, so global Method A `t`
      // readers re-resolve their strings (they do not rebuild on a bare
      // LocaleSettings change).
      expect(
        src.contains(
            "ValueKey<String>('app-locale-\${locale.toLanguageTag()}')"),
        isTrue,
        reason: 'the root app must be keyed by the current locale to remount '
            'on a hot language switch',
      );
    });
  });
}
