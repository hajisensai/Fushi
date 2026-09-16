// macOS support for the app-external global lookup: the platform gate and the
// popup assets folder the native overlay serves (Windows keeps the
// <exe>/data layout; macOS resolves into the App.framework bundle).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  group('GlobalLookupController.popupAssetsDirFor', () {
    // Path styles are passed explicitly: the global `p` context follows the
    // host OS, so a Windows-style path split on a Linux CI runner would yield
    // ['.', ...] (the original CI red of PR #1490).
    test('macOS resolves into Contents/Frameworks/App.framework', () {
      final String dir = GlobalLookupController.popupAssetsDirFor(
        '/Applications/Fushi.app/Contents/MacOS/Fushi',
        isMacOS: true,
        context: p.posix,
      );
      expect(
        p.posix.split(dir).skipWhile((String s) => s != 'Fushi.app').toList(),
        <String>[
          'Fushi.app',
          'Contents',
          'Frameworks',
          'App.framework',
          'Resources',
          'flutter_assets',
          'assets',
          'popup',
        ],
      );
      expect(dir, isNot(contains('..')));
    });

    test('Windows keeps the <exe>/data/flutter_assets layout', () {
      final String dir = GlobalLookupController.popupAssetsDirFor(
        r'C:\Program Files\Fushi\fushi.exe',
        isMacOS: false,
        context: p.windows,
      );
      final List<String> parts = p.windows.split(dir);
      expect(parts.skip(parts.length - 5).toList(), <String>[
        'Fushi',
        'data',
        'flutter_assets',
        'assets',
        'popup',
      ]);
    });
  });

  test('isSupported covers Windows and macOS (Linux still has no overlay)', () {
    // Source guard: the gate is what unlocks start(), the settings switches and
    // the shortcut registration on macOS.
    final String src = File(
      'lib/src/lookup/global_lookup_controller.dart',
    ).readAsStringSync();
    expect(src, contains('(Platform.isWindows || Platform.isMacOS)'));
    expect(
      GlobalLookupController.isSupported,
      Platform.isWindows || Platform.isMacOS,
    );
  });
}
