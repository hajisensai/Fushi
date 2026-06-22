import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/startup/desktop_window_placement.dart';

void main() {
  group('DesktopWindowPlacement', () {
    test('chooses a roomy centered default on large desktop work areas', () {
      final Rect bounds = DesktopWindowPlacement.resolveInitialBounds(
        workArea: const Rect.fromLTWH(0, 0, 2560, 1440),
      );

      expect(bounds.size, const Size(1440, 960));
      expect(bounds.left, 560);
      expect(bounds.top, 240);
    });

    test('keeps first-run defaults inside small work areas', () {
      final Rect bounds = DesktopWindowPlacement.resolveInitialBounds(
        workArea: const Rect.fromLTWH(0, 0, 800, 560),
      );

      // BUG-401: minimum window width relaxed 960 -> 480. The first-run
      // default is 82% of the work-area width (656 on an 800-wide screen);
      // previously the 960-wide minimum clamped that up to the full 800.
      // Height still fills the short 560 work area (86% = 481.6 floored by
      // the 560 effective minimum). The window stays centered horizontally.
      expect(bounds.size, const Size(656, 560));
      expect(bounds.left, 72);
      expect(bounds.top, 0);
    });

    test('restores the last size and clamps an off-screen position', () {
      final Rect bounds = DesktopWindowPlacement.resolveInitialBounds(
        workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
        savedBounds: const Rect.fromLTWH(5000, -900, 1600, 1000),
      );

      expect(bounds.size, const Size(1600, 1000));
      expect(bounds.left, 320);
      expect(bounds.top, 0);
    });

    test('expands too-small saved bounds to the effective minimum size', () {
      final Rect bounds = DesktopWindowPlacement.resolveInitialBounds(
        workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
        savedBounds: const Rect.fromLTWH(48, 56, 420, 320),
      );

      expect(bounds.size, DesktopWindowPlacement.minimumSize);
      expect(bounds.left, 48);
      expect(bounds.top, 56);
    });

    test('shrinks the effective minimum size when the work area is tiny', () {
      final Size minimum = DesktopWindowPlacement.minimumSizeForWorkArea(
        const Rect.fromLTWH(0, 0, 700, 500),
      );

      // BUG-401: minimum window width relaxed 960 -> 480. On a 700-wide work
      // area the effective minimum width is now the literal 480 (no longer
      // clamped up to the work-area width); the height is still shrunk to the
      // 500 work area (< the 640 minimum height).
      expect(minimum, const Size(480, 500));
    });

    test('selects the work area containing the current window center', () {
      final Rect selected = DesktopWindowPlacement.selectWorkArea(
        workAreas: const <Rect>[
          Rect.fromLTWH(0, 0, 1920, 1040),
          Rect.fromLTWH(1920, 0, 1440, 900),
        ],
        currentBounds: const Rect.fromLTWH(2200, 120, 1280, 720),
      );

      expect(selected, const Rect.fromLTWH(1920, 0, 1440, 900));
    });

    test('restores to secondary display when saved bounds are there', () {
      const Rect savedBounds = Rect.fromLTWH(2000, 80, 1200, 800);
      final Rect workArea = DesktopWindowPlacement.selectInitialWorkArea(
        workAreas: const <Rect>[
          Rect.fromLTWH(0, 0, 1920, 1040),
          Rect.fromLTWH(1920, 0, 1440, 900),
        ],
        savedBounds: savedBounds,
        currentBounds: const Rect.fromLTWH(10, 10, 1280, 720),
      );

      final Rect bounds = DesktopWindowPlacement.resolveInitialBounds(
        workArea: workArea,
        savedBounds: savedBounds,
      );

      expect(workArea, const Rect.fromLTWH(1920, 0, 1440, 900));
      expect(bounds, savedBounds);
    });
  });

  group('desktop startup wiring', () {
    test('main applies and saves desktop window placement', () {
      final String source = File('lib/main.dart').readAsStringSync();

      expect(
        source,
        contains(
          "import 'package:hibiki/src/startup/desktop_window_placement.dart';",
        ),
      );
      expect(
        source,
        contains('DesktopWindowPlacement.applyInitialPlacement()'),
      );
      expect(
        source,
        contains('DesktopWindowPlacement.rememberCurrentBounds()'),
      );
      expect(source, contains('void onWindowMoved()'));
      expect(source, contains('void onWindowResized()'));

      final int placementIndex = source.indexOf(
        'DesktopWindowPlacement.applyInitialPlacement()',
      );
      final int runAppIndex = source.indexOf('runApp(');
      expect(placementIndex, isNonNegative);
      expect(runAppIndex, isNonNegative);
      expect(
        placementIndex,
        lessThan(runAppIndex),
        reason: '窗口尺寸/位置必须在首个 Flutter frame 之前应用。',
      );
    });
  });
}
