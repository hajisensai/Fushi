import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-235 source-scan guard: the vendored `media_kit_video` desktop seek bar
/// must keep its use-after-dispose guards.
///
/// Root cause: upstream `media_kit_video` 2.0.1's `MaterialDesktopSeekBarState`
/// calls `controller(context)` (which dereferences `State.context`) inside both
/// `onPointerUp()` and `onPointerMove()` with no `mounted` guard. Hibiki tears
/// down the controls subtree on fullscreen enter/exit and episode switch
/// (VideoControlsFocusGate), so releasing the seek bar drag right then lands on
/// a disposed State and crashes with
/// `Null check operator used on a null value`
/// (`material_desktop.dart`, MaterialDesktopSeekBarState.onPointerUp).
///
/// Fix: the package is vendored to `third_party/media_kit_video/` and both
/// handlers get `if (!mounted) return;` (matching the State's existing
/// `if (mounted)` setState guard). This test guards the *patch* — if a future
/// re-vendor of media_kit_video drops the guard, the crash returns and this
/// goes red. See `third_party/media_kit_video/PATCHES.md`.
void main() {
  // Tests run with CWD = `hibiki/`; vendored packages live at the workspace root.
  const String controlsPath =
      '../third_party/media_kit_video/lib/media_kit_video_controls/'
      'src/controls/material_desktop.dart';

  test('vendored media_kit_video override is wired in pubspec', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExp override = RegExp(
      r'media_kit_video:\s*\n\s*path:\s*\.\./third_party/media_kit_video',
    );
    expect(
      override.hasMatch(pubspec),
      isTrue,
      reason: 'dependency_overrides must point media_kit_video at '
          '../third_party/media_kit_video (BUG-235). Without it the pub.dev '
          'package returns and the seek bar onPointerUp UAF crash comes back.',
    );
  });

  group('MaterialDesktopSeekBarState pointer handlers guard !mounted', () {
    late String source;

    setUp(() {
      source = File(controlsPath).readAsStringSync();
    });

    /// Returns the body of `void <name>(...) { ... }` by brace matching, so the
    /// assertion is about the handler itself and never matches an unrelated
    /// `if (!mounted) return;` elsewhere in the file.
    String bodyOf(String name) {
      final int sig = source.indexOf(RegExp('void\\s+$name\\s*\\('));
      expect(sig, isNonNegative,
          reason: 'expected a `void $name(` handler in $controlsPath');
      final int open = source.indexOf('{', sig);
      expect(open, isNonNegative);
      int depth = 0;
      for (int i = open; i < source.length; i++) {
        final String c = source[i];
        if (c == '{') depth++;
        if (c == '}') {
          depth--;
          if (depth == 0) return source.substring(open, i + 1);
        }
      }
      fail('unbalanced braces in $name body of $controlsPath');
    }

    test('onPointerUp returns early when unmounted', () {
      expect(
        bodyOf('onPointerUp').contains(RegExp(r'if\s*\(\s*!mounted\s*\)\s*return')),
        isTrue,
        reason: 'onPointerUp dereferences controller(context); it must bail out '
            'with `if (!mounted) return;` before that, or the disposed-State '
            'crash (BUG-235) returns.',
      );
    });

    test('onPointerMove returns early when unmounted', () {
      expect(
        bodyOf('onPointerMove')
            .contains(RegExp(r'if\s*\(\s*!mounted\s*\)\s*return')),
        isTrue,
        reason: 'onPointerMove also dereferences controller(context); it must '
            'bail out with `if (!mounted) return;` (BUG-235).',
      );
    });
  });
}
