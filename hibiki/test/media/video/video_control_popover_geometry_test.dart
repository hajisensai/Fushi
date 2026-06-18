import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_control_popover_placement.dart';

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
}
