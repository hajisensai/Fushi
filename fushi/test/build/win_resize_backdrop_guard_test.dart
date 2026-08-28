import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for BUG-1916 (Windows 最大化/还原/缩放过渡露出深青「底色层」).
///
/// The Win32 runner cannot run on the Dart host, so these pin the wiring that
/// keeps the top-level window's own surface — which DWM shows for a frame
/// during maximize / restore / DPI transitions, underneath the separately
/// composed Flutter view — the same colour as the app background:
///
/// * the window class owns no background brush (the TODO-959 splash colour is
///   only the *initial* value of the per-window backdrop brush);
/// * the main window is created `WS_CLIPCHILDREN`, so WM_PAINT erases never
///   touch the pixels under the Flutter view;
/// * `WM_SIZE` refills the whole surface (under the view too, via the
///   unclipped `GetDCEx(..., DCX_CACHE)`) *before* `MoveWindow` blocks on the
///   engine's synchronous resize;
/// * `WM_ERASEBKGND` erases with that same brush and reports the erase handled;
/// * Dart's theme surface colour (`setCaptionColors`) is what replaces the
///   splash colour, and replacing it refills the surface immediately.
///
/// Comments are stripped before the order checks so a stale explanatory
/// comment cannot satisfy an `indexOf` on the real call site.
String _stripLineComments(String source) =>
    source.replaceAll(RegExp(r'//[^\n]*'), '');

void main() {
  late String cpp;
  late String header;
  late String flutterWindow;

  setUpAll(() {
    cpp = _stripLineComments(
      File('windows/runner/win32_window.cpp').readAsStringSync(),
    );
    header = File('windows/runner/win32_window.h').readAsStringSync();
    flutterWindow = _stripLineComments(
      File('windows/runner/flutter_window.cpp').readAsStringSync(),
    );
  });

  group('BUG-1916 Windows surface backdrop', () {
    test('window class owns no background brush', () {
      expect(
        cpp.contains('window_class.hbrBackground = nullptr;'),
        isTrue,
        reason: 'the class brush is what painted teal under the view.',
      );
      expect(
        cpp.contains('window_class.hbrBackground = CreateSolidBrush'),
        isFalse,
      );
    });

    test('main window is created WS_CLIPCHILDREN', () {
      final int styleAt = cpp.indexOf('const DWORD window_style =');
      expect(styleAt, isNonNegative);
      final int createAt = cpp.indexOf('CreateWindowEx(', styleAt);
      expect(createAt, greaterThan(styleAt));
      expect(
        cpp.substring(styleAt, createAt).contains('WS_CLIPCHILDREN'),
        isTrue,
        reason: 'without WS_CLIPCHILDREN WM_PAINT erases under the view.',
      );
    });

    test('WM_SIZE refills the surface before resizing the child view', () {
      final int sizeAt = cpp.indexOf('case WM_SIZE:');
      expect(sizeAt, isNonNegative);
      final int eraseAt = cpp.indexOf('case WM_ERASEBKGND:', sizeAt);
      expect(eraseAt, greaterThan(sizeAt));
      final String body = cpp.substring(sizeAt, eraseAt);
      final int fillAt = body.indexOf('FillSurfaceBackdrop();');
      final int moveAt = body.indexOf('MoveWindow(child_content_');
      expect(fillAt, isNonNegative);
      expect(
        moveAt,
        greaterThan(fillAt),
        reason:
            'MoveWindow blocks until the engine presents; the resized '
            'surface must already be theme-coloured before that.',
      );
    });

    test('FillSurfaceBackdrop paints under the view with an unclipped DC', () {
      final int fnAt = cpp.indexOf('void Win32Window::FillSurfaceBackdrop()');
      expect(fnAt, isNonNegative);
      final int fnEnd = cpp.indexOf('\n}', fnAt);
      final String body = cpp.substring(fnAt, fnEnd);
      expect(
        body.contains('GetDCEx(window_handle_, nullptr, DCX_CACHE)'),
        isTrue,
        reason:
            'GetDC honours WS_CLIPCHILDREN and would skip the pixels under '
            'the view, which is exactly where the stale splash fill lives.',
      );
      expect(body.contains('PaintBackdrop(dc)'), isTrue);
      expect(body.contains('GetDC(window_handle_)'), isFalse);
    });

    test(
      'WM_ERASEBKGND erases with the instance brush and reports handled',
      () {
        final int eraseAt = cpp.indexOf('case WM_ERASEBKGND:');
        expect(eraseAt, isNonNegative);
        final int nextAt = cpp.indexOf('case WM_ACTIVATE:', eraseAt);
        expect(nextAt, greaterThan(eraseAt));
        final String body = cpp.substring(eraseAt, nextAt);
        expect(
          body.contains('PaintBackdrop(reinterpret_cast<HDC>(wparam))'),
          isTrue,
        );
        expect(
          body.contains('return 1;'),
          isTrue,
          reason: 'returning 0 would let DefWindowProc erase again.',
        );
      },
    );

    test('backdrop brush starts as the splash colour, follows the theme, and '
        'refills the surface when replaced', () {
      expect(header.contains('void SetBackdropColor(COLORREF color);'), isTrue);
      expect(header.contains('void FillSurfaceBackdrop();'), isTrue);
      expect(header.contains('HBRUSH backdrop_brush_ = nullptr;'), isTrue);
      expect(
        cpp.contains(
          'backdrop_brush_(CreateSolidBrush(kSplashBackgroundColor))',
        ),
        isTrue,
        reason: 'TODO-959 cold-start splash fill must survive.',
      );
      final int setAt = cpp.indexOf('void Win32Window::SetBackdropColor(');
      expect(setAt, isNonNegative);
      final int setEnd = cpp.indexOf('\n}', setAt);
      expect(
        cpp.substring(setAt, setEnd).contains('FillSurfaceBackdrop();'),
        isTrue,
        reason:
            'replacing the brush without repainting leaves the splash '
            'colour under the view until the first maximize shows it.',
      );
      final int applyAt = flutterWindow.indexOf(
        'void FlutterWindow::ApplyCaptionColors(',
      );
      expect(applyAt, isNonNegative);
      final int applyEnd = flutterWindow.indexOf('\n}', applyAt);
      expect(applyEnd, greaterThan(applyAt));
      expect(
        flutterWindow
            .substring(applyAt, applyEnd)
            .contains('SetBackdropColor(caption)'),
        isTrue,
        reason:
            'the theme surface colour pushed by Dart must drive the '
            'backdrop, or the transition frame stays teal.',
      );
    });
  });
}
