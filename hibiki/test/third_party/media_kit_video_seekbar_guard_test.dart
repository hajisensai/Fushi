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
        bodyOf('onPointerUp')
            .contains(RegExp(r'if\s*\(\s*!mounted\s*\)\s*return')),
        isTrue,
        reason:
            'onPointerUp dereferences controller(context); it must bail out '
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

  group('TODO-669: seek-bar onHoverPosition patch survives re-vendor', () {
    late String source;

    setUp(() {
      source = File(controlsPath).readAsStringSync();
    });

    test('theme data class exposes onHoverPosition field', () {
      expect(
        source.contains(
          RegExp(r'void Function\(double\? fraction\)\?\s+onHoverPosition'),
        ),
        isTrue,
        reason: 'MaterialDesktopVideoControlsThemeData must keep the '
            'onHoverPosition field (TODO-669); without it the host can no '
            'longer drive the progress-bar thumbnail preview.',
      );
    });

    test('copyWith carries onHoverPosition', () {
      expect(
        source.contains(
          RegExp(
              r'onHoverPosition:\s*onHoverPosition \?\? this\.onHoverPosition'),
        ),
        isTrue,
        reason: 'copyWith must propagate onHoverPosition (TODO-669).',
      );
    });

    test('onHover/onEnter call onHoverPosition with the fraction', () {
      // Two call sites with a clamped percent (onHover + onEnter).
      final Iterable<Match> calls = RegExp(
        r'widget\.onHoverPosition\?\.call\(percent\.clamp',
      ).allMatches(source);
      expect(
        calls.length,
        greaterThanOrEqualTo(2),
        reason: 'onHover and onEnter must surface the hover fraction to the '
            'host (TODO-669).',
      );
    });

    test('onExit clears the preview with null', () {
      expect(
        source.contains(RegExp(r'widget\.onHoverPosition\?\.call\(null\)')),
        isTrue,
        reason: 'onExit must clear the host thumbnail preview with null '
            '(TODO-669).',
      );
    });

    test('seek bar widget forwards the theme callback', () {
      expect(
        source.contains(
          RegExp(r'onHoverPosition:\s*_theme\(context\)\s*\.onHoverPosition'),
        ),
        isTrue,
        reason: 'The seek bar must be constructed with the theme '
            "onHoverPosition (TODO-669), or the host's callback never fires.",
      );
    });
  });

  group('TODO-669: host wiring (desktop only)', () {
    test('desktop controls theme injects onHoverPosition', () {
      final String themeSrc = File(
        'lib/src/pages/implementations/video_hibiki/controls_theme.part.dart',
      ).readAsStringSync();
      final int desktopStart = themeSrc.indexOf('_desktopControlsTheme(');
      final int mobileStart = themeSrc.indexOf('_mobileControlsTheme(');
      expect(desktopStart, isNonNegative);
      expect(mobileStart, isNonNegative);
      final String desktopBody = themeSrc.substring(desktopStart, mobileStart);
      final String mobileBody = themeSrc.substring(mobileStart);
      expect(
        desktopBody.contains('onHoverPosition: _onSeekBarHover'),
        isTrue,
        reason: 'desktop controls theme must wire onHoverPosition to '
            '_onSeekBarHover (TODO-669).',
      );
      expect(
        mobileBody.contains('onHoverPosition'),
        isFalse,
        reason: 'mobile controls theme must NOT wire onHoverPosition — touch '
            'has no hover, mobile stays unchanged (TODO-669).',
      );
    });

    test('thumbnail preview overlay is mounted in the controls Stack', () {
      final String layoutSrc = File(
        'lib/src/pages/implementations/video_hibiki/layout.part.dart',
      ).readAsStringSync();
      expect(
        layoutSrc.contains('_buildThumbnailPreviewOverlay(controller)'),
        isTrue,
        reason: 'the thumbnail preview overlay must ride the controls Stack '
            '(TODO-669).',
      );
    });
  });
}
