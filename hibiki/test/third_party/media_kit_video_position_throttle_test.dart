import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// The quantize helper lives in the vendored media_kit_video controls. Importing
// the src file directly exercises the real code (it lives under the package
// `lib/`, so it is reachable even though it is not re-exported).
import 'package:media_kit_video/media_kit_video_controls/src/controls/extensions/duration.dart';

/// TODO-1243 guard: the vendored `media_kit_video` controls must keep quantizing
/// the displayed playback position, so the seek bar + `mm:ss` clock rebuild at
/// ~5fps instead of the libmpv frame rate (~60fps). Without it the
/// integrated-GPU (`gpu0`) raster thread pins at 100% while the controls overlay
/// is visible (TODO-1119/1201/1203 family). See `third_party/media_kit_video/
/// PATCHES.md` (TODO-1243).
void main() {
  group('DurationExtension.floorTo (TODO-1243 quantize)', () {
    test('floors down to the nearest multiple of step', () {
      expect(
        const Duration(milliseconds: 1150).floorTo(kPositionUiThrottleStep),
        const Duration(milliseconds: 1000),
      );
      expect(
        const Duration(milliseconds: 1990).floorTo(kPositionUiThrottleStep),
        const Duration(milliseconds: 1800),
      );
      expect(
        const Duration(milliseconds: 2000).floorTo(kPositionUiThrottleStep),
        const Duration(milliseconds: 2000),
      );
      expect(
        Duration.zero.floorTo(kPositionUiThrottleStep),
        Duration.zero,
      );
    });

    test('non-positive step returns the value unchanged (no quantization)', () {
      const Duration v = Duration(milliseconds: 1234);
      expect(v.floorTo(Duration.zero), v);
      expect(v.floorTo(const Duration(milliseconds: -5)), v);
    });

    test('step is 200ms — 5fps, and divides 1000ms evenly', () {
      expect(kPositionUiThrottleStep, const Duration(milliseconds: 200));
      expect(1000 % kPositionUiThrottleStep.inMilliseconds, 0);
    });

    test(
        'quantizing never changes the whole-second value shown by the '
        'mm:ss clock', () {
      // Because the step divides 1000ms, flooring always stays inside the same
      // second — so `Duration.label` (second granularity) is byte-identical.
      for (int ms = 0; ms <= 5000; ms += 37) {
        final Duration raw = Duration(milliseconds: ms);
        expect(
          raw.floorTo(kPositionUiThrottleStep).inSeconds,
          raw.inSeconds,
          reason: 'floorTo must not cross a second boundary at ${ms}ms',
        );
      }
    });

    test(
        'quantizing collapses a frame-rate position stream to <=5 distinct '
        'values per second', () {
      // Simulate ~60fps position emits across one second; the controls only
      // rebuild when the quantized value changes.
      final Set<Duration> distinct = <Duration>{};
      for (int frame = 0; frame < 60; frame++) {
        final Duration pos = Duration(milliseconds: (frame * 1000) ~/ 60);
        distinct.add(pos.floorTo(kPositionUiThrottleStep));
      }
      expect(distinct.length, lessThanOrEqualTo(5));
    });
  });

  group('TODO-1243 source guards: controls quantize position before setState',
      () {
    // Tests run with CWD = `hibiki/`; vendored packages live at the workspace
    // root.
    const String extPath =
        '../third_party/media_kit_video/lib/media_kit_video_controls/'
        'src/controls/extensions/duration.dart';
    const String desktopPath =
        '../third_party/media_kit_video/lib/media_kit_video_controls/'
        'src/controls/material_desktop.dart';
    const String mobilePath =
        '../third_party/media_kit_video/lib/media_kit_video_controls/'
        'src/controls/material.dart';

    test('extension file declares the step const and floorTo', () {
      final String ext = File(extPath).readAsStringSync();
      expect(
        ext.contains(
            RegExp(r'const Duration kPositionUiThrottleStep\s*=\s*Duration\('
                r'milliseconds:\s*200\)')),
        isTrue,
        reason: 'kPositionUiThrottleStep (200ms) must survive re-vendor '
            '(TODO-1243).',
      );
      expect(
        ext.contains(RegExp(r'Duration floorTo\(Duration step\)')),
        isTrue,
        reason: 'DurationExtension.floorTo must survive re-vendor (TODO-1243).',
      );
    });

    /// Returns the `.listen((event) { ... })` body attached to the first
    /// `player.stream.position` occurrence at or after [from], by brace
    /// matching from the callback's opening `{`.
    String positionListenerBody(String source, int from) {
      final int at = source.indexOf('player.stream.position.listen', from);
      expect(at, isNonNegative,
          reason:
              'expected a player.stream.position.listen after offset $from');
      final int open = source.indexOf('{', at);
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
      fail('unbalanced braces in position listener body');
    }

    void expectQuantized(String path, String label) {
      final String source = File(path).readAsStringSync();
      int from = 0;
      int found = 0;
      while (true) {
        final int at = source.indexOf('player.stream.position.listen', from);
        if (at < 0) break;
        found++;
        final String body = positionListenerBody(source, at);
        expect(
          body.contains('floorTo(kPositionUiThrottleStep)'),
          isTrue,
          reason: '$label position listener #$found must quantize via '
              'floorTo(kPositionUiThrottleStep) (TODO-1243), else the ~60fps '
              'controls rebuild / integrated-GPU 100% load returns.',
        );
        expect(
          body.contains(
              RegExp(r'if\s*\(\s*next\s*==\s*position\s*\)\s*return')),
          isTrue,
          reason: '$label position listener #$found must skip setState when '
              'the quantized value is unchanged (TODO-1243).',
        );
        from = at + 1;
      }
      expect(found, greaterThanOrEqualTo(2),
          reason: '$label should have both a seek bar and a position-indicator '
              'position listener');
    }

    test('desktop controls quantize both position listeners', () {
      expectQuantized(desktopPath, 'desktop');
    });

    test('mobile controls quantize both position listeners', () {
      expectQuantized(mobilePath, 'mobile');
    });
  });
}
