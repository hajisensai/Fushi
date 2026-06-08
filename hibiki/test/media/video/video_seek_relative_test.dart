import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';

void main() {
  group('clampSeekTargetMs (±10s transport)', () {
    test('forward within bounds', () {
      expect(
          VideoPlayerController.clampSeekTargetMs(5000, 10000, 60000), 15000);
    });

    test('backward clamps to 0', () {
      expect(VideoPlayerController.clampSeekTargetMs(3000, -10000, 60000), 0);
    });

    test('forward clamps to duration', () {
      expect(
          VideoPlayerController.clampSeekTargetMs(58000, 10000, 60000), 60000);
    });

    test('unknown duration only guards lower bound', () {
      expect(
          VideoPlayerController.clampSeekTargetMs(58000, 10000, null), 68000);
      expect(VideoPlayerController.clampSeekTargetMs(1000, -10000, null), 0);
    });

    test('zero duration treated as unknown (no upper clamp)', () {
      expect(VideoPlayerController.clampSeekTargetMs(1000, 10000, 0), 11000);
    });
  });
}
