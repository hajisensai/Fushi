import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_asbplayer_config.dart';
import 'package:fushi/src/media/video/video_horizontal_seek_gesture.dart';

void main() {
  test('defaults mirror asbplayer playback preferences', () {
    expect(VideoAsbplayerConfig.defaults.seekSeconds, 3);
    expect(VideoAsbplayerConfig.defaults.speedStep, 0.1);
    expect(VideoAsbplayerConfig.defaults.pauseAtSubtitleEnd, isFalse);
    expect(VideoAsbplayerConfig.defaults.longPressSpeed, 2.0);
    // TODO-173/BUG-231: 双击行为默认 0=关（向后兼容，双击仍走暂停/全屏，不分区）。
    expect(VideoAsbplayerConfig.defaults.doubleTapSeekSeconds, 0);
    // BUG-1485: 横滑 seek 默认中档（拖过整屏 ≈ 90 秒），比旧的比例制钝一个数量级。
    expect(
      VideoAsbplayerConfig.defaults.dragSeekSensitivity,
      VideoSeekSensitivity.medium,
    );
  });

  test('encode/decode round trips user playback preferences', () {
    const VideoAsbplayerConfig config = VideoAsbplayerConfig(
      seekSeconds: 5,
      speedStep: 0.2,
      pauseAtSubtitleEnd: true,
      doubleTapSeekSeconds: 10,
      longPressSpeed: 2.5,
      dragSeekSensitivity: VideoSeekSensitivity.low,
    );

    final VideoAsbplayerConfig decoded =
        VideoAsbplayerConfig.decode(VideoAsbplayerConfig.encode(config));

    expect(decoded.seekSeconds, 5);
    expect(decoded.speedStep, 0.2);
    expect(decoded.pauseAtSubtitleEnd, isTrue);
    expect(decoded.doubleTapSeekSeconds, 10);
    expect(decoded.longPressSpeed, 2.5);
    expect(decoded.dragSeekSensitivity, VideoSeekSensitivity.low);
  });

  test('BUG-1485: 旧档（无 dragSeekSensitivity 键）与脏值都回落默认档', () {
    // 升级前写下的配置里没有这个键——不得抛、不得变成别的档。
    expect(
      VideoAsbplayerConfig.decode(
        '{"seekSeconds":5,"speedStep":0.2,"pauseAtSubtitleEnd":false}',
      ).dragSeekSensitivity,
      VideoSeekSensitivity.medium,
    );
    // 脏值：类型不对（数字，例如误存了枚举 index）/ 不认识的档名。
    expect(
      VideoAsbplayerConfig.decode('{"dragSeekSensitivity":2}')
          .dragSeekSensitivity,
      VideoSeekSensitivity.medium,
    );
    expect(
      VideoAsbplayerConfig.decode('{"dragSeekSensitivity":"turbo"}')
          .dragSeekSensitivity,
      VideoSeekSensitivity.medium,
    );
    // 存的是枚举 name 而非 index，改枚举顺序不串档。
    expect(
      VideoAsbplayerConfig.encode(
        VideoAsbplayerConfig.defaults
            .copyWith(dragSeekSensitivity: VideoSeekSensitivity.high),
      ),
      contains('"dragSeekSensitivity":"high"'),
    );
  });

  test('decode tolerates empty and clamps unsupported values', () {
    expect(VideoAsbplayerConfig.decode('').seekSeconds, 3);

    final VideoAsbplayerConfig decoded = VideoAsbplayerConfig.decode(
      '{"seekSeconds":0,"speedStep":2,"pauseAtSubtitleEnd":true}',
    );

    expect(decoded.seekSeconds, 1);
    expect(decoded.speedStep, 0.5);
    expect(decoded.pauseAtSubtitleEnd, isTrue);
    expect(decoded.longPressSpeed, 2.0);
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
