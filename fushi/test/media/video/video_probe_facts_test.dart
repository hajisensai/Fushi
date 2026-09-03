import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/media/video/video_dynamic_range.dart';

/// ffprobe JSON 的解析。
///
/// 下面每一段 JSON 都是**捆绑的 ffprobe n7.1.5 真跑出来的原样输出**（样本用 ffmpeg
/// 现造：多音轨多字幕的 mkv、写了 HDR10 VUI 的 HEVC、以及没写任何色彩标签的对照），
/// 不是照着文档手写的。这很重要——手写 fixture 会把「ffprobe 到底给不给这个字段」
/// 这类关键事实猜错，而恰恰是这些缺字段决定了解析器要怎么兜底。
void main() {
  group('完整形态 mkv（3 音轨 + 2 字幕轨）', () {
    // 真实输出：1920x1080 h264 / flac 5.1 jpn(default) / aac 2.0 eng /
    // aac 2.0 eng(comment) / subrip chi(default) / subrip jpn(forced)
    const String json = '''
{
    "streams": [
        {
            "index": 0, "codec_name": "h264", "codec_type": "video",
            "width": 1920, "height": 1080, "pix_fmt": "yuv420p",
            "r_frame_rate": "24/1", "bits_per_raw_sample": "8",
            "disposition": { "default": 0, "comment": 0, "forced": 0 },
            "tags": { }
        },
        {
            "index": 1, "codec_name": "flac", "codec_type": "audio",
            "sample_rate": "44100", "channels": 6, "channel_layout": "5.1",
            "r_frame_rate": "0/0", "bits_per_raw_sample": "16",
            "disposition": { "default": 1, "comment": 0, "forced": 0 },
            "tags": { "language": "jpn", "title": "Japanese 5.1" }
        },
        {
            "index": 2, "codec_name": "aac", "codec_type": "audio",
            "sample_rate": "44100", "channels": 2, "channel_layout": "stereo",
            "r_frame_rate": "0/0",
            "disposition": { "default": 0, "comment": 0, "forced": 0 },
            "tags": { "language": "eng", "title": "English Dub" }
        },
        {
            "index": 3, "codec_name": "aac", "codec_type": "audio",
            "sample_rate": "44100", "channels": 2, "channel_layout": "stereo",
            "r_frame_rate": "0/0",
            "disposition": { "default": 0, "comment": 1, "forced": 0 },
            "tags": { "language": "eng", "title": "Commentary" }
        },
        {
            "index": 4, "codec_name": "subrip", "codec_type": "subtitle",
            "r_frame_rate": "0/0",
            "disposition": { "default": 1, "comment": 0, "forced": 0 },
            "tags": { "language": "chi", "title": "Simplified" }
        },
        {
            "index": 5, "codec_name": "subrip", "codec_type": "subtitle",
            "r_frame_rate": "0/0",
            "disposition": { "default": 0, "comment": 0, "forced": 1 },
            "tags": { "language": "jpn", "title": "Forced Signs" }
        }
    ],
    "format": { "duration": "2.023000", "size": "1453519", "bit_rate": "5747974" }
}
''';

    test('容器级事实', () {
      final VideoProbeFacts facts = parseFfprobeFacts(json);
      expect(facts.durationMs, 2023);
      expect(facts.fileSizeBytes, 1453519);
      expect(facts.containerBitrate, 5747974);
      expect(facts.isEmpty, isFalse);
    });

    test('视频流规格', () {
      final VideoStreamFacts video = parseFfprobeFacts(json).video!;
      expect(video.codec, 'h264');
      expect(video.codecLabel, 'H.264');
      expect(video.width, 1920);
      expect(video.height, 1080);
      expect(video.resolutionLabel, '1080p');
      expect(video.bitDepth, 8);
      expect(video.frameRateMilli, 24000);
      expect(video.frameRate, 24.0);
      // 这个样本没写色彩标签 → ffprobe 整个省略键 → 必须是 unknown，不是 sdr。
      expect(video.dynamicRange, VideoDynamicRange.unknown);
    });

    test('三条音轨按流顺序，标志位正确', () {
      final List<AudioTrackFacts> tracks = parseFfprobeFacts(json).audioTracks;
      expect(tracks.length, 3);

      expect(tracks[0].index, 1);
      expect(tracks[0].codecLabel, 'FLAC');
      expect(tracks[0].channels, 6);
      expect(tracks[0].channelLabel, '5.1');
      expect(tracks[0].language, 'jpn');
      expect(tracks[0].title, 'Japanese 5.1');
      expect(tracks[0].isDefault, isTrue);
      expect(tracks[0].isCommentary, isFalse);

      expect(tracks[1].codecLabel, 'AAC');
      expect(tracks[1].channelLabel, '2.0', reason: 'stereo 归一成 2.0');
      expect(tracks[1].isDefault, isFalse);

      expect(tracks[2].isCommentary, isTrue, reason: 'disposition.comment=1');
      expect(tracks[2].title, 'Commentary');
    });

    test('两条字幕轨', () {
      final List<SubtitleTrackFacts> subs =
          parseFfprobeFacts(json).subtitleTracks;
      expect(subs.length, 2);
      expect(subs[0].codecLabel, 'SRT');
      expect(subs[0].language, 'chi');
      expect(subs[0].isDefault, isTrue);
      expect(subs[1].isForced, isTrue);
      expect(subs[1].title, 'Forced Signs');
    });

    test('audioLanguages 与扩展前语义逐字相同（老调用点依赖）', () {
      final VideoProbeFacts facts = parseFfprobeFacts(json);
      expect(facts.audioLanguages, <String>['jpn', 'eng', 'eng']);
      expect(facts.primaryAudioLanguage, 'jpn');
    });
  });

  group('HDR10 4K（真实 VUI）', () {
    // 关键点：10-bit HEVC 流**不给** bits_per_raw_sample，色深只能从 pix_fmt 推。
    const String json = '''
{
    "streams": [
        {
            "index": 0, "codec_name": "hevc", "codec_type": "video",
            "width": 3840, "height": 2160, "pix_fmt": "yuv420p10le",
            "color_range": "tv", "color_space": "bt2020nc",
            "color_transfer": "smpte2084", "color_primaries": "bt2020",
            "r_frame_rate": "24/1"
        }
    ],
    "format": { "duration": "1.000000", "size": "1950255", "bit_rate": "15586453" }
}
''';

    test('4K / HDR10 / 10bit / HEVC', () {
      final VideoStreamFacts video = parseFfprobeFacts(json).video!;
      expect(video.resolutionLabel, '4K');
      expect(video.dynamicRange, VideoDynamicRange.hdr10);
      expect(video.codecLabel, 'HEVC');
      expect(video.bitDepth, 10,
          reason: 'bits_per_raw_sample 缺失，必须从 pix_fmt 的 p10le 推');
      expect(video.colorTransfer, 'smpte2084');
    });

    test('没有音轨时 audioTracks 为空而不是抛异常', () {
      final VideoProbeFacts facts = parseFfprobeFacts(json);
      expect(facts.audioTracks, isEmpty);
      expect(facts.audioLanguages, isEmpty);
      expect(facts.primaryAudioLanguage, isNull);
    });
  });

  group('23.976fps 的分数帧率', () {
    const String json = '''
{
    "streams": [
        {
            "index": 0, "codec_name": "hevc", "codec_type": "video",
            "width": 3840, "height": 2160, "pix_fmt": "yuv420p10le",
            "color_space": "bt2020nc", "r_frame_rate": "2997/125"
        }
    ],
    "format": { "duration": "1.001000" }
}
''';

    test('"2997/125" → 23976（×1000 整数，无浮点误差）', () {
      final VideoStreamFacts video = parseFfprobeFacts(json).video!;
      expect(video.frameRateMilli, 23976);
      expect(video.frameRate, closeTo(23.976, 0.0005));
    });

    test('只有 color_space 没有 primaries/transfer → unknown', () {
      // 实测形态：给编码器传了 -color_trc 但没写进 VUI 时就长这样。
      expect(
        parseFfprobeFacts(json).video!.dynamicRange,
        VideoDynamicRange.unknown,
      );
    });
  });

  group('帧率解析边界', () {
    test('"0/0"（音轨/字幕轨的写法）→ null', () {
      expect(frameRateMilliFromFraction('0/0'), isNull);
    });

    test('null / 空串 → null', () {
      expect(frameRateMilliFromFraction(null), isNull);
      expect(frameRateMilliFromFraction('  '), isNull);
    });

    test('整常见帧率', () {
      expect(frameRateMilliFromFraction('24/1'), 24000);
      expect(frameRateMilliFromFraction('25/1'), 25000);
      expect(frameRateMilliFromFraction('30000/1001'), 29970);
      expect(frameRateMilliFromFraction('60/1'), 60000);
    });

    test('非分数写法也认', () {
      expect(frameRateMilliFromFraction('24'), 24000);
    });
  });

  group('色深从 pix_fmt 推', () {
    test('无后缀数字 = 8bit', () {
      expect(bitDepthFromPixelFormat('yuv420p'), 8);
      expect(bitDepthFromPixelFormat('yuvj420p'), 8);
    });

    test('10 / 12 bit', () {
      expect(bitDepthFromPixelFormat('yuv420p10le'), 10);
      expect(bitDepthFromPixelFormat('yuv444p12le'), 12);
      expect(bitDepthFromPixelFormat('gbrp10le'), 10);
    });

    test('null → null（不猜）', () {
      expect(bitDepthFromPixelFormat(null), isNull);
      expect(bitDepthFromPixelFormat('  '), isNull);
    });
  });

  group('清晰度分档按长边', () {
    ({int w, int h, String? label}) c(int w, int h, String? label) =>
        (w: w, h: h, label: label);

    final List<({int w, int h, String? label})> cases =
        <({int w, int h, String? label})>[
      c(3840, 2160, '4K'),
      c(4096, 1716, '4K'),
      c(2560, 1440, '1440p'),
      c(1920, 1080, '1080p'),
      // 2.35:1 的电影裁边片源：高度只有 804，按高度分档会误判成 720p。
      c(1920, 804, '1080p'),
      c(1280, 720, '720p'),
      c(1024, 576, '576p'),
      c(720, 480, '480p'),
      // 竖屏：长边是高度。
      c(1080, 1920, '1080p'),
    ];

    for (final ({int w, int h, String? label}) item in cases) {
      test('${item.w}x${item.h} → ${item.label}', () {
        expect(
          VideoStreamFacts(width: item.w, height: item.h).resolutionLabel,
          item.label,
        );
      });
    }

    test('缺尺寸 → null', () {
      expect(const VideoStreamFacts().resolutionLabel, isNull);
      expect(const VideoStreamFacts(width: 0, height: 0).resolutionLabel,
          isNull);
    });
  });

  group('容错', () {
    test('空 stdout → empty', () {
      expect(parseFfprobeFacts('').isEmpty, isTrue);
      expect(parseFfprobeFacts('   ').isEmpty, isTrue);
    });

    test('非 JSON → empty，不抛', () {
      expect(parseFfprobeFacts('not json at all').isEmpty, isTrue);
    });

    test('streams 整个缺失（只要了 format 时）仍能拿到时长', () {
      const String json = '{"format": {"duration": "12.5"}}';
      final VideoProbeFacts facts = parseFfprobeFacts(json);
      expect(facts.durationMs, 12500);
      expect(facts.video, isNull);
      expect(facts.audioTracks, isEmpty);
    });

    test('duration 为 "N/A" → null 而非崩', () {
      const String json = '{"format": {"duration": "N/A"}}';
      expect(parseFfprobeFacts(json).durationMs, isNull);
    });

    test('stream 缺 tags / disposition 时用安全默认', () {
      const String json = '''
{"streams":[{"index":1,"codec_name":"aac","codec_type":"audio","channels":2}]}
''';
      final AudioTrackFacts track = parseFfprobeFacts(json).audioTracks.single;
      expect(track.language, isNull);
      expect(track.title, isNull);
      expect(track.isDefault, isFalse);
      expect(track.isForced, isFalse);
      expect(track.isCommentary, isFalse);
      expect(track.channelLabel, '2.0', reason: '无 layout 时从 channels 推');
    });

    test('und 语言不入列（等同未标注）', () {
      const String json = '''
{"streams":[
  {"index":1,"codec_type":"audio","codec_name":"aac","tags":{"language":"und"}},
  {"index":2,"codec_type":"audio","codec_name":"aac","tags":{"language":"jpn"}}
]}
''';
      final VideoProbeFacts facts = parseFfprobeFacts(json);
      expect(facts.audioTracks.length, 2, reason: '轨道本身还在');
      expect(facts.audioTracks[0].language, isNull);
      expect(facts.audioLanguages, <String>['jpn'], reason: 'und 不入语言列表');
      expect(facts.primaryAudioLanguage, 'jpn');
    });

    test('parseFfprobeDurationMs 老入口仍可用', () {
      expect(parseFfprobeDurationMs('{"format":{"duration":"3.5"}}'), 3500);
    });
  });

  group('声道标签', () {
    String? label(String? layout, int? channels) => AudioTrackFacts(
          index: 0,
          channelLayout: layout,
          channels: channels,
        ).channelLabel;

    test('layout 优先', () {
      expect(label('5.1', 6), '5.1');
      expect(label('7.1', 8), '7.1');
      expect(label('stereo', 2), '2.0');
      expect(label('mono', 1), '1.0');
    });

    test('带括号后缀取主体', () {
      expect(label('5.1(side)', 6), '5.1');
    });

    test('无 layout 时按声道数', () {
      expect(label(null, 6), '5.1');
      expect(label(null, 8), '7.1');
      expect(label(null, 2), '2.0');
      expect(label(null, null), isNull);
    });
  });
}
