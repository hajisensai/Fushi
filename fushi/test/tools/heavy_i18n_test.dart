import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

  test('heavy.dart 在本机运行前（offload 之后、lease 之前）接了生成，失败即失败', () {
    final String heavy = File('tool/heavy.dart').readAsStringSync();
    final int offload = heavy.indexOf('if (remote != null) exit(remote);');
    final int gen = heavy.indexOf('heavyCommandNeedsI18n(');
    final int lease = heavy.indexOf('lease = await acquireHeavyLease(');
    expect(offload, greaterThan(0));
    expect(gen, greaterThan(offload));
    expect(lease, greaterThan(gen));
    expect(heavy, contains('exit(gen);'));
  });
}
