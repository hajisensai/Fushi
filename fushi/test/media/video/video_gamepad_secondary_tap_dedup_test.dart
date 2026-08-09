import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';

void main() {
  group('VideoGamepadSecondaryTapDeduper (BUG-1453)', () {
    test('settle delay covers one 60ms desktop poll tick', () {
      expect(
        VideoGamepadSecondaryTapDeduper.settleDelay,
        greaterThan(const Duration(milliseconds: 60)),
      );
      expect(
        VideoGamepadSecondaryTapDeduper.settleDelay,
        lessThanOrEqualTo(
          VideoGamepadSecondaryTapDeduper.coincidenceWindow,
        ),
      );
    });

    test('allows an ordinary mouse secondary tap', () {
      final VideoGamepadSecondaryTapDeduper deduper =
          VideoGamepadSecondaryTapDeduper();

      expect(
        deduper.shouldSuppressSecondaryTap(const Duration(seconds: 1)),
        isFalse,
      );
    });

    test('suppresses controller-first synthetic right-click', () {
      final VideoGamepadSecondaryTapDeduper deduper =
          VideoGamepadSecondaryTapDeduper()
            ..recordGamepadPress(const Duration(milliseconds: 1000));

      expect(
        deduper.shouldSuppressSecondaryTap(
          const Duration(milliseconds: 1060),
        ),
        isTrue,
      );
    });

    test('suppresses pointer-first synthetic right-click after poll tick', () {
      final VideoGamepadSecondaryTapDeduper deduper =
          VideoGamepadSecondaryTapDeduper()
            ..recordGamepadPress(const Duration(milliseconds: 1060));

      expect(
        deduper.shouldSuppressSecondaryTap(
          const Duration(milliseconds: 1000),
        ),
        isTrue,
      );
    });

    test('does not suppress a later independent mouse right-click', () {
      final VideoGamepadSecondaryTapDeduper deduper =
          VideoGamepadSecondaryTapDeduper()
            ..recordGamepadPress(const Duration(milliseconds: 1000));

      expect(
        deduper.shouldSuppressSecondaryTap(
          const Duration(milliseconds: 1201),
        ),
        isFalse,
      );
    });

    test('coincidence boundary is inclusive', () {
      final VideoGamepadSecondaryTapDeduper deduper =
          VideoGamepadSecondaryTapDeduper()
            ..recordGamepadPress(const Duration(milliseconds: 1000));

      expect(
        deduper.shouldSuppressSecondaryTap(
          const Duration(milliseconds: 1120),
        ),
        isTrue,
      );
    });
  });
}
