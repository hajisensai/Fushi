import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// B 守卫：视频制卡封面改成「cue 时间段的循环 GIF」。验证纯参数构造（时长 clamp、
/// 起点非负、调色板双遍滤镜、-loop 0、-ss/-t 在 -i 前快速定位）。
void main() {
  group('buildFfmpegClipGifArgs', () {
    test('builds palette gif with fast input seek + infinite loop', () {
      final args = buildFfmpegClipGifArgs(
        inputPath: '/v/ep04.mkv',
        startMs: 1000,
        endMs: 3000,
        outputPath: '/tmp/clip.gif',
      );
      // -ss/-t 在 -i 前（快速输入定位）。
      expect(args.indexOf('-ss') < args.indexOf('-i'), isTrue);
      expect(args.indexOf('-t') < args.indexOf('-i'), isTrue);
      expect(args[args.indexOf('-ss') + 1], '1.000');
      expect(args[args.indexOf('-t') + 1], '2.000');
      expect(args.contains('-an'), isTrue);
      // 调色板双遍（高质量、避免抖动）+ 无限循环。
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains('palettegen'));
      expect(filter, contains('paletteuse'));
      // TODO-646 近无损压缩：cue 封面动图收紧到 320px / 8fps（原 480 / 12）。
      expect(filter, contains('fps=8'));
      expect(filter, contains('scale=320:-2'));
      expect(args[args.indexOf('-loop') + 1], '0');
      expect(args.last, '/tmp/clip.gif');
    });

    test('clamps duration to maxDurationMs for long cues', () {
      final args = buildFfmpegClipGifArgs(
        inputPath: '/v/ep.mkv',
        startMs: 0,
        endMs: 60000, // 60s cue
        outputPath: '/tmp/c.gif',
        maxDurationMs: 10000,
      );
      expect(args[args.indexOf('-t') + 1], '10.000');
    });

    test('clamps negative start to 0', () {
      final args = buildFfmpegClipGifArgs(
        inputPath: '/v/ep.mkv',
        startMs: -500,
        endMs: 1500,
        outputPath: '/tmp/c.gif',
      );
      expect(args[args.indexOf('-ss') + 1], '0.000');
    });
  });
}
