import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String readSource(String rel) {
    final File file = File(rel);
    expect(file.existsSync(), isTrue, reason: 'missing source: $rel');
    return file.readAsStringSync();
  }

  group('macOS restart uses LaunchServices', () {
    test('DesktopLifecycleService restarts macOS via open --args', () {
      final String src = readSource(
        'lib/src/platform/desktop/desktop_lifecycle_service.dart',
      );

      expect(src.contains('Platform.isMacOS'), isTrue,
          reason: 'macOS must not use the raw executable restart path.');
      expect(src.contains("'/usr/bin/open'"), isTrue,
          reason:
              'sandboxed macOS app restarts must go through LaunchServices.');
      expect(src.contains("'--args'"), isTrue,
          reason: 'the restart marker still has to reach main(List<String>).');
      expect(src.contains('macOSAppBundlePathForExecutable'), isTrue,
          reason: 'restart must launch the .app bundle, not Contents/MacOS.');
    });
  });
}
