import 'dart:ui' show Size;

import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_orientation_policy.dart';

/// 拍板台 P9AS-fvjJh：视频页方向策略与竖屏版式判据（纯函数）。
void main() {
  group('VideoEntryOrientation storage', () {
    test('round-trips the frozen storage values', () {
      for (final VideoEntryOrientation v in VideoEntryOrientation.values) {
        expect(VideoEntryOrientation.fromStorage(v.storageValue), v);
      }
      expect(VideoEntryOrientation.videoAspect.storageValue, 'video_aspect');
    });

    test('unknown / empty falls back to landscape (old users unchanged)', () {
      expect(
        VideoEntryOrientation.fromStorage(null),
        VideoEntryOrientation.landscape,
      );
      expect(
        VideoEntryOrientation.fromStorage(''),
        VideoEntryOrientation.landscape,
      );
      expect(
        VideoEntryOrientation.fromStorage('bogus'),
        VideoEntryOrientation.landscape,
      );
    });

    test('remembered orientation only accepts landscape / portrait', () {
      expect(
        VideoOrientationLock.fromRemembered('portrait'),
        VideoOrientationLock.portrait,
      );
      expect(
        VideoOrientationLock.fromRemembered('landscape'),
        VideoOrientationLock.landscape,
      );
      expect(VideoOrientationLock.fromRemembered('sensor'), isNull);
      expect(VideoOrientationLock.fromRemembered(''), isNull);
    });
  });

  group('resolveVideoOrientationLock', () {
    test('default entry is landscape regardless of the video', () {
      expect(
        resolveVideoOrientationLock(
          entry: VideoEntryOrientation.landscape,
          videoAspectRatio: 9 / 16,
        ),
        VideoOrientationLock.landscape,
      );
    });

    test('match-video picks portrait only for vertical videos', () {
      expect(
        resolveVideoOrientationLock(
          entry: VideoEntryOrientation.videoAspect,
          videoAspectRatio: 9 / 16,
        ),
        VideoOrientationLock.portrait,
      );
      expect(
        resolveVideoOrientationLock(
          entry: VideoEntryOrientation.videoAspect,
          videoAspectRatio: 16 / 9,
        ),
        VideoOrientationLock.landscape,
      );
      // 尺寸还没出来：先横屏。
      expect(
        resolveVideoOrientationLock(entry: VideoEntryOrientation.videoAspect),
        VideoOrientationLock.landscape,
      );
    });

    test('auto-rotate follows the sensor', () {
      expect(
        resolveVideoOrientationLock(entry: VideoEntryOrientation.sensor),
        VideoOrientationLock.sensor,
      );
    });

    test('an explicit override (rotate button / remembered) wins', () {
      expect(
        resolveVideoOrientationLock(
          entry: VideoEntryOrientation.sensor,
          override: VideoOrientationLock.portrait,
        ),
        VideoOrientationLock.portrait,
      );
      expect(
        resolveVideoOrientationLock(
          entry: VideoEntryOrientation.videoAspect,
          override: VideoOrientationLock.landscape,
          videoAspectRatio: 9 / 16,
        ),
        VideoOrientationLock.landscape,
      );
    });
  });

  group('videoDeviceOrientationsFor', () {
    test('never empty and never upside down (BUG-221)', () {
      for (final VideoOrientationLock lock in VideoOrientationLock.values) {
        final List<DeviceOrientation> set = videoDeviceOrientationsFor(lock);
        expect(set, isNotEmpty, reason: '$lock');
        expect(set, isNot(contains(DeviceOrientation.portraitDown)));
      }
    });

    test('maps each lock to its orientation set', () {
      expect(
        videoDeviceOrientationsFor(VideoOrientationLock.landscape),
        <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      );
      expect(
        videoDeviceOrientationsFor(VideoOrientationLock.portrait),
        <DeviceOrientation>[DeviceOrientation.portraitUp],
      );
      expect(
        videoDeviceOrientationsFor(VideoOrientationLock.sensor),
        containsAll(<DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    });

    test('rotate button flips by the actual screen shape', () {
      expect(
        videoOrientationToggleTarget(screenIsPortrait: true),
        VideoOrientationLock.landscape,
      );
      expect(
        videoOrientationToggleTarget(screenIsPortrait: false),
        VideoOrientationLock.portrait,
      );
    });
  });

  group('resolveVideoPortraitLayout', () {
    VideoPortraitLayoutKind layout({
      bool mobile = true,
      Size screen = const Size(390, 844),
      double? aspect = 16 / 9,
      bool showList = true,
      bool mini = false,
    }) => resolveVideoPortraitLayout(
      mobile: mobile,
      screen: screen,
      videoAspectRatio: aspect,
      showSubtitleList: showList,
      miniSurface: mini,
    );

    test('phone portrait with a landscape video stacks', () {
      expect(layout(), VideoPortraitLayoutKind.stacked);
      // 比例未知按横版处理。
      expect(layout(aspect: null), VideoPortraitLayoutKind.stacked);
    });

    test('tablet portrait (>= 600dp wide) splits left / right', () {
      expect(
        layout(screen: const Size(800, 1280)),
        VideoPortraitLayoutKind.split,
      );
    });

    test(
      'landscape, desktop, mini window, vertical video, list off → none',
      () {
        expect(
          layout(screen: const Size(844, 390)),
          VideoPortraitLayoutKind.none,
        );
        expect(layout(mobile: false), VideoPortraitLayoutKind.none);
        expect(layout(mini: true), VideoPortraitLayoutKind.none);
        expect(layout(aspect: 9 / 16), VideoPortraitLayoutKind.none);
        expect(layout(showList: false), VideoPortraitLayoutKind.none);
      },
    );
  });

  group('portrait geometry', () {
    test('strip follows the video aspect, clamped and capped', () {
      expect(
        videoPortraitStripHeight(width: 390, availableHeight: 844),
        closeTo(390 * 9 / 16, 0.01),
      );
      // 超宽片夹到 2.4:1。
      expect(
        videoPortraitStripHeight(
          width: 390,
          availableHeight: 844,
          videoAspectRatio: 4,
        ),
        closeTo(390 / 2.4, 0.01),
      );
      // 不超过可用高度的 45%。
      expect(
        videoPortraitStripHeight(
          width: 390,
          availableHeight: 500,
          videoAspectRatio: 1,
        ),
        closeTo(225, 0.01),
      );
    });

    test(
      'video bottom includes the top inset and matches the split column',
      () {
        const Size phone = Size(390, 844);
        expect(
          videoPortraitVideoBottom(
            kind: VideoPortraitLayoutKind.stacked,
            screen: phone,
            topInset: 24,
          ),
          closeTo(24 + 390 * 9 / 16, 0.01),
        );
        const Size tablet = Size(800, 1280);
        final double column = 800 - videoPortraitSplitPaneWidth(800);
        expect(
          videoPortraitVideoBottom(
            kind: VideoPortraitLayoutKind.split,
            screen: tablet,
            topInset: 0,
          ),
          closeTo(column * 9 / 16, 0.01),
        );
        expect(
          videoPortraitVideoBottom(
            kind: VideoPortraitLayoutKind.none,
            screen: phone,
            topInset: 24,
          ),
          0,
        );
      },
    );

    test('lookup sheet: half screen collapsed, video bottom expanded', () {
      const Size phone = Size(390, 844);
      expect(
        videoPortraitLookupSheetHeight(
          screen: phone,
          videoBottom: 240,
          expanded: false,
        ),
        422,
      );
      expect(
        videoPortraitLookupSheetHeight(
          screen: phone,
          videoBottom: 240,
          expanded: true,
        ),
        604,
      );
      // 视频条比半屏还高时，收起态也不盖住视频。
      expect(
        videoPortraitLookupSheetHeight(
          screen: phone,
          videoBottom: 500,
          expanded: false,
        ),
        344,
      );
    });
  });
}
