import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/flutter_sdk_executables.dart';
import '../../tool/test_flow/heavy_sdk_check.dart';

void main() {
  FlutterSdkExecutables exe({
    Map<String, String> env = const <String, String>{},
    String running = 'D:/sdk/good/bin/cache/dart-sdk/bin/dart.exe',
    Set<String> files = const <String>{},
  }) => FlutterSdkExecutables(
    environment: env,
    resolvedExecutable: running,
    isWindows: false,
    fileExists: files.contains,
  );

  String? versions(String root) => switch (root) {
    'D:/sdk/good' => '3.47.6',
    'D:/sdk/old' => '3.44.0',
    _ => null,
  };

  group('flutterSdkRootOfLauncher', () {
    test('flutter / dart launchers under <root>/bin', () {
      expect(
        flutterSdkRootOfLauncher(r'D:\sdk\good\bin\flutter.bat'),
        'D:/sdk/good',
      );
      expect(flutterSdkRootOfLauncher('/opt/flutter/bin/dart'), '/opt/flutter');
    });

    test('anything else is not a launcher', () {
      expect(flutterSdkRootOfLauncher('flutter'), isNull);
      expect(flutterSdkRootOfLauncher('D:/x/gradlew.bat'), isNull);
      expect(flutterSdkRootOfLauncher('D:/sdk/flutter.bat'), isNull);
    });
  });

  group('checkHeavyCommandSdk', () {
    test('bare flutter resolves to the SDK running the tool and passes', () {
      final HeavySdkCheck r = checkHeavyCommandSdk(
        <String>['flutter', 'test', 'a_test.dart'],
        pinned: '3.47.6',
        executables: exe(files: <String>{'D:/sdk/good/bin/flutter'}),
        sdkVersionOf: versions,
      );
      expect(r.error, isNull);
      expect(r.command, <String>[
        'D:/sdk/good/bin/flutter',
        'test',
        'a_test.dart',
      ]);
    });

    test('a PATH SDK of another version is refused before it runs', () {
      final HeavySdkCheck r = checkHeavyCommandSdk(
        <String>['flutter', 'analyze', '--no-pub'],
        pinned: '3.47.6',
        executables: exe(running: 'D:/dart-only/bin/dart.exe'),
        sdkVersionOf: versions,
        pathLookup: (String n) => 'D:/sdk/old/bin/$n.bat',
      );
      expect(r.error, contains('3.44.0'));
      expect(r.error, contains('3.47.6'));
    });

    test('an explicit launcher path of another version is refused too', () {
      final HeavySdkCheck r = checkHeavyCommandSdk(
        <String>['D:/sdk/old/bin/dart', 'analyze'],
        pinned: '3.47.6',
        sdkVersionOf: versions,
      );
      expect(r.error, isNotNull);
      expect(r.command.first, 'D:/sdk/old/bin/dart');
    });

    test('non-SDK commands, unknown versions and no pin pass unchanged', () {
      for (final List<String> argv in <List<String>>[
        <String>['gradlew.bat', ':app:assembleRelease'],
        <String>['fvm', 'flutter', 'test'],
        <String>['D:/standalone/bin/dart', 'test'],
      ]) {
        final HeavySdkCheck r = checkHeavyCommandSdk(
          argv,
          pinned: '3.47.6',
          sdkVersionOf: versions,
        );
        expect(r.error, isNull, reason: '$argv');
        expect(r.command, argv);
      }
      expect(
        checkHeavyCommandSdk(
          <String>['D:/sdk/old/bin/flutter', 'test'],
          pinned: null,
          sdkVersionOf: versions,
        ).error,
        isNull,
      );
    });
  });
}
