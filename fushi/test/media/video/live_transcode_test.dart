import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';

void main() {
  group('VideoTranscodeProfile', () {
    test('两项都缺 / 非法 → null（= 不转码，走原文件直传）', () {
      expect(VideoTranscodeProfile.fromQuery(const <String, String>{}), isNull);
      expect(
        VideoTranscodeProfile.fromQuery(const <String, String>{
          'maxWidth': 'abc',
          'maxBitrate': '',
        }),
        isNull,
      );
      expect(
        VideoTranscodeProfile.fromQuery(const <String, String>{
          'maxWidth': '0',
          'maxBitrate': '0',
        }),
        isNull,
      );
    });

    test('单给一项也成立（只限宽度 / 只限码率）', () {
      expect(
        VideoTranscodeProfile.fromQuery(const <String, String>{
          'maxWidth': '1280',
        }),
        const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
      );
      expect(
        VideoTranscodeProfile.fromQuery(const <String, String>{
          'maxBitrate': '3000000',
        }),
        const VideoTranscodeProfile(maxWidth: 0, maxBitrate: 3000000),
      );
    });

    test('query 往返', () {
      const VideoTranscodeProfile profile = VideoTranscodeProfile(
        maxWidth: 1280,
        maxBitrate: 3000000,
      );
      expect(VideoTranscodeProfile.fromQuery(profile.toQuery()), profile);
    });
  });

  group('分段划分', () {
    test('不满一段的尾巴也算一段', () {
      expect(transcodeSegmentCount(0), 0);
      expect(transcodeSegmentCount(1), 1);
      expect(transcodeSegmentCount(6000), 1);
      expect(transcodeSegmentCount(6001), 2);
      expect(transcodeSegmentCount(18000), 3);
    });

    test('末段按真实时长收尾，不越过片尾', () {
      final ({Duration start, Duration end}) last = transcodeSegmentRange(
        2,
        15500,
      );
      expect(last.start, const Duration(seconds: 12));
      expect(last.end, const Duration(milliseconds: 15500));
    });
  });

  group('HLS playlist', () {
    test('VOD 头 + 每段 EXTINF + ENDLIST，TS 分段没有 EXT-X-MAP', () {
      final String playlist = buildTranscodeHlsPlaylist(
        durationMs: 15500,
        segmentUri: (int i) => '$kTranscodeSegmentPathSuffix?token=T&n=$i',
      );
      final List<String> lines = playlist
          .trim()
          .split('\n')
          .map((String l) => l.trim())
          .toList();
      expect(lines.first, '#EXTM3U');
      expect(lines, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
      // BUG-2630：分段是自描述的 MPEG-TS，没有初始化段——有 MAP 就说明又回到了
      // fMP4（FFmpeg 6.1 客户端 seek 必坏，见 live_transcode.dart 文件头）。
      expect(lines.where((String l) => l.startsWith('#EXT-X-MAP')), isEmpty);
      expect(lines.last, '#EXT-X-ENDLIST');
      expect(
        lines
            .where((String l) => l.startsWith('$kTranscodeSegmentPathSuffix?'))
            .length,
        3,
      );
      // 末段 3.5 秒：EXTINF 必须是真实段长，播放器据此算总时长与 seek 落点。
      expect(lines, contains('#EXTINF:3.500000,'));
    });

    test('时长为 0 → 一个分段都不列（host 侧据此拒绝转码）', () {
      final String playlist = buildTranscodeHlsPlaylist(
        durationMs: 0,
        segmentUri: (int i) => 's$i',
      );
      expect(playlist, isNot(contains('#EXTINF')));
    });
  });

  group('ffmpeg 参数', () {
    test('-ss / -to 落在 -i 之前（输入 seek，别把跳过的部分也解码一遍）', () {
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(
          maxWidth: 1280,
          maxBitrate: 3000000,
        ),
        start: const Duration(seconds: 12),
        end: const Duration(seconds: 18),
      );
      expect(args.indexOf('-ss'), lessThan(args.indexOf('-i')));
      expect(args.indexOf('-to'), lessThan(args.indexOf('-i')));
      expect(args[args.indexOf('-ss') + 1], '12.000');
      expect(args[args.indexOf('-to') + 1], '18.000');
    });

    test('码率上限连带 maxrate/bufsize（单给 -b:v 箍不住瞬时码率）', () {
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 0, maxBitrate: 800000),
        start: Duration.zero,
        end: const Duration(seconds: 6),
      );
      expect(args[args.indexOf('-b:v') + 1], '800000');
      expect(args[args.indexOf('-maxrate') + 1], '800000');
      expect(args[args.indexOf('-bufsize') + 1], '1600000');
      expect(args, isNot(contains('-crf')));
      // 没给宽度上限就不该有 scale 滤镜（别白跑一遍缩放）。
      expect(args, isNot(contains('-vf')));
    });

    test('没有码率上限时走恒定质量', () {
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 854, maxBitrate: 0),
        start: Duration.zero,
        end: const Duration(seconds: 6),
      );
      expect(args, contains('-crf'));
      expect(args, isNot(contains('-b:v')));
    });

    test('scale 只缩不放、高度取偶（奇数边会被 libx264 直接拒绝）', () {
      expect(scaleFilterFor(1280), r'scale=min(1280\,iw):-2');
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
        start: Duration.zero,
        end: const Duration(seconds: 6),
      );
      expect(args[args.indexOf('-vf') + 1], r'scale=min(1280\,iw):-2');
    });

    test('字幕不进转码流；音轨可指定且越界不硬失败', () {
      final List<String> byDefault = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
        start: Duration.zero,
        end: const Duration(seconds: 6),
      );
      expect(byDefault, contains('-sn'));
      expect(byDefault, contains('0:a:0?'));
      final List<String> picked = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
        start: Duration.zero,
        end: const Duration(seconds: 6),
        audioStreamIndex: 2,
      );
      expect(picked, contains('0:a:2?'));
    });

    test('输出是 MPEG-TS 到 stdout，段内时间轴按 -output_ts_offset 平移（BUG-2630）', () {
      final List<String> args = buildTranscodeSegmentArgs(
        inputPath: '/v.mkv',
        profile: const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 0),
        start: const Duration(seconds: 12),
        end: const Duration(seconds: 18),
      );
      // fMP4（mp4 muxer 的 fragmented 模式）在 FFmpeg 6.1 客户端上 seek 必坏，
      // 见 live_transcode.dart 文件头；这里钉死不再出 mp4。
      expect(args[args.indexOf('-f') + 1], 'mpegts');
      expect(args, isNot(contains('-movflags')));
      expect(args[args.indexOf('-output_ts_offset') + 1], '12.000');
      expect(args.last, 'pipe:1');
    });
  });
}
