import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';

void main() {
  test('defaults mirror asbplayer playback preferences', () {
    expect(VideoAsbplayerConfig.defaults.seekSeconds, 3);
    expect(VideoAsbplayerConfig.defaults.speedStep, 0.1);
    expect(VideoAsbplayerConfig.defaults.pauseAtSubtitleEnd, isFalse);
  });

  test('encode/decode round trips user playback preferences', () {
    const VideoAsbplayerConfig config = VideoAsbplayerConfig(
      seekSeconds: 5,
      speedStep: 0.2,
      pauseAtSubtitleEnd: true,
    );

    final VideoAsbplayerConfig decoded =
        VideoAsbplayerConfig.decode(VideoAsbplayerConfig.encode(config));

    expect(decoded.seekSeconds, 5);
    expect(decoded.speedStep, 0.2);
    expect(decoded.pauseAtSubtitleEnd, isTrue);
  });

  test('decode tolerates empty and clamps unsupported values', () {
    expect(VideoAsbplayerConfig.decode('').seekSeconds, 3);

    final VideoAsbplayerConfig decoded = VideoAsbplayerConfig.decode(
      '{"seekSeconds":0,"speedStep":2,"pauseAtSubtitleEnd":true}',
    );

    expect(decoded.seekSeconds, 1);
    expect(decoded.speedStep, 0.5);
    expect(decoded.pauseAtSubtitleEnd, isTrue);
  });
}
