import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// Source-scan guards for BUG-1933 (Windows 全屏/取消全屏闪一帧白色).
///
/// window_manager's `SetFullScreen` and media_kit's `EnterNativeFullscreen`
/// both implement fullscreen by stripping `WS_CAPTION|WS_THICKFRAME`; the
/// style change makes DWM rebuild the window's frame visual and for at least
/// one composition the Flutter view's layer is absent, revealing the
/// redirection surface (theme surface colour — white in a light theme) for a
/// full frame. The fix makes the runner the single owner of Windows
/// fullscreen: frame styles kept, window oversized so the client area covers
/// the monitor, HWND_TOPMOST over the taskbar, a pre-transition screen
/// snapshot stretched onto the surface as a race fallback, and every Dart
/// entry point routed through the `app.fushi/window` channel.
///
/// The Win32 runner cannot run on the Dart host, so these pin the wiring.
/// Comments are masked (not deleted) before order checks so a stale
/// explanatory comment cannot satisfy an `indexOf` on the real call site,
/// while every offset still lines up with the original source.
/// `maskComments` is the shared lexical primitive — it also covers block
/// comments, which a line-only regex lets through.
void main() {
  late String cpp;
  late String header;
  late String flutterWindow;
  late String navDart;
  late String videoFullscreenDart;
  late String placementDart;
  late String channelDart;

  setUpAll(() {
    cpp = maskComments(
      File('windows/runner/win32_window.cpp').readAsStringSync(),
    );
    header = File('windows/runner/win32_window.h').readAsStringSync();
    flutterWindow = maskComments(
      File('windows/runner/flutter_window.cpp').readAsStringSync(),
    );
    navDart = maskComments(
      File('lib/src/shortcuts/global_navigation.dart').readAsStringSync(),
    );
    videoFullscreenDart = maskComments(
      File(
        'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
      ).readAsStringSync(),
    );
    placementDart = maskComments(
      File('lib/src/startup/desktop_window_placement.dart').readAsStringSync(),
    );
    channelDart = maskComments(
      File('lib/src/utils/window_caption_channel.dart').readAsStringSync(),
    );
  });

  group('BUG-1933 runner-owned fullscreen', () {
    test('the runner never strips frame styles (no GWL_STYLE writes)', () {
      // Style stripping is the root cause: it forces a DWM frame-visual
      // rebuild that drops the Flutter view layer for a frame. Reading
      // GWL_STYLE (for AdjustWindowRectExForDpi) is fine; writing it is not.
      expect(
        RegExp(r'SetWindowLongPtr\([^,]+,\s*GWL_STYLE').hasMatch(cpp),
        isFalse,
        reason:
            'fullscreen must keep WS_CAPTION|WS_THICKFRAME; stripping them '
            'reveals the surface for a frame (the white flash).',
      );
      expect(header.contains('void SetFullscreen(bool fullscreen);'), isTrue);
      expect(header.contains('bool IsFullscreen() const'), isTrue);
    });

    test('SetFullscreen oversizes by the DPI frame and goes topmost', () {
      final int fnAt = cpp.indexOf('void Win32Window::SetFullscreen(');
      expect(fnAt, isNonNegative);
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);
      expect(
        body.contains('ClientToScreen(hwnd, &client_origin);'),
        isTrue,
        reason:
            'the client area must cover the monitor exactly, and the frame '
            'must be MEASURED (window rect vs client origin) — '
            'AdjustWindowRectExForDpi is wrong under window_manager\'s '
            'hidden-title-bar WM_NCCALCSIZE reshaping.',
      );
      expect(body.contains('AdjustWindowRectExForDpi'), isFalse);
      expect(
        body.contains('HWND_TOPMOST'),
        isTrue,
        reason:
            'the shell does not classify an oversized framed window as '
            'fullscreen, so without topmost the taskbar stays on top.',
      );
      expect(body.contains('GetWindowPlacement(hwnd'), isTrue);
      expect(body.contains('CaptureTransitionSnapshot();'), isTrue);
    });

    test('exiting from a maximized entry re-maximizes via SW_SHOWNORMAL', () {
      // The zoomed flag survives the fullscreen SetWindowPos; restoring a
      // SW_SHOWMAXIMIZED placement onto an already-"maximized" window is a
      // geometry no-op and the window stays at the oversized rect (measured).
      final int fnAt = cpp.indexOf('void Win32Window::SetFullscreen(');
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);
      expect(body.contains('restore.showCmd = SW_SHOWNORMAL;'), isTrue);
      expect(body.contains('ShowWindow(hwnd, SW_MAXIMIZE);'), isTrue);
      expect(body.contains('HWND_NOTOPMOST'), isTrue);
    });

    test('FillSurfaceBackdrop prefers the transition snapshot', () {
      final int fnAt = cpp.indexOf('void Win32Window::FillSurfaceBackdrop()');
      expect(fnAt, isNonNegative);
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);
      final int snapshotAt = body.indexOf('transition_snapshot_ != nullptr');
      final int stretchAt = body.indexOf('StretchBlt(');
      final int brushAt = body.indexOf('PaintBackdrop(dc)');
      expect(snapshotAt, isNonNegative);
      expect(stretchAt, greaterThan(snapshotAt));
      expect(
        brushAt,
        greaterThan(stretchAt),
        reason:
            'a raced composition during the fullscreen jump must show the '
            'previous frame, not a solid colour flash; everything without a '
            'snapshot (interactive resize) keeps the cheap brush fill.',
      );
    });

    test('WM_ACTIVATE drops topmost while fullscreen and deactivated', () {
      final int activateAt = cpp.indexOf('case WM_ACTIVATE:');
      expect(activateAt, isNonNegative);
      final int nextAt = cpp.indexOf('case WM_DISPLAYCHANGE:', activateAt);
      expect(nextAt, greaterThan(activateAt));
      final String body = cpp.substring(activateAt, nextAt);
      expect(body.contains('fullscreen_'), isTrue);
      expect(
        body.contains('WA_INACTIVE'),
        isTrue,
        reason:
            'holding topmost while another app is active would keep a '
            'screen-sized window over everything.',
      );
      expect(body.contains('HWND_NOTOPMOST'), isTrue);
    });

    test('WM_GETMINMAXINFO is lifted after the plugin delegates ran', () {
      final int dispatchAt = flutterWindow.indexOf(
        'HandleTopLevelWindowProc(hwnd, message, wparam',
      );
      expect(dispatchAt, isNonNegative);
      final int liftAt = flutterWindow.indexOf(
        'message == WM_GETMINMAXINFO && IsFullscreen()',
      );
      expect(
        liftAt,
        greaterThan(dispatchAt),
        reason:
            "window_manager's delegate consumes WM_GETMINMAXINFO (it applies "
            'the minimum window size); the max-track lift must run after it, '
            'or the fullscreen SetWindowPos is clamped ~30px short and a '
            'taskbar strip stays exposed (measured).',
      );
      final int liftEnd = flutterWindow.indexOf('return 0;', liftAt);
      expect(liftEnd, greaterThan(liftAt));
      expect(
        flutterWindow.substring(liftAt, liftEnd).contains('ptMaxTrackSize'),
        isTrue,
      );
    });

    test('the window channel exposes setFullscreen/isFullscreen', () {
      expect(
        flutterWindow.contains('call.method_name() == "setFullscreen"'),
        isTrue,
      );
      expect(
        flutterWindow.contains('call.method_name() == "isFullscreen"'),
        isTrue,
      );
      expect(flutterWindow.contains('SetFullscreen(enter);'), isTrue);
      expect(
        flutterWindow.contains(
          'result->Success(flutter::EncodableValue(IsFullscreen()))',
        ),
        isTrue,
      );
      expect(
        channelDart.contains("invokeMethod<void>('setFullscreen'"),
        isTrue,
      );
      expect(
        channelDart.contains("invokeMethod<bool>('isFullscreen')"),
        isTrue,
      );
    });

    test('every Dart fullscreen entry routes Windows through the runner', () {
      // The single Windows mutation/read point behind
      // toggleDesktopWindowFullscreen / setDesktopWindowFullscreen must talk
      // to the runner, never to window_manager (whose SetFullScreen strips
      // the frame styles — the flash).
      final int resolveAt = navDart.indexOf(
        'Future<bool?> _resolveWindowsFullscreen(',
      );
      expect(resolveAt, isNonNegative);
      final int resolveEnd = navDart.indexOf('\n}', resolveAt);
      final String resolveBody = navDart.substring(resolveAt, resolveEnd);
      expect(
        resolveBody.contains('WindowCaptionChannel.setFullscreen(fullscreen)'),
        isTrue,
      );
      expect(
        resolveBody.contains('WindowCaptionChannel.isFullscreen()'),
        isTrue,
      );
      expect(
        resolveBody.contains('windowManager.'),
        isFalse,
        reason:
            'window_manager.setFullScreen strips the frame styles on '
            'Windows — it must only remain as the Linux path.',
      );

      // The Windows state read must also come from the runner
      // (window_manager.isFullScreen is permanently false there).
      final int readAt = navDart.indexOf(
        'Future<bool?> readDesktopWindowFullscreen()',
      );
      expect(readAt, isNonNegative);
      final int readWinAt = navDart.indexOf(
        'WindowCaptionChannel.isFullscreen()',
        readAt,
      );
      final int readChromeAt = navDart.indexOf(
        'FushiWindowsTitleBar.setWindowManagerFullscreen(fullscreen)',
        readAt,
      );
      expect(readWinAt, isNonNegative);
      expect(
        readChromeAt,
        greaterThan(readWinAt),
        reason:
            'the app-frame chrome must be derived from the runner-owned '
            'state.',
      );

      // Video player native fullscreen callbacks (media_kit replacement).
      final int enterAt = videoFullscreenDart.indexOf(
        '_enterVideoNativeFullscreen()',
      );
      expect(enterAt, isNonNegative);
      final int enterRouteAt = videoFullscreenDart.indexOf(
        'WindowCaptionChannel.setFullscreen(true)',
        enterAt,
      );
      final int enterDefaultAt = videoFullscreenDart.indexOf(
        'defaultEnterNativeFullscreen()',
        enterAt,
      );
      expect(enterRouteAt, isNonNegative);
      expect(enterDefaultAt, greaterThan(enterRouteAt));

      final int exitAt = videoFullscreenDart.indexOf(
        '_exitVideoNativeFullscreen()',
      );
      expect(exitAt, isNonNegative);
      final int exitRouteAt = videoFullscreenDart.indexOf(
        'WindowCaptionChannel.setFullscreen(false)',
        exitAt,
      );
      final int exitDefaultAt = videoFullscreenDart.indexOf(
        'defaultExitNativeFullscreen()',
        exitAt,
      );
      expect(exitRouteAt, isNonNegative);
      expect(exitDefaultAt, greaterThan(exitRouteAt));
    });

    test('bounds saving skips the runner-owned fullscreen state', () {
      // window_manager.isFullScreen() is permanently false on Windows now;
      // without asking the runner, the oversized fullscreen rect would be
      // saved as normal bounds and the next launch starts monitor-sized
      // (measured).
      final int saveAt = placementDart.indexOf(
        'Future<void> saveCurrentBoundsNow()',
      );
      expect(saveAt, isNonNegative);
      final int checkAt = placementDart.indexOf(
        'WindowCaptionChannel.isFullscreen()',
        saveAt,
      );
      final int readBoundsAt = placementDart.indexOf(
        'windowManager.getBounds()',
        saveAt,
      );
      expect(checkAt, isNonNegative);
      expect(readBoundsAt, greaterThan(checkAt));
    });
  });

  group('BUG-2006 edge-to-edge windows suppress the DWM frame chrome', () {
    // Windows 11 paints the thin window border and rounds the window's
    // corners in the compositor, ON TOP of the client area — neither belongs
    // to the non-client area window_manager's hidden-title-bar WM_NCCALCSIZE
    // leaves this window. Whenever the client reaches the screen edges that
    // chrome lands on app content: measured on Windows 11 26200, a normal
    // (SW_SHOWNORMAL, not zoomed) Hibiki window sized to the monitor has
    // 3830/3840 pixels of screen row 0 painted in the accent colour and the
    // desktop showing through all four corners — the user's report.
    //
    // The suppression is therefore NOT fullscreen-only: it must cover every
    // way this window presents edge to edge.

    test('the policy covers fullscreen, maximized AND screen-sized', () {
      final int fnAt = cpp.indexOf('void Win32Window::UpdateFrameChrome()');
      expect(
        fnAt,
        isNonNegative,
        reason:
            'a single policy point decides whether DWM may paint chrome over '
            'the client area.',
      );
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      expect(fnEnd, greaterThan(fnAt));
      final String body = cpp.substring(fnAt, fnEnd);

      expect(
        body.contains('fullscreen_'),
        isTrue,
        reason: 'runner-owned fullscreen covers the monitor.',
      );
      expect(
        body.contains('IsZoomed(hwnd)'),
        isTrue,
        reason:
            'Windows drops the border and the rounding for a maximized '
            'window on its own; a custom-frame window has to ask.',
      );
      expect(
        body.contains('ClientCoversMonitor(hwnd)'),
        isTrue,
        reason:
            'the reported state was a NORMAL, not-zoomed window whose client '
            'happened to cover the monitor (measured 3830/3840 accent pixels '
            'on screen row 0) — a fullscreen-only guard would miss it.',
      );
      expect(
        body.contains('frame_chrome_suppressed_'),
        isTrue,
        reason:
            'transition-only: a DwmSetWindowAttribute round trip on every '
            'WM_SIZE would tax interactive resizing (BUG-1917 cadence).',
      );
    });

    test('both DWM attributes are set, and both are restorable', () {
      final int fnAt = cpp.indexOf('void ApplyFrameChrome(');
      expect(fnAt, isNonNegative);
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);

      expect(
        body.contains('DWMWA_BORDER_COLOR'),
        isTrue,
        reason:
            'DWMWA_BORDER_COLOR=DWMWA_COLOR_NONE is the measured fix for the '
            'top line (600/600 chrome pixels on the client top row before, '
            '0/600 after, and the line returns when the default is restored).',
      );
      expect(body.contains('DWMWA_COLOR_NONE'), isTrue);
      expect(
        body.contains('DWMWA_COLOR_DEFAULT'),
        isTrue,
        reason:
            'an ordinary windowed Hibiki must keep its normal border — this '
            'is a state-dependent policy, not a permanent window attribute.',
      );
      expect(
        body.contains('DWMWA_WINDOW_CORNER_PREFERENCE'),
        isTrue,
        reason:
            'the rounded corners clip the client and show the desktop '
            'through all four corners; DWMWCP_DONOTROUND is a separate fix '
            'from the border colour (measured: it alone leaves the top line '
            'untouched, and the border colour alone leaves the corners cut).',
      );
      expect(body.contains('DWMWCP_DONOTROUND'), isTrue);
      expect(body.contains('DWMWCP_DEFAULT'), isTrue);
      expect(
        cpp.contains('#include <dwmapi.h>'),
        isTrue,
        reason: 'DwmSetWindowAttribute needs the DWM header.',
      );
    });

    test('every geometry change re-evaluates the policy', () {
      final int sizeAt = cpp.indexOf('case WM_SIZE:');
      expect(sizeAt, isNonNegative);
      final int sizeEnd = cpp.indexOf('case WM_ERASEBKGND', sizeAt);
      expect(sizeEnd, greaterThan(sizeAt));
      expect(
        cpp.substring(sizeAt, sizeEnd).contains('UpdateFrameChrome()'),
        isTrue,
        reason:
            'maximize / restore / drag-resize all cross the edge-to-edge '
            'boundary; without a WM_SIZE hook the chrome would only ever be '
            'updated by the fullscreen toggle.',
      );

      final int fnAt = cpp.indexOf('void Win32Window::SetFullscreen(');
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);
      final int enterChromeAt = body.indexOf('UpdateFrameChrome()');
      final int topmostAt = body.indexOf('SetWindowPos(hwnd, HWND_TOPMOST');
      expect(enterChromeAt, isNonNegative);
      expect(
        topmostAt,
        greaterThan(enterChromeAt),
        reason:
            'suppress the chrome before the jump, or the compositor paints '
            'the border over a client area that already covers the monitor.',
      );

      final int notopmostAt = body.indexOf('HWND_NOTOPMOST');
      final int exitChromeAt = body.indexOf('UpdateFrameChrome()', notopmostAt);
      expect(notopmostAt, isNonNegative);
      expect(
        exitChromeAt,
        greaterThan(notopmostAt),
        reason:
            're-evaluate only once the geometry is back, so the policy sees '
            'the restored window instead of the still-oversized one.',
      );
    });
  });
}
