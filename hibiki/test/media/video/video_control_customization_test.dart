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

    test('legacy settingsOnly keeps a button off the player', () {
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

  group('VideoControlLayout index-aware moves', () {
    test('reorders one item within the same slot', () {
      final VideoControlLayout moved =
          VideoControlLayout.currentChrome.moveDraggedItem(
        const VideoControlDragData(
          item: VideoControlItem.nextCue,
          sourceSlot: VideoControlSlot.bottomCenter,
          sourceIndex: 3,
        ),
        VideoControlSlot.bottomCenter,
        targetIndex: 0,
      );

      expect(
        moved.itemsIn(VideoControlSlot.bottomCenter).take(5),
        <VideoControlItem>[
          VideoControlItem.nextCue,
          VideoControlItem.seekBackward,
          VideoControlItem.previousCue,
          VideoControlItem.playPause,
          VideoControlItem.seekForward,
        ],
      );
    });

    test('moves only the dragged copy across slots', () {
      final VideoControlLayout layout = VideoControlLayout.fromSlots(
        const <VideoControlSlot, List<VideoControlItem>>{
          VideoControlSlot.topRight: <VideoControlItem>[
            VideoControlItem.screenshot,
          ],
          VideoControlSlot.screenLeft: <VideoControlItem>[
            VideoControlItem.screenshot,
            VideoControlItem.settings,
          ],
        },
      );

      final VideoControlLayout moved = layout.moveDraggedItem(
        const VideoControlDragData(
          item: VideoControlItem.screenshot,
          sourceSlot: VideoControlSlot.screenLeft,
          sourceIndex: 0,
        ),
        VideoControlSlot.bottomLeft,
        targetIndex: 0,
      );

      expect(
        moved.itemsIn(VideoControlSlot.topRight),
        contains(VideoControlItem.screenshot),
        reason: 'Moving one copy must not delete another slot copy.',
      );
      expect(
        moved.itemsIn(VideoControlSlot.screenLeft),
        isNot(contains(VideoControlItem.screenshot)),
      );
      expect(
        moved.itemsIn(VideoControlSlot.bottomLeft).first,
        VideoControlItem.screenshot,
      );
    });
  });
}
