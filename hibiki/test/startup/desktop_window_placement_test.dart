import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/startup/desktop_window_placement.dart';

void main() {
  group('DesktopWindowPlacement', () {
    test('TODO-1377: minimum window size is the phone-class 360x480 floor', () {
      // 用户「窗口不能再缩小了」：下限从 480x640 放宽到 360x480（普通手机宽度级，
      // 全表面已在 min_window_size_surfaces_itest 离屏真 app 验证无溢出）。
      // 别随手抬高：宽度 >=480 会让词典 dialog 的 compact 分支在桌面不可达。
      expect(DesktopWindowPlacement.minimumSize, const Size(360, 480));
    });

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

      // BUG-401 relaxed the minimum width 960 -> 480; TODO-1377 relaxes the
      // minimum to 360x480. The first-run default is 82% of the work-area
      // width (656 on an 800-wide screen) and 86% of its height (481.6 on a
      // 560-tall screen; no longer clamped up by the old 640 minimum height).
      // The window stays centered in both axes.
      // closeTo：Rect.fromLTWH 内部存 LTRB，size.height = (top+height)-top
      // 会重引入 1ulp 级浮点差，不能用精确相等。
      expect(bounds.size.width, closeTo(800 * 0.82, 1e-9));
      expect(bounds.size.height, closeTo(560 * 0.86, 1e-9));
      expect(bounds.left, closeTo(72, 1e-9));
      expect(bounds.top, closeTo((560 - 560 * 0.86) / 2, 1e-9));
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
        savedBounds: const Rect.fromLTWH(48, 56, 320, 300),
      );

      expect(bounds.size, DesktopWindowPlacement.minimumSize);
      expect(bounds.left, 48);
      expect(bounds.top, 56);
    });

    test('shrinks the effective minimum size when the work area is tiny', () {
      final Size minimum = DesktopWindowPlacement.minimumSizeForWorkArea(
        const Rect.fromLTWH(0, 0, 320, 400),
      );

      // TODO-1377: the minimum window size is 360x480. On a work area smaller
      // than that in both axes the effective minimum shrinks to the work area
      // so the window always fits the screen.
      expect(minimum, const Size(320, 400));
    });

    test('keeps the literal minimum on work areas larger than it', () {
      final Size minimum = DesktopWindowPlacement.minimumSizeForWorkArea(
        const Rect.fromLTWH(0, 0, 700, 500),
      );

      // Both axes exceed the 360x480 minimum, so nothing shrinks.
      expect(minimum, DesktopWindowPlacement.minimumSize);
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
