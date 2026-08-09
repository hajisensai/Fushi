import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1243 follow-up guard (large-window integrated-GPU 100% / flicker).
///
/// The position-quantize patch (`media_kit_video_position_throttle_test.dart`)
/// cut the seek bar / `mm:ss` clock rebuild *frequency* to ~5fps, which fixed
/// the HD Graphics 620 GPU-100% flicker **in a small window** -- but the flicker
/// stayed maximized / fullscreen. Frequency is window-size-independent, so the
/// residual cost was the per-repaint *area*: the seek bar and clock are leaves
/// in the controls `Stack` that also holds the two full-video-area gradient
/// scrims, with no `RepaintBoundary` between them, so every ~5fps fill step
/// re-rasterises the **entire full-screen controls picture** (cost scales with
/// window size).
///
/// The fix wraps the seek bar and the position clock each in a
/// `RepaintBoundary`, capping their re-raster to their own thin bounds
/// regardless of window size. This guard fails if a re-vendor of
/// `media_kit_video` drops either boundary (the large-window flicker returns).
/// See `third_party/media_kit_video/PATCHES.md` (TODO-1243 follow-up).
void main() {
  // Tests run with CWD = `fushi/`; the vendored package lives at the workspace
  // root.
  const String desktopPath =
      '../third_party/media_kit_video/lib/media_kit_video_controls/'
      'src/controls/material_desktop.dart';
  const String mobilePath =
      '../third_party/media_kit_video/lib/media_kit_video_controls/'
      'src/controls/material.dart';

  /// Returns the brace-matched body (including the outer `{ ... }`) of the first
  /// `{` at or after [from] in [source].
  String braceMatchedBody(String source, int from) {
    final int open = source.indexOf('{', from);
    expect(open, isNonNegative, reason: 'expected a `{` at or after $from');
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      final String c = source[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces starting at $open');
  }

  /// Extracts the `build(BuildContext context)` method body of the State class
  /// named [stateClass] in [source].
  String buildBodyOf(String source, String stateClass) {
    final int cls = source.indexOf('class $stateClass');
    expect(cls, isNonNegative, reason: 'expected class $stateClass in source');
    final int build = source.indexOf('Widget build(BuildContext context)', cls);
    expect(build, isNonNegative, reason: 'expected a build() in $stateClass');
    return braceMatchedBody(source, build);
  }

  group('TODO-1243 follow-up: seek bar is RepaintBoundary-isolated', () {
    void expectSeekBarBoundary(String path, String stateClass, String label) {
      final String source = File(path).readAsStringSync();
      final String build = buildBodyOf(source, stateClass);
      // The seek bar `build` must hand its heavy body off through a
      // RepaintBoundary so its ~5fps fill re-raster does not re-record the
      // full-screen controls picture (the full-video-area gradient scrims it
      // shares a layer with).
      expect(
        build.contains('RepaintBoundary('),
        isTrue,
        reason: '$label seek bar build() must wrap its body in a '
            'RepaintBoundary (TODO-1243 follow-up), else maximized / '
            'fullscreen re-rasters the whole controls picture at ~5fps and the '
            'integrated-GPU 100% load / flicker returns.',
      );
      // The body Container (the actual seek bar tree) must live under the
      // boundary -- verify the boundary appears before the seek bar Container is
      // constructed (either inline or via the extracted helper).
      final int boundary = build.indexOf('RepaintBoundary(');
      final int helperOrContainer = build.contains('_buildSeekBarBody(')
          ? build.indexOf('_buildSeekBarBody(')
          : build.indexOf('Container(');
      expect(helperOrContainer, isNonNegative);
      expect(boundary, lessThan(helperOrContainer),
          reason: '$label RepaintBoundary must enclose the seek bar body');
    }

    test('desktop seek bar', () {
      expectSeekBarBoundary(
          desktopPath, 'MaterialDesktopSeekBarState', 'desktop');
    });

    test('mobile seek bar', () {
      expectSeekBarBoundary(mobilePath, 'MaterialSeekBarState', 'mobile');
    });
  });

  group('TODO-1243 follow-up: position clock is RepaintBoundary-isolated', () {
    void expectClockBoundary(String path, String stateClass, String label) {
      final String source = File(path).readAsStringSync();
      final String build = buildBodyOf(source, stateClass);
      expect(
        build.contains('RepaintBoundary('),
        isTrue,
        reason: '$label mm:ss clock build() must wrap its Text in a '
            'RepaintBoundary (TODO-1243 follow-up), so the second-boundary '
            'repaint does not re-raster the shared full-screen controls '
            'picture.',
      );
      final int boundary = build.indexOf('RepaintBoundary(');
      final int text = build.indexOf('Text(');
      expect(text, isNonNegative);
      expect(boundary, lessThan(text),
          reason: '$label RepaintBoundary must enclose the clock Text');
    }

    test('desktop position indicator', () {
      expectClockBoundary(
          desktopPath, 'MaterialDesktopPositionIndicatorState', 'desktop');
    });

    test('mobile position indicator', () {
      expectClockBoundary(
          mobilePath, 'MaterialPositionIndicatorState', 'mobile');
    });
  });

  test('both seek bars keep the position quantize AND the RepaintBoundary', () {
    // The two mitigations are complementary and must both survive a re-vendor:
    // the quantize bounds rebuild frequency (small-window fix), the boundary
    // bounds raster area (large-window fix). This cross-check fails if a
    // re-vendor keeps one but drops the other.
    for (final String path in <String>[desktopPath, mobilePath]) {
      final String source = File(path).readAsStringSync();
      expect(source.contains('floorTo(kPositionUiThrottleStep)'), isTrue,
          reason: 'position quantize (TODO-1243) must remain in $path');
      expect(
          source.contains('RepaintBoundary(child: _buildSeekBarBody('), isTrue,
          reason: 'seek bar RepaintBoundary (TODO-1243 follow-up) must remain '
              'in $path');
    }
  });
}
