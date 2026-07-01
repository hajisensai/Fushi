import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('macOS file picker entitlements', () {
    const List<String> entitlementFiles = <String>[
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ];

    for (final String path in entitlementFiles) {
      test('$path allows user-selected read/write file access', () {
        final String xml =
            File(path).readAsStringSync().replaceAll('\r\n', '\n');

        expect(
          xml,
          contains(
              '<key>com.apple.security.files.user-selected.read-write</key>'),
          reason: 'FilePicker save/open/directory panels need this entitlement '
              'when the macOS app sandbox is enabled.',
        );
        expect(
          xml,
          contains('<key>com.apple.security.app-sandbox</key>\n\t<true/>'),
          reason:
              'This guard is only meaningful while the app sandbox stays on.',
        );
      });
    }
  });
}
