import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard for BUG-837: desktop video fullscreen must NOT become a
/// DWM exclusive fullscreen (Fullscreen Optimization / exclusive MPO flip).
///
/// media_kit's upstream [Utils::EnterNativeFullscreen] makes the borderless
/// main window fill the monitor rect exactly and lands it at HWND_TOP. On
/// Windows that gets promoted to exclusive fullscreen: the window seizes the
/// z-order, so the user can no longer Alt+Tab / click the taskbar to reach
/// other apps (the second monitor is dragged along too) — only Win+D or exiting
/// the video releases it. The native window cannot run on the test host, so
/// this guard pins the two load-bearing bits of the fix inside the vendored
/// utils.cc so a `pub get` re-vendor or refactor cannot silently regress it.
void main() {
  late String enterBody;

  setUpAll(() {
    final String cpp =
        File('../third_party/media_kit_video/windows/utils.cc')
            .readAsStringSync();
    final int enter = cpp.indexOf('void Utils::EnterNativeFullscreen');
    final int exit = cpp.indexOf('void Utils::ExitNativeFullscreen');
    expect(enter, greaterThanOrEqualTo(0),
        reason: 'EnterNativeFullscreen must exist in vendored utils.cc');
    expect(exit, greaterThan(enter),
        reason: 'ExitNativeFullscreen must follow EnterNativeFullscreen');
    enterBody = cpp.substring(enter, exit);
  });

  group('BUG-837 desktop video fullscreen is non-exclusive', () {
    test('window lands non-topmost so other apps can cover it', () {
      // Must place the fullscreen window on the non-topmost band and clear any
      // leftover always-on-top, so an activated app can rise above it.
      expect(enterBody.contains('HWND_NOTOPMOST'), isTrue,
          reason: 'Fullscreen window must be forced non-topmost (BUG-837).');
      expect(enterBody.contains('HWND_TOP,'), isFalse,
          reason:
              'HWND_TOP re-introduces exclusive-fullscreen z-order seizure.');
    });

    test('client rect is not an exact monitor cover (breaks exclusive flip)',
        () {
      // One pixel taller than the monitor keeps the window off the DWM
      // exclusive-fullscreen path; the extra pixel is off-screen and invisible.
      expect(enterBody.contains('monitor_height + 1'), isTrue,
          reason:
              'Fullscreen height must differ from the monitor rect so DWM does '
              'not promote it to an exclusive flip (BUG-837).');
    });
  });
}
