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

  group('内嵌封面图不能被当成视频轨', () {
    // 真实输出（ffprobe n7.1.5，样本是 ffmpeg 造的 mp4：1080p h264 + 600x900 mjpeg
    // 封面）。注意 attached_pic 是 mp4/mov 的机制——mkv 走 Attachments，封面根本不
    // 作为 stream 出现，所以那边天然没这个问题。
    const String coverAfter = '''
{
    "streams": [
        {
            "index": 0, "codec_name": "h264", "codec_type": "video",
            "width": 1920, "height": 1080, "pix_fmt": "yuv420p",
            "disposition": { "attached_pic": 0 }
        },
        {
            "index": 1, "codec_name": "mjpeg", "codec_type": "video",
            "width": 600, "height": 900, "pix_fmt": "yuvj420p",
            "disposition": { "attached_pic": 1 }
        }
    ]
}
''';

    // 同一份数据，封面排在**前面**——muxer 顺序不保证，这是会真的出错的排列。
    const String coverFirst = '''
{
    "streams": [
        {
            "index": 0, "codec_name": "mjpeg", "codec_type": "video",
            "width": 600, "height": 900, "pix_fmt": "yuvj420p",
            "disposition": { "attached_pic": 1 }
        },
        {
            "index": 1, "codec_name": "h264", "codec_type": "video",
            "width": 1920, "height": 1080, "pix_fmt": "yuv420p",
            "disposition": { "attached_pic": 0 }
        }
    ]
}
''';

    test('封面在后：取到真视频轨', () {
      final VideoStreamFacts video = parseFfprobeFacts(coverAfter).video!;
      expect(video.codecLabel, 'H.264');
      expect(video.resolutionLabel, '1080p');
    });

    test('封面在前：仍取到真视频轨，不会标成 MJPEG 海报尺寸', () {
      final VideoStreamFacts video = parseFfprobeFacts(coverFirst).video!;
      expect(video.codec, 'h264', reason: '拿第一条 video 流会得到 mjpeg');
      expect(video.width, 1920);
      expect(video.height, 1080);
      expect(video.resolutionLabel, '1080p',
          reason: '封面是 600x900，误判会显示 900p 一类');
    });

    test('只有封面没有真视频轨 → 没有视频流（纯音频带封面）', () {
      const String onlyCover = '''
{"streams":[{"index":0,"codec_name":"mjpeg","codec_type":"video",
"width":600,"height":900,"disposition":{"attached_pic":1}},
{"index":1,"codec_name":"flac","codec_type":"audio","channels":2}]}
''';
      final VideoProbeFacts facts = parseFfprobeFacts(onlyCover);
      expect(facts.video, isNull);
      expect(facts.audioTracks, hasLength(1));
    });
  });

  group('清晰度短标：原生超宽 vs 裁边', () {
    String? label(int w, int h) =>
        VideoStreamFacts(width: w, height: h).resolutionLabel;

    test('原生超宽按短边（21:9 的多出来的是宽，不是清晰度档）', () {
      // 只按长边会判成 1440p——用户在角标看到 1440p，点进去只有 1080 行像素。
      expect(label(2560, 1080), '1080p', reason: 'UW-FHD');
      expect(label(3440, 1440), '1440p', reason: 'UW-QHD');
      expect(label(5120, 2160), '4K', reason: 'UW-4K');
      expect(label(2160, 1080), '1080p', reason: '正好 2.0:1');
    });

    test('2.35:1 裁边仍按长边（短边落不到标准档上）', () {
      expect(label(1920, 800), '1080p');
      expect(label(1920, 872), '1080p');
      expect(label(1280, 534), '720p');
      // 这一条是窄窗口判据的判例：4096×1716 短边 1716，任何 `>= 1400` 的开区间
      // 都会把它吞成 1440p。
      expect(label(4096, 1716), '4K', reason: 'DCI 4K 的 2.39:1 裁边');
      expect(label(2048, 858), '1080p', reason: 'DCI 2K 的 2.39:1 裁边');
    });

    test('普通 16:9 与竖屏不受超宽分支影响', () {
      expect(label(1920, 1080), '1080p');
      expect(label(2560, 1440), '1440p');
      expect(label(3840, 2160), '4K');
      expect(label(1080, 1920), '1080p', reason: '竖屏');
      expect(label(1440, 2560), '1440p', reason: '竖屏');
    });
  });

  group('色深从 pix_fmt 推', () {
    test('以 p 结尾无后缀数字 = 8bit', () {
      expect(bitDepthFromPixelFormat('yuv420p'), 8);
      expect(bitDepthFromPixelFormat('yuvj420p'), 8);
      expect(bitDepthFromPixelFormat('gbrp'), 8);
    });

    test('10 / 12 bit', () {
      expect(bitDepthFromPixelFormat('yuv420p10le'), 10);
      expect(bitDepthFromPixelFormat('yuv444p12le'), 12);
      expect(bitDepthFromPixelFormat('gbrp10le'), 10);
    });

    test('pNXX 半平面族按 `p<子采样><位深>` 解，不是「p 后面全是位深」', () {
      // p010/p012/p016 此前是撞巧对上的（子采样位恰好是 0）；p2xx / p4xx 会被通用
      // 规则解析成 210~416，详情页显示「色深 210 bit」，而且返回非 null 还会短路掉
      // 调用方对 bits_per_raw_sample 的回退。
      expect(bitDepthFromPixelFormat('p010le'), 10, reason: '4:2:0 10bit');
      expect(bitDepthFromPixelFormat('p016le'), 16);
      expect(bitDepthFromPixelFormat('p210le'), 10, reason: '4:2:2 10bit');
      expect(bitDepthFromPixelFormat('p212le'), 12);
      expect(bitDepthFromPixelFormat('p216le'), 16);
      expect(bitDepthFromPixelFormat('p410le'), 10, reason: '4:4:4 10bit');
      expect(bitDepthFromPixelFormat('p412le'), 12);
      expect(bitDepthFromPixelFormat('p416le'), 16);
      // 大小端后缀可缺省。
      expect(bitDepthFromPixelFormat('p010'), 10);
    });

    test('不以 p 收尾的格式 → null（回退到 bits_per_raw_sample）', () {
      // 兜底成 8 会把这些格式的真实位深永久盖掉，而正确值就在同一条 JSON 里。
      expect(bitDepthFromPixelFormat('rgb48le'), isNull);
      expect(bitDepthFromPixelFormat('xyz12le'), isNull);
      expect(bitDepthFromPixelFormat('nv20'), isNull);
    });

    test('解析器与 bits_per_raw_sample 的协作：pix_fmt 推不出时用后者', () {
      const String json = '''
{"streams":[{"index":0,"codec_type":"video","codec_name":"ffv1",
"width":1920,"height":1080,"pix_fmt":"rgb48le","bits_per_raw_sample":"16"}]}
''';
      expect(parseFfprobeFacts(json).video!.bitDepth, 16);
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
      expect(
          const VideoStreamFacts(width: 0, height: 0).resolutionLabel, isNull);
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
