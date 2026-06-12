import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';

void main() {
  test('defaults mirror asbplayer playback preferences', () {
    expect(VideoAsbplayerConfig.defaults.seekSeconds, 3);
    expect(VideoAsbplayerConfig.defaults.speedStep, 0.1);
    expect(VideoAsbplayerConfig.defaults.pauseAtSubtitleEnd, isFalse);
    // TODO-173/BUG-231: 双击行为默认 0=关（向后兼容，双击仍走暂停/全屏，不分区）。
    expect(VideoAsbplayerConfig.defaults.doubleTapSeekSeconds, 0);
  });

  test('encode/decode round trips user playback preferences', () {
    const VideoAsbplayerConfig config = VideoAsbplayerConfig(
      seekSeconds: 5,
      speedStep: 0.2,
      pauseAtSubtitleEnd: true,
      doubleTapSeekSeconds: 10,
    );

    final VideoAsbplayerConfig decoded =
        VideoAsbplayerConfig.decode(VideoAsbplayerConfig.encode(config));

    expect(decoded.seekSeconds, 5);
    expect(decoded.speedStep, 0.2);
    expect(decoded.pauseAtSubtitleEnd, isTrue);
    expect(decoded.doubleTapSeekSeconds, 10);
  });

  test('decode tolerates empty and clamps unsupported values', () {
    expect(VideoAsbplayerConfig.decode('').seekSeconds, 3);

    final VideoAsbplayerConfig decoded = VideoAsbplayerConfig.decode(
      '{"seekSeconds":0,"speedStep":2,"pauseAtSubtitleEnd":true}',
    );

    expect(decoded.seekSeconds, 1);
    expect(decoded.speedStep, 0.5);
    expect(decoded.pauseAtSubtitleEnd, isTrue);
    // 旧档无 doubleTapSeekSeconds 键 → 回默认 0=关。
    expect(decoded.doubleTapSeekSeconds, 0);
  });

  group('doubleTapSeekSeconds (TODO-173/BUG-231)', () {
    test('copyWith carries the double-tap behavior', () {
      final VideoAsbplayerConfig next =
          VideoAsbplayerConfig.defaults.copyWith(doubleTapSeekSeconds: 5);
      expect(next.doubleTapSeekSeconds, 5);
      // 其它字段不受影响。
      expect(next.seekSeconds, VideoAsbplayerConfig.defaults.seekSeconds);
      expect(next.speedStep, VideoAsbplayerConfig.defaults.speedStep);
    });

    test('subtitle-jump sentinel round trips', () {
      final VideoAsbplayerConfig config =
          VideoAsbplayerConfig.defaults.copyWith(
        doubleTapSeekSeconds: VideoAsbplayerConfig.kDoubleTapSubtitle,
      );
      final VideoAsbplayerConfig decoded =
          VideoAsbplayerConfig.decode(VideoAsbplayerConfig.encode(config));
      expect(decoded.doubleTapSeekSeconds,
          VideoAsbplayerConfig.kDoubleTapSubtitle);
      expect(VideoAsbplayerConfig.kDoubleTapSubtitle, -1);
    });

    test('every option value survives encode/decode', () {
      for (final int v in VideoAsbplayerConfig.doubleTapSeekOptions) {
        final VideoAsbplayerConfig decoded = VideoAsbplayerConfig.decode(
          VideoAsbplayerConfig.encode(
            VideoAsbplayerConfig.defaults.copyWith(doubleTapSeekSeconds: v),
          ),
        );
        expect(decoded.doubleTapSeekSeconds, v, reason: 'option $v 应往返不变');
      }
    });

    test('decode rejects out-of-whitelist values back to default', () {
      // 非白名单值（脏持久化 / 旧档异常值）兜底回默认 0，不进手势分流逻辑。
      for (final String raw in <String>[
        '{"doubleTapSeekSeconds":4}',
        '{"doubleTapSeekSeconds":-5}',
        '{"doubleTapSeekSeconds":99}',
        '{"doubleTapSeekSeconds":"5"}',
      ]) {
        expect(VideoAsbplayerConfig.decode(raw).doubleTapSeekSeconds, 0,
            reason: '非法值 $raw 应兜底回 0=关');
      }
    });

    test('option whitelist is the expected discrete set', () {
      expect(
        VideoAsbplayerConfig.doubleTapSeekOptions,
        containsAll(
            <int>[VideoAsbplayerConfig.kDoubleTapSubtitle, 0, 3, 5, 10]),
      );
      expect(VideoAsbplayerConfig.doubleTapSeekOptions.length, 5);
    });
  });
}
