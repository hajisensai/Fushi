import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/flutter_sdk_executables.dart';

FlutterSdkExecutables _sdk({
  Map<String, String> env = const <String, String>{},
  String running = '',
  bool windows = true,
  Set<String> files = const <String>{},
}) => FlutterSdkExecutables(
  environment: env,
  resolvedExecutable: running,
  isWindows: windows,
  fileExists: files.contains,
);

const String _runningWin =
    r'D:\sdk\flutter_3.47.6\bin\cache\dart-sdk\bin\dart.exe';

void main() {
  group('FlutterSdkExecutables.flutter', () {
    test('FUSHI_FLUTTER wins when the file exists', () {
      final FlutterSdkExecutables sdk = _sdk(
        env: <String, String>{
          'FUSHI_FLUTTER': r'E:\pinned\bin\flutter.bat',
          'FLUTTER_ROOT': r'D:\root',
        },
        running: _runningWin,
        files: <String>{
          r'E:\pinned\bin\flutter.bat',
          r'D:\root\bin\flutter.bat',
          r'D:\sdk\flutter_3.47.6\bin\flutter.bat',
        },
      );
      expect(sdk.flutter(), r'E:\pinned\bin\flutter.bat');
    });

    test('FLUTTER_ROOT beats the running SDK', () {
      final FlutterSdkExecutables sdk = _sdk(
        env: <String, String>{'FLUTTER_ROOT': r'D:\root\'},
        running: _runningWin,
        files: <String>{
          r'D:\root\bin\flutter.bat',
          r'D:\sdk\flutter_3.47.6\bin\flutter.bat',
        },
      );
      expect(sdk.flutter(), r'D:\root\bin\flutter.bat');
    });

    test('stale variables fall through to the SDK running this tool', () {
      final FlutterSdkExecutables sdk = _sdk(
        env: <String, String>{
          'FUSHI_FLUTTER': r'E:\gone\bin\flutter.bat',
          'FLUTTER_ROOT': r'D:\gone',
        },
        running: _runningWin,
        files: <String>{r'D:\sdk\flutter_3.47.6\bin\flutter.bat'},
      );
      expect(sdk.flutter(), r'D:\sdk\flutter_3.47.6\bin\flutter.bat');
    });

    test('a standalone dart SDK is not mistaken for a Flutter SDK', () {
      final FlutterSdkExecutables sdk = _sdk(
        running: r'C:\tools\dart-sdk\bin\dart.exe',
        files: <String>{r'C:\tools\bin\flutter.bat'},
      );
      expect(sdk.flutter(), 'flutter');
    });

    test('nothing found falls back to a PATH lookup', () {
      expect(_sdk().flutter(), 'flutter');
    });

    test('POSIX uses the extensionless launcher and forward slashes', () {
      final FlutterSdkExecutables sdk = _sdk(
        windows: false,
        running: '/opt/flutter/bin/cache/dart-sdk/bin/dart',
        files: <String>{'/opt/flutter/bin/flutter'},
      );
      expect(sdk.flutter(), '/opt/flutter/bin/flutter');
    });
  });

  group('FlutterSdkExecutables.dart', () {
    test('comes from the same SDK as flutter', () {
      final FlutterSdkExecutables sdk = _sdk(
        env: <String, String>{'FUSHI_FLUTTER': r'E:\pinned\bin\flutter.bat'},
        running: _runningWin,
        files: <String>{
          r'E:\pinned\bin\flutter.bat',
          r'E:\pinned\bin\dart.bat',
          r'D:\sdk\flutter_3.47.6\bin\dart.bat',
        },
      );
      expect(sdk.dart(), r'E:\pinned\bin\dart.bat');
    });

    test('falls back to the running dart, then PATH', () {
      expect(
        _sdk(
          running: r'C:\tools\dart-sdk\bin\dart.exe',
          files: <String>{r'C:\tools\dart-sdk\bin\dart.exe'},
        ).dart(),
        r'C:\tools\dart-sdk\bin\dart.exe',
      );
      expect(_sdk().dart(), 'dart');
    });
  });

  test('resolveCommand only rewrites flutter and dart', () {
    final FlutterSdkExecutables sdk = _sdk(
      running: _runningWin,
      files: <String>{
        r'D:\sdk\flutter_3.47.6\bin\flutter.bat',
        r'D:\sdk\flutter_3.47.6\bin\dart.bat',
      },
    );
    expect(
      sdk.resolveCommand('flutter'),
      r'D:\sdk\flutter_3.47.6\bin\flutter.bat',
    );
    expect(sdk.resolveCommand('dart'), r'D:\sdk\flutter_3.47.6\bin\dart.bat');
    expect(sdk.resolveCommand('adb'), 'adb');
  });

  test('the real environment resolves to an existing flutter launcher', () {
    final String flutter = FlutterSdkExecutables.current().flutter();
    // Under `flutter test` FLUTTER_ROOT is always exported, so the PATH
    // fallback must not be what we got.
    expect(flutter, isNot('flutter'));
    expect(File(flutter).existsSync(), isTrue, reason: flutter);
  });

  test('no repo tool hardcodes a machine-local Flutter SDK path', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in Directory(
      'tool',
    ).listSync(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String text = e.readAsStringSync();
      if (RegExp(r'flutter_sdk[\\/]+flutter_').hasMatch(text) ||
          text.contains('flutter_extracted')) {
        offenders.add(e.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
