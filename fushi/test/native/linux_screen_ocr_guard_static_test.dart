// Source guard for the Linux desktop floating ball's screen OCR (capture +
// freeze layer, spec docs/specs/2026-09-30-desktop-system-floating-ball.md
// "截屏识字"). Linux native code is not built on the Windows CI runner, so this
// scans the sources: the channel contract the Dart host uses, the portal
// capture on Wayland desktops, and the build wiring stay in place.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String relativeToFushi) {
    final File file = File(relativeToFushi);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected file at ${file.absolute.path}',
    );
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  late String channel;
  late String capture;
  late String overlay;
  late String cmake;
  late String dartChannel;
  setUpAll(() {
    channel = read('linux/runner/floating_ball_channel.cc');
    capture = read('linux/runner/screen_capture.cc');
    overlay =
        read('linux/runner/screen_ocr_overlay.cc') +
        read('linux/runner/screen_ocr_overlay.h');
    cmake = read('linux/runner/CMakeLists.txt');
    dartChannel = read('lib/src/floating_ball/floating_ball_channel.dart');
  });

  test('runner answers the three Dart → native screen OCR methods', () {
    for (final String method in <String>[
      'startScreenOcrCapture',
      'updateScreenOcrOverlay',
      'stopScreenOcr',
    ]) {
      expect(dartChannel, contains("'$method'"), reason: method);
      expect(channel, contains('method == "$method"'), reason: method);
    }
  });

  test('runner reports taps and dismissal with the names Dart listens to', () {
    for (final String method in <String>[
      'screenOcrTap',
      'screenOcrDismissed',
    ]) {
      expect(dartChannel, contains("'$method'"), reason: method);
      expect(channel, contains('"$method"'), reason: method);
    }
    // Reply keys of startScreenOcrCapture (DesktopScreenOcrCapture).
    for (final String key in <String>['png', 'screen', 'error']) {
      expect(channel, contains('"$key"'), reason: key);
    }
  });

  test('Wayland desktops capture through the screenshot portal', () {
    // XWayland only sees X windows: a root read is black there.
    expect(capture, contains('org.freedesktop.portal.Screenshot'));
    expect(capture, contains('"interactive"'));
    expect(capture, contains('g_variant_new_boolean(FALSE)'));
    // The portal writes a file per request: it is our temporary capture.
    expect(capture, contains('g_unlink(path)'));
    // Without a match rule the Response signal never arrives.
    expect(capture, isNot(contains('G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE')));
    expect(capture, contains('"permission_denied"'));
  });

  test('freeze layer is an unmanaged popup sharing the Windows logic', () {
    expect(overlay, contains('GTK_WINDOW_POPUP'));
    expect(overlay, contains('windows/runner/screen_ocr_logic.h'));
    expect(overlay, contains('ClassifyLeftClick'));
    expect(overlay, contains('LayoutBanner'));
    expect(overlay, contains('GDK_KEY_Escape'));
  });

  test('windows hidden for a capture skip the KWin close fade', () {
    // Otherwise the screenshot catches the fading ball / button column.
    expect(capture, contains('_KDE_NET_WM_SKIP_CLOSE_ANIMATION'));
    expect(
      read('linux/runner/floating_ball_window.cc'),
      contains('SkipCloseAnimation('),
    );
    expect(overlay, contains('SkipCloseAnimation('));
  });

  test('both sources are built into the runner', () {
    expect(cmake, contains('"screen_capture.cc"'));
    expect(cmake, contains('"screen_ocr_overlay.cc"'));
  });
}
