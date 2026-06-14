import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-364 source-scan guard: the vendored `media_kit_video` controls must keep
/// publishing their **real** `visible` into the host's `visibilityNotifier`.
///
/// Root cause: Hibiki renders its own subtitle overlay and dodges the bottom
/// controls bar. It used to keep a *separate* mirror of controls visibility with
/// its own timer, which drifted out of phase with each control State's private
/// `visible` + private `Timer` and made the subtitle dodge reverse direction
/// under concurrent input. The fix exposes a single source of truth: both theme
/// data classes gain an optional `visibilityNotifier`, and every control State
/// pushes its real `visible` into it after each mutation (`_publishVisibility()`).
/// Hibiki consumes that one notifier instead of duplicating the state machine.
///
/// This guards the *patch* — if a future re-vendor of media_kit_video drops the
/// `visibilityNotifier` field or stops publishing after a `visible` change, the
/// host mirror starts drifting again and the direction-reversal bug returns.
/// See `third_party/media_kit_video/PATCHES.md`.
void main() {
  // Tests run with CWD = `hibiki/`; vendored packages live at the workspace root.
  const String base =
      '../third_party/media_kit_video/lib/media_kit_video_controls/'
      'src/controls/';
  const String desktopPath = '${base}material_desktop.dart';
  const String mobilePath = '${base}material.dart';

  test('pubspec override points media_kit_video at the vendored fork', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExp override = RegExp(
      r'media_kit_video:\s*\n\s*path:\s*\.\./third_party/media_kit_video',
    );
    expect(override.hasMatch(pubspec), isTrue,
        reason:
            'dependency_overrides must point media_kit_video at the vendored '
            'fork, otherwise the visibilityNotifier patch (TODO-364) is lost and '
            'the subtitle dodge starts drifting again.');
  });

  for (final ({String label, String path, String themeClass}) target
      in <({String label, String path, String themeClass})>[
    (
      label: 'desktop',
      path: desktopPath,
      themeClass: 'MaterialDesktopVideoControlsThemeData',
    ),
    (
      label: 'mobile',
      path: mobilePath,
      themeClass: 'MaterialVideoControlsThemeData',
    ),
  ]) {
    group('${target.label} controls publish real visibility (TODO-364)', () {
      late String source;
      setUp(() => source = File(target.path).readAsStringSync());

      test('${target.themeClass} exposes a visibilityNotifier field', () {
        expect(
          source.contains('final ValueNotifier<bool>? visibilityNotifier;'),
          isTrue,
          reason:
              '${target.themeClass} must carry an optional visibilityNotifier '
              'so the host can read the single source of truth.',
        );
        // Constructor + copyWith must wire it through (else host injection is dropped).
        expect(source.contains('this.visibilityNotifier'), isTrue,
            reason: 'constructor must accept visibilityNotifier');
        expect(
          source.contains(
              'visibilityNotifier: visibilityNotifier ?? this.visibilityNotifier'),
          isTrue,
          reason: 'copyWith must carry visibilityNotifier through',
        );
      });

      test('a _publishVisibility() helper pushes the real `visible`', () {
        expect(source.contains('void _publishVisibility()'), isTrue,
            reason: 'control State must have a _publishVisibility() helper');
        // The helper writes the State's real `visible` into the injected notifier.
        final int fn = source.indexOf('void _publishVisibility()');
        final int end = source.indexOf('\n  }', fn);
        final String body = source.substring(fn, end);
        expect(body.contains('visibilityNotifier?.value = visible'), isTrue,
            reason: '_publishVisibility must push the real `visible` into the '
                'notifier (the single source of truth).');
      });

      test('every `visible = ...` mutation is followed by a publish', () {
        // Count direct visibility mutations and the publish calls; the publish
        // count must be at least the mutation count so no transition is silent.
        // (The mount-initial publish is via an addPostFrameCallback notifier
        // write, counted separately below.)
        final int mutations =
            RegExp(r'visible = (?:true|false);').allMatches(source).length;
        final int publishes = '_publishVisibility();'.allMatches(source).length;
        expect(publishes, greaterThanOrEqualTo(mutations),
            reason: 'each `visible = ...` change must be followed by '
                '_publishVisibility(); otherwise the host mirror drifts out of '
                'phase (TODO-364). mutations=$mutations publishes=$publishes');
        // The initial (mount) visibility is published too, deferred post-frame.
        expect(source.contains('addPostFrameCallback'), isTrue,
            reason: 'initial visibility must be published post-frame to avoid '
                're-entering host setState during mount.');
      });
    });
  }
}
