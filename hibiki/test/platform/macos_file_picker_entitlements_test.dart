import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('macOS file picker entitlements', () {
    const List<String> entitlementFiles = <String>[
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ];

    for (final String path in entitlementFiles) {
      test('$path keeps user-selected read/write file access', () {
        final String xml =
            File(path).readAsStringSync().replaceAll('\r\n', '\n');

        expect(
          xml,
          contains(
              '<key>com.apple.security.files.user-selected.read-write</key>'),
          reason: 'FilePicker save/open/directory panels rely on this '
              'entitlement; kept (a no-op without the sandbox) so the file '
              'picker / data-root code paths stay unchanged.',
        );
      });

      // 全平台自动更新 Phase 3：macOS 去沙盒换真应用内自替换（写 /Applications/
      // hibiki.app 需沙盒外，见 platform_updater.dart 的 MacInstaller）。此断言从
      // 「app-sandbox 必须在」演进为「app-sandbox 必须已移除」，与 update_settings_
      // android_only_guard 的 BUG-013 演进同性质——有意的不变量演进，不是回归。
      test('$path drops the app sandbox (de-sandboxed for in-app update)', () {
        final String xml =
            File(path).readAsStringSync().replaceAll('\r\n', '\n');
        expect(
          xml.contains('<key>com.apple.security.app-sandbox</key>'),
          isFalse,
          reason: 'macOS must stay de-sandboxed so the updater can replace '
              '/Applications/hibiki.app and relaunch.',
        );
      });
    }
  });
}
