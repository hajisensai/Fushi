import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';

void main() {
  group('VideoControlCustomization', () {
    test('defaults put speed in the bottom bar and subtitles on the right rail',
        () {
      const VideoControlCustomization customization =
          VideoControlCustomization.defaults;

      expect(
        customization.placementFor(VideoControlButton.speed),
        VideoControlPlacement.bottom,
      );
      expect(
        customization.placementFor(VideoControlButton.subtitleList),
        VideoControlPlacement.rightRail,
      );
      expect(customization.isOnPlayer(VideoControlButton.speed), isTrue);
      expect(
        customization.isOnPlayer(VideoControlButton.subtitleList),
        isTrue,
      );
    });

    test('moving a button to settings keeps a settings fallback', () {
      final VideoControlCustomization customization =
          VideoControlCustomization.defaults.copyWithPlacement(
        VideoControlButton.speed,
        VideoControlPlacement.settingsOnly,
      );

      expect(customization.isOnPlayer(VideoControlButton.speed), isFalse);
      expect(
        customization.settingsFallbackButtons,
        contains(VideoControlButton.speed),
      );
      expect(
        customization.buttonsFor(VideoControlPlacement.bottom),
        isNot(contains(VideoControlButton.speed)),
      );
    });

    test('buttons can move between bottom and right rail without duplication',
        () {
      final VideoControlCustomization customization =
          VideoControlCustomization.defaults.copyWithPlacement(
        VideoControlButton.speed,
        VideoControlPlacement.rightRail,
      );

      expect(
        customization.buttonsFor(VideoControlPlacement.rightRail),
        contains(VideoControlButton.speed),
      );
      expect(
        customization.buttonsFor(VideoControlPlacement.bottom),
        isNot(contains(VideoControlButton.speed)),
      );
    });

    test('encodes and decodes storage without losing placements', () {
      final VideoControlCustomization customization =
          VideoControlCustomization.defaults
              .copyWithPlacement(
                VideoControlButton.speed,
                VideoControlPlacement.rightRail,
              )
              .copyWithPlacement(
                VideoControlButton.subtitleList,
                VideoControlPlacement.settingsOnly,
              );

      final String encoded = customization.encode();
      final VideoControlCustomization decoded =
          VideoControlCustomization.decode(encoded);

      expect(
        decoded.placementFor(VideoControlButton.speed),
        VideoControlPlacement.rightRail,
      );
      expect(
        decoded.placementFor(VideoControlButton.subtitleList),
        VideoControlPlacement.settingsOnly,
      );
    });

    test('bad storage falls back to defaults', () {
      expect(
        VideoControlCustomization.decode('{not json}'),
        VideoControlCustomization.defaults,
      );
      expect(
        VideoControlCustomization.decode(''),
        VideoControlCustomization.defaults,
      );
    });
  });
}
