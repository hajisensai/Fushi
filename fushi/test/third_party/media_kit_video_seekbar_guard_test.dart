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
///
/// BUG-566: the *mobile* controls (`material.dart`, `MaterialSeekBarState`)
/// have the exact same unguarded `controller(context)` dereference in their
/// `onPointerMove()`/`onPointerUp()`; BUG-235 only patched the desktop file.
/// The mobile handlers carry the same `if (!mounted) return;` guard, asserted
/// by the mirrored group below.
void main() {
  // Tests run with CWD = `fushi/`; vendored packages live at the workspace root.
  const String controlsPath =
      '../third_party/media_kit_video/lib/media_kit_video_controls/'
      'src/controls/material_desktop.dart';
  const String mobileControlsPath =
      '../third_party/media_kit_video/lib/media_kit_video_controls/'
      'src/controls/material.dart';

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

  group('MaterialSeekBarState (mobile) pointer handlers guard !mounted', () {
    late String source;

    setUp(() {
      source = File(mobileControlsPath).readAsStringSync();
    });

    /// Same brace-matching body extraction as the desktop group, applied to
    /// the mobile `material.dart`.
    String bodyOf(String name) {
      final int sig = source.indexOf(RegExp('void\\s+$name\\s*\\('));
      expect(sig, isNonNegative,
          reason: 'expected a `void $name(` handler in $mobileControlsPath');
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
      fail('unbalanced braces in $name body of $mobileControlsPath');
    }

    test('onPointerUp returns early when unmounted', () {
      expect(
        bodyOf('onPointerUp')
            .contains(RegExp(r'if\s*\(\s*!mounted\s*\)\s*return')),
        isTrue,
        reason: 'mobile onPointerUp dereferences controller(context); it must '
            'bail out with `if (!mounted) return;` before that, or the '
            'disposed-State crash (BUG-566, mobile mirror of BUG-235) returns.',
      );
    });

    test('onPointerMove returns early when unmounted', () {
      expect(
        bodyOf('onPointerMove')
            .contains(RegExp(r'if\s*\(\s*!mounted\s*\)\s*return')),
        isTrue,
        reason: 'mobile onPointerMove also dereferences controller(context); '
            'it must bail out with `if (!mounted) return;` (BUG-566).',
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
        'lib/src/pages/implementations/video_fushi/controls_theme.part.dart',
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
        'lib/src/pages/implementations/video_fushi/layout.part.dart',
      ).readAsStringSync();
      expect(
        layoutSrc.contains('_buildThumbnailPreviewOverlay(controller)'),
        isTrue,
        reason: 'the thumbnail preview overlay must ride the controls Stack '
            '(TODO-669).',
      );
    });
  });

  // BUG-796 后续：进度条 seek 落点在途保护补丁（onSeekEnd(target)）必须在 re-vendor 后存活。
  // 缺任一环，进度条拖到无字幕段（尤其暂停）旧字幕不消失的 bug 复发。
  group(
      'BUG-796 follow-up: seek-bar onSeekEnd(target) patch survives re-vendor',
      () {
    for (final String path in <String>[controlsPath, mobileControlsPath]) {
      test('$path theme data class exposes onSeekEnd(Duration) field', () {
        final String source = File(path).readAsStringSync();
        expect(
          source.contains(RegExp(r'void Function\(Duration\)\?\s+onSeekEnd')),
          isTrue,
          reason: 'the theme data class must expose a '
              'void Function(Duration)? onSeekEnd field (BUG-796 follow-up); '
              'without it the host cannot learn the progress-bar seek target.',
        );
      });

      test('$path copyWith carries onSeekEnd', () {
        final String source = File(path).readAsStringSync();
        expect(
          source
              .contains(RegExp(r'onSeekEnd:\s*onSeekEnd \?\? this\.onSeekEnd')),
          isTrue,
          reason: 'copyWith must propagate onSeekEnd (BUG-796 follow-up).',
        );
      });

      test('$path seek bar forwards the committed target to onSeekEnd', () {
        final String source = File(path).readAsStringSync();
        // The seek-commit point passes the target Duration (duration * slider).
        expect(
          source.contains(
              RegExp(r'widget\.onSeekEnd\?\.call\(duration \* slider\)')),
          isTrue,
          reason: 'the seek bar onPointerUp must call '
              'onSeekEnd(duration * slider) so the host gets the destination '
              '(BUG-796 follow-up).',
        );
        // The widget instantiation forwards the theme callback with the target.
        expect(
          source.contains(
              RegExp(r'_theme\(context\)\s*\.onSeekEnd\s*\?\.call\(target\)')),
          isTrue,
          reason: 'the seek bar must be constructed forwarding '
              '_theme(context).onSeekEnd(target) (BUG-796 follow-up), or the '
              "host's callback never fires.",
        );
      });
    }

    test('host wires onSeekEnd -> notifyExternalSeek in BOTH control themes',
        () {
      final String themeSrc = File(
        'lib/src/pages/implementations/video_fushi/controls_theme.part.dart',
      ).readAsStringSync();
      final int desktopStart = themeSrc.indexOf('_desktopControlsTheme(');
      final int mobileStart = themeSrc.indexOf('_mobileControlsTheme(');
      expect(desktopStart, isNonNegative);
      expect(mobileStart, isNonNegative);
      final String desktopBody = themeSrc.substring(desktopStart, mobileStart);
      final String mobileBody = themeSrc.substring(mobileStart);
      final RegExp wiring = RegExp(
        r'onSeekEnd:\s*\(Duration target\)\s*=>\s*'
        r'controller\.notifyExternalSeek\(target\.inMilliseconds\)',
      );
      expect(wiring.hasMatch(desktopBody), isTrue,
          reason: 'desktop controls theme must wire onSeekEnd to '
              'notifyExternalSeek (BUG-796 follow-up).');
      expect(wiring.hasMatch(mobileBody), isTrue,
          reason: 'mobile controls theme must wire onSeekEnd to '
              'notifyExternalSeek (BUG-796 follow-up) — progress-bar drag '
              'affects touch too.');
    });
  });
}
