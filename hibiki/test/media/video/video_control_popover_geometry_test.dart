import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_control_popover_placement.dart';
import 'package:hibiki/src/media/video/video_volume_overlays.dart';

void main() {
  group('volume popover placement', () {
    const Rect player = Rect.fromLTWH(0, 0, 320, 180);

    test('bottom-left volume stays inside the player', () {
      final VideoControlPopoverPlacement placement =
          resolveVideoControlPopoverPlacement(
        playerBounds: player,
        targetRect: const Rect.fromLTWH(8, 140, 36, 36),
        preferredWidth: 220,
        sourceSlot: VideoControlSlot.bottomLeft,
      );

      expect(placement.left, greaterThanOrEqualTo(player.left));
      expect(placement.right, lessThanOrEqualTo(player.right));
      expect(placement.width, 220);
    });

    test('bottom-right volume stays inside the player', () {
      final VideoControlPopoverPlacement placement =
          resolveVideoControlPopoverPlacement(
        playerBounds: player,
        targetRect: const Rect.fromLTWH(276, 140, 36, 36),
        preferredWidth: 220,
        sourceSlot: VideoControlSlot.bottomRight,
      );

      expect(placement.left, greaterThanOrEqualTo(player.left));
      expect(placement.right, lessThanOrEqualTo(player.right));
      expect(placement.width, 220);
    });

    test('bottom-right volume can be an inner button and still clamp', () {
      final VideoControlPopoverPlacement placement =
          resolveVideoControlPopoverPlacement(
        playerBounds: player,
        targetRect: const Rect.fromLTWH(100, 140, 36, 36),
        preferredWidth: 220,
        sourceSlot: VideoControlSlot.bottomRight,
      );

      expect(placement.left, player.left);
      expect(placement.right, 220);
      expect(placement.width, 220);
    });

    test('oversized scaled volume popover shrinks to player width', () {
      final VideoControlPopoverPlacement placement =
          resolveVideoControlPopoverPlacement(
        playerBounds: player,
        targetRect: const Rect.fromLTWH(276, 140, 36, 36),
        preferredWidth: 520,
        sourceSlot: VideoControlSlot.bottomRight,
      );

      expect(placement.left, player.left);
      expect(placement.right, player.right);
      expect(placement.width, player.width);
    });

    test('video page render path uses measured target geometry helper', () {
      final String page = File(
        'lib/src/pages/implementations/video_hibiki_page.dart',
      ).readAsStringSync();

      expect(page, contains('resolveVideoControlPopoverPlacement('));
      expect(page, contains('_activeControlPopoverTargetRect('));
      expect(page, contains('_controlPopoverTargetKeyFor('));
      expect(page, contains('resolved.left -'));
    });
  });

  group('slot-adaptive popover direction (TODO-560)', () {
    test('bottom slots pop up, top slots pop down, side rails pop sideways',
        () {
      expect(
        videoControlPopoverDirectionForSlot(VideoControlSlot.bottomLeft),
        VideoControlPopoverDirection.up,
      );
      expect(
        videoControlPopoverDirectionForSlot(VideoControlSlot.bottomCenter),
        VideoControlPopoverDirection.up,
      );
      expect(
        videoControlPopoverDirectionForSlot(VideoControlSlot.bottomRight),
        VideoControlPopoverDirection.up,
      );
      expect(
        videoControlPopoverDirectionForSlot(VideoControlSlot.topLeft),
        VideoControlPopoverDirection.down,
      );
      expect(
        videoControlPopoverDirectionForSlot(VideoControlSlot.topCenter),
        VideoControlPopoverDirection.down,
      );
      expect(
        videoControlPopoverDirectionForSlot(VideoControlSlot.topRight),
        VideoControlPopoverDirection.down,
      );
      expect(
        videoControlPopoverDirectionForSlot(VideoControlSlot.screenLeft),
        VideoControlPopoverDirection.right,
      );
      expect(
        videoControlPopoverDirectionForSlot(VideoControlSlot.screenRight),
        VideoControlPopoverDirection.left,
      );
    });

    test('null / hidden slot falls back to popping up (no regression)', () {
      expect(
        videoControlPopoverDirectionForSlot(null),
        VideoControlPopoverDirection.up,
      );
      expect(
        videoControlPopoverDirectionForSlot(VideoControlSlot.hidden),
        VideoControlPopoverDirection.up,
      );
    });

    const Rect player = Rect.fromLTWH(0, 0, 320, 180);
    const double height = 56;

    test('bottom button: popover top sits ABOVE the button', () {
      final VideoControlPopoverPlacement placement =
          resolveVideoControlPopoverPlacement(
        playerBounds: player,
        targetRect: const Rect.fromLTWH(276, 140, 36, 36),
        preferredWidth: 220,
        sourceSlot: VideoControlSlot.bottomRight,
        height: height,
      );
      // Popover bottom edge (top + height) must clear the button top (140).
      expect(placement.top + height, lessThanOrEqualTo(140 + 0.001));
    });

    test('top button: popover top sits BELOW the button (not above)', () {
      const Rect target = Rect.fromLTWH(8, 4, 36, 36);
      final VideoControlPopoverPlacement placement =
          resolveVideoControlPopoverPlacement(
        playerBounds: player,
        targetRect: target,
        preferredWidth: 220,
        sourceSlot: VideoControlSlot.topLeft,
        height: height,
      );
      // The whole point of TODO-560: a top-bar button must NOT pop above.
      expect(placement.top, greaterThanOrEqualTo(target.bottom));
      expect(placement.left, greaterThanOrEqualTo(player.left));
      expect(placement.right, lessThanOrEqualTo(player.right));
    });

    test('left side rail: popover sits to the RIGHT of the button', () {
      const Rect target = Rect.fromLTWH(4, 70, 36, 36);
      final VideoControlPopoverPlacement placement =
          resolveVideoControlPopoverPlacement(
        playerBounds: player,
        targetRect: target,
        preferredWidth: 160,
        sourceSlot: VideoControlSlot.screenLeft,
        height: height,
      );
      expect(placement.left, greaterThanOrEqualTo(target.right));
      expect(placement.right, lessThanOrEqualTo(player.right));
    });

    test('right side rail: popover sits to the LEFT of the button', () {
      const Rect target = Rect.fromLTWH(280, 70, 36, 36);
      final VideoControlPopoverPlacement placement =
          resolveVideoControlPopoverPlacement(
        playerBounds: player,
        targetRect: target,
        preferredWidth: 160,
        sourceSlot: VideoControlSlot.screenRight,
        height: height,
      );
      expect(placement.right, lessThanOrEqualTo(target.left));
      expect(placement.left, greaterThanOrEqualTo(player.left));
    });

    test('top button popover stays inside the player vertically', () {
      final VideoControlPopoverPlacement placement =
          resolveVideoControlPopoverPlacement(
        playerBounds: player,
        targetRect: const Rect.fromLTWH(8, 4, 36, 36),
        preferredWidth: 220,
        sourceSlot: VideoControlSlot.topLeft,
        height: height,
      );
      expect(placement.top, greaterThanOrEqualTo(player.top));
      expect(placement.top + height, lessThanOrEqualTo(player.bottom + 0.001));
    });

    test(
        'speed popover render path is slot-adaptive: threads sourceSlot and '
        'uses gapDirection', () {
      final String page = File(
        'lib/src/pages/implementations/video_hibiki_page.dart',
      ).readAsStringSync();

      // The placement helper must derive direction from the slot for BOTH kinds
      // (no hardcoded "speed always pops up" branch).
      expect(page, contains('videoControlPopoverDirectionForSlot('));
      expect(page, contains('final Offset gapDirection;'));
      expect(page, contains('placement.gapDirection * gap'));
      expect(page, isNot(contains('offset: Offset(dx, -gap)')));

      // The speed click + hover paths must carry the slot so the popover can
      // follow the button into top / side slots.
      expect(
        page,
        contains(
          'void _showSpeedMenu({LayerLink? popoverLink, '
          'VideoControlSlot? sourceSlot})',
        ),
      );
      expect(
        page,
        contains('_showSpeedMenu(popoverLink: popoverLink, '
            'sourceSlot: sourceSlot)'),
      );
      // Horizontal clamp now also runs for the speed popover, not volume-only:
      // the resolve gate keys off sourceSlot/targetRect, not the popover kind.
      expect(page, contains('sourceSlot != null && targetRect != null'));
    });
  });

  group('visible volume overlays render compactly', () {
    const List<Size> viewports = <Size>[
      Size(360, 640),
      Size(1000, 700),
    ];
    const List<double> uiScales = <double>[1, 2];

    Future<void> setViewport(WidgetTester tester, Size viewport) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    for (final Size viewport in viewports) {
      for (final double uiScale in uiScales) {
        testWidgets(
          'volume popover frame and Slider stay compact at '
          '${viewport.width.toInt()}x${viewport.height.toInt()} scale $uiScale',
          (WidgetTester tester) async {
            await setViewport(tester, viewport);
            final double popoverWidth = math.min(220 * uiScale, viewport.width);
            const Key barrierKey = ValueKey<String>('volume-popover-barrier');

            await tester.pumpWidget(
              MaterialApp(
                home: Builder(
                  builder: (BuildContext context) {
                    final ColorScheme cs = Theme.of(context).colorScheme;
                    return Scaffold(
                      body: Stack(
                        children: <Widget>[
                          const Positioned.fill(
                            child: SizedBox.expand(key: barrierKey),
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: VideoVolumePopoverCard(
                              width: popoverWidth,
                              value: 42,
                              uiScale: uiScale,
                              colorScheme: cs,
                              icon: Icons.volume_up,
                              tooltip: 'Volume',
                              onToggleMute: () {},
                              onChanged: (_) {},
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            );

            final Size barrierSize = tester.getSize(find.byKey(barrierKey));
            expect(barrierSize.height, viewport.height);

            final Size frameSize =
                tester.getSize(find.byKey(videoVolumePopoverFrameKey));
            final Size sliderSize =
                tester.getSize(find.byKey(videoVolumePopoverSliderKey));
            expect(frameSize.width, closeTo(popoverWidth, 0.1));
            expect(frameSize.height, closeTo(56 * uiScale, 0.1));
            expect(frameSize.height, lessThan(viewport.height * 0.25),
                reason:
                    'measure the visible popover frame, not the full barrier');
            expect(sliderSize.height, lessThanOrEqualTo(40 * uiScale + 0.1));
            expect(sliderSize.height, lessThan(frameSize.height));
          },
        );

        testWidgets(
          'volume HUD card stays compact at '
          '${viewport.width.toInt()}x${viewport.height.toInt()} scale $uiScale',
          (WidgetTester tester) async {
            await setViewport(tester, viewport);
            const Key barrierKey = ValueKey<String>('volume-hud-barrier');

            await tester.pumpWidget(
              MaterialApp(
                home: Builder(
                  builder: (BuildContext context) {
                    final ColorScheme cs = Theme.of(context).colorScheme;
                    return Scaffold(
                      body: Stack(
                        children: <Widget>[
                          const Positioned.fill(
                            child: SizedBox.expand(key: barrierKey),
                          ),
                          VideoLevelHudCard(
                            value: 65,
                            uiScale: uiScale,
                            icon: Icons.volume_up,
                            alignment: Alignment.centerRight,
                            minimum: EdgeInsets.only(
                              left: 16,
                              top: 16,
                              right: 76 * uiScale,
                              bottom: 16,
                            ),
                            surfaceColor:
                                cs.inverseSurface.withValues(alpha: 0.82),
                            textColor: cs.onInverseSurface,
                            shadowColor: cs.shadow,
                            frameKey: videoVolumeHudFrameKey,
                            progressKey: videoVolumeHudProgressKey,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            );

            final Size barrierSize = tester.getSize(find.byKey(barrierKey));
            expect(barrierSize.height, viewport.height);

            final Size frameSize =
                tester.getSize(find.byKey(videoVolumeHudFrameKey));
            final Size progressSize =
                tester.getSize(find.byKey(videoVolumeHudProgressKey));
            expect(frameSize.height, greaterThan(40 * uiScale));
            expect(frameSize.height, lessThanOrEqualTo(72 * uiScale));
            expect(frameSize.height, lessThan(viewport.height * 0.25),
                reason: 'measure the visible HUD card, not the full barrier');
            expect(progressSize.height, closeTo(4 * uiScale, 0.1));
          },
        );
      }
    }
  });
}
