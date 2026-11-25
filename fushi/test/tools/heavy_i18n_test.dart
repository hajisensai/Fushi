import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/heavy_i18n.dart';

/// tool/heavy.dart 在本机跑编 app 的命令前重新生成不入库的 strings.g.dart：
/// checkout / merge 会删掉或让它过期，漏判一条命令就是成片「找不到 strings.g.dart」。
void main() {
  group('heavyCommandNeedsI18n', () {
    bool needs(List<String> cmd, String cwd, {bool win = true}) =>
        heavyCommandNeedsI18n(
          cmd,
          cwd: cwd,
          checkout: win ? r'D:\wt' : '/wt',
          isWindows: win,
        );

    test('fushi/ 下编 app 的 flutter / dart / gradle 命令要生成', () {
      const String fl = r'D:\sdk\bin\flutter.bat';
      const String dt = r'D:\sdk\bin\dart.bat';
      expect(needs(<String>[fl, 'test', 'a_test.dart'], r'D:\wt\fushi'), true);
      expect(needs(<String>[fl, 'analyze', '--no-pub'], r'D:\WT\Fushi'), true);
      expect(
        needs(<String>[fl, '-v', 'build', 'windows'], r'D:\wt\fushi'),
        true,
      );
      expect(needs(<String>[dt, 'analyze', 'lib'], r'D:\wt\fushi'), true);
      expect(needs(<String>[dt, 'run', 'tool/x.dart'], r'D:\wt\fushi'), true);
      expect(
        needs(<String>[dt, 'tool/flutter_test_failures.dart'], r'D:\wt\fushi'),
        true,
      );
      expect(
        needs(<String>[
          r'.\gradlew.bat',
          ':app:assembleRelease',
        ], r'D:\wt\fushi\android'),
        true,
      );
      expect(
        needs(<String>['/sdk/bin/flutter', 'test'], '/wt/fushi', win: false),
        true,
      );
    });

    test('pub / format / 生成器本身 / fushi/ 以外的目录不生成', () {
      const String fl = r'D:\sdk\bin\flutter.bat';
      const String dt = r'D:\sdk\bin\dart.bat';
      expect(needs(<String>[fl, 'pub', 'get'], r'D:\wt\fushi'), false);
      expect(needs(<String>[fl, '--version'], r'D:\wt\fushi'), false);
      expect(needs(<String>[dt, 'format', 'lib'], r'D:\wt\fushi'), false);
      expect(needs(<String>[dt, 'tool/gen_i18n.dart'], r'D:\wt\fushi'), false);
      expect(
        needs(<String>[fl, 'test'], r'D:\wt\packages\fushi_srs'),
        false,
        reason: 'packages/ 不依赖 package:fushi',
      );
      expect(needs(<String>[fl, 'test'], r'D:\wt\fushi_other'), false);
      expect(needs(<String>[fl, 'test'], r'D:\wt'), false);
      expect(needs(<String>['powershell', 'x.ps1'], r'D:\wt\fushi'), false);
      expect(
        needs(<String>[
          'powershell',
          '-File',
          r'tool\run_windows_itest.ps1',
        ], r'D:\wt\fushi'),
        true,
      );
      expect(
        needs(<String>['pwsh', 'tool/run_windows_itest.ps1'], r'D:\wt\fushi'),
        true,
      );
      expect(needs(<String>[fl, 'test'], '/wt/Fushi', win: false), false);
    });
  });

  group('heavyCommandAnalyzesApp', () {
    bool analyzes(List<String> cmd, String cwd, {bool win = true}) =>
        heavyCommandAnalyzesApp(
          cmd,
          cwd: cwd,
          checkout: win ? r'D:\wt' : '/wt',
          isWindows: win,
        );

    test('fushi/ 下的 flutter / dart analyze 要先编着色器包', () {
      const String fl = r'D:\sdk\bin\flutter.bat';
      const String dt = r'D:\sdk\bin\dart.bat';
      expect(
        analyzes(<String>[fl, 'analyze', '--no-pub'], r'D:\WT\Fushi'),
        true,
      );
      expect(
        analyzes(<String>[dt, 'analyze', 'lib'], r'D:\wt\fushi\lib'),
        true,
      );
      expect(
        analyzes(
          <String>['/sdk/bin/flutter', 'analyze'],
          '/wt/fushi',
          win: false,
        ),
        true,
      );
    });

    test('test / build / fushi/ 以外的 analyze 不编（构建钩子自己会编或不需要）', () {
      const String fl = r'D:\sdk\bin\flutter.bat';
      expect(analyzes(<String>[fl, 'test'], r'D:\wt\fushi'), false);
      expect(analyzes(<String>[fl, 'build', 'windows'], r'D:\wt\fushi'), false);
      expect(
        analyzes(<String>[fl, 'analyze'], r'D:\wt\packages\fushi_srs'),
        false,
      );
      expect(
        analyzes(<String>[r'.\gradlew.bat', 'analyze'], r'D:\wt\fushi'),
        false,
      );
      expect(analyzes(<String>[], r'D:\wt\fushi'), false);
    });
  });

  group('heavyI18nDart', () {
    test('取命令自己那份 SDK 的 dart（stamp 认 Dart 版本，format 决定字节）', () {
      expect(
        heavyI18nDart(
          <String>[r'D:\sdk\bin\flutter.bat', 'test'],
          checkout: 'D:/wt',
          fallback: 'X',
          isWindows: true,
          fileExists: (String p) =>
              p == 'D:/sdk/bin/cache/dart-sdk/bin/dart.exe',
          read: (_) => null,
        ),
        'D:/sdk/bin/cache/dart-sdk/bin/dart.exe',
      );
      // 命令已是 dart-sdk 里的 dart。
      expect(
        heavyI18nDart(
          <String>['/sdk/bin/cache/dart-sdk/bin/dart', 'analyze'],
          checkout: '/wt',
          fallback: 'X',
          isWindows: false,
          fileExists: (String p) => p == '/sdk/bin/cache/dart-sdk/bin/dart',
          read: (_) => null,
        ),
        '/sdk/bin/cache/dart-sdk/bin/dart',
      );
    });

    test('gradlew 等非 SDK 命令：用 pub get 记下的 flutterRoot，再退回 fallback', () {
      const String cfg =
          '{"configVersion":2,"packages":[],'
          '"flutterRoot":"file:///D:/flutter%20sdk/f","flutterVersion":"3.47.6"}';
      expect(
        heavyI18nDart(
          <String>[r'.\gradlew.bat', 'assembleRelease'],
          checkout: 'D:/wt',
          fallback: 'X',
          isWindows: true,
          fileExists: (String p) =>
              p == 'D:/flutter sdk/f/bin/cache/dart-sdk/bin/dart.exe',
          read: (String p) =>
              p == 'D:/wt/.dart_tool/package_config.json' ? cfg : null,
        ),
        'D:/flutter sdk/f/bin/cache/dart-sdk/bin/dart.exe',
      );
      expect(
        heavyI18nDart(
          <String>['gradlew'],
          checkout: '/wt',
          fallback: '/running/dart',
          isWindows: false,
          fileExists: (_) => false,
          read: (_) => null,
        ),
        '/running/dart',
      );
    });
  });

  group('heavyCommandIsAppGradle', () {
    bool gradle(List<String> cmd, String cwd, {bool win = true}) =>
        heavyCommandIsAppGradle(
          cmd,
          cwd: cwd,
          checkout: win ? r'D:\wt' : '/wt',
          isWindows: win,
        );

    test('fushi/android 下的 gradlew 要先刷新插件注册（release 编不过 debug 那份）', () {
      expect(
        gradle(<String>[
          r'.\gradlew.bat',
          ':app:assembleRelease',
        ], r'D:\WT\fushi\android'),
        true,
      );
      expect(
        gradle(
          <String>['./gradlew', ':app:testDebugUnitTest'],
          '/wt/fushi/android',
          win: false,
        ),
        true,
      );
    });

    test('flutter / dart 命令、fushi/android 以外的 gradlew 不刷新', () {
      expect(
        gradle(<String>[
          r'D:\sdk\bin\flutter.bat',
          'build',
          'apk',
        ], r'D:\wt\fushi'),
        false,
      );
      expect(
        gradle(<String>[r'.\gradlew.bat', 'build'], r'D:\other\android'),
        false,
      );
      expect(
        gradle(<String>[r'.\gradlew.bat', 'build'], r'D:\wt\fushi'),
        false,
      );
      expect(gradle(const <String>[], r'D:\wt\fushi\android'), false);
    });
  });

  group('heavyGradleConfigFlutter', () {
    test('取 pub get 记下的 SDK 的 flutter，没有就退回 PATH 上的', () {
      const String cfg =
          '{"configVersion":2,"packages":[],'
          '"flutterRoot":"file:///D:/flutter%20sdk/f","flutterVersion":"3.47.6"}';
      expect(
        heavyGradleConfigFlutter(
          checkout: 'D:/wt',
          isWindows: true,
          fileExists: (String p) => p == 'D:/flutter sdk/f/bin/flutter.bat',
          read: (String p) =>
              p == 'D:/wt/.dart_tool/package_config.json' ? cfg : null,
        ),
        'D:/flutter sdk/f/bin/flutter.bat',
      );
      expect(
        heavyGradleConfigFlutter(
          checkout: '/wt',
          isWindows: false,
          fileExists: (_) => false,
          read: (_) => null,
        ),
        'flutter',
      );
    });
  });

  test(
    'heavy.dart 本机跑 gradlew 前先 flutter build apk --config-only，失败即失败（lease 之前）',
    () {
      final String heavy = File('tool/heavy.dart').readAsStringSync();
      final int gen = heavy.indexOf('heavyCommandNeedsI18n(');
      final int config = heavy.indexOf('heavyCommandIsAppGradle(');
      final int lease = heavy.indexOf('admitted = await acquireHeavyLease(');
      expect(config, allOf(greaterThan(gen), lessThan(lease)));
      expect(heavy, contains("<String>['build', 'apk', '--config-only']"));
      expect(heavy, contains('exit(config);'));
    },
  );

  test('heavy.dart 在本机运行前（offload 之后、lease 之前）接了生成，失败即失败', () {
    final String heavy = File('tool/heavy.dart').readAsStringSync();
    // 外包先问一次别的机器（它们接走就直接以其退出码结束）；没接走才在本机生成、再排本机的租约。
    final int offload = heavy.indexOf('await _askElsewhere(');
    final int gen = heavy.indexOf('heavyCommandNeedsI18n(');
    final int lease = heavy.indexOf('admitted = await acquireHeavyLease(');
    expect(offload, greaterThan(0));
    expect(
      heavy.indexOf('case HeavyOffloadNext.done:'),
      allOf(greaterThan(offload), lessThan(gen)),
    );
    expect(gen, greaterThan(offload));
    expect(lease, greaterThan(gen));
    expect(heavy, contains('exit(gen);'));
  });
}
