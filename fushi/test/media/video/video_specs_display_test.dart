import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/media/video/video_specs_display.dart';

/// 规格的格式化。纯函数层，不碰 i18n 也不碰 widget。
void main() {
  VideoProbeFacts factsWith({
    int? width,
    int? height,
    String? codec,
    String? transfer,
    String? primaries,
    int? bitDepth,
    int? frameRateMilli,
    int? videoBitrate,
    int? containerBitrate,
    List<AudioTrackFacts> audio = const <AudioTrackFacts>[],
    List<SubtitleTrackFacts> subtitles = const <SubtitleTrackFacts>[],
  }) =>
      VideoProbeFacts(
        containerBitrate: containerBitrate,
        video: (width == null && codec == null && transfer == null)
            ? null
            : VideoStreamFacts(
                codec: codec,
                width: width,
                height: height,
                bitDepth: bitDepth,
                frameRateMilli: frameRateMilli,
                bitrate: videoBitrate,
                colorPrimaries: primaries,
                colorTransfer: transfer,
              ),
        audioTracks: audio,
        subtitleTracks: subtitles,
      );

  group('封面角标', () {
    test('4K + HDR10 两个', () {
      expect(
        videoSpecsCoverBadges(factsWith(
          width: 3840,
          height: 2160,
          primaries: 'bt2020',
          transfer: 'smpte2084',
        )),
        <String>['4K', 'HDR10'],
      );
    });

    test('HLG 也出角标', () {
      expect(
        videoSpecsCoverBadges(factsWith(
          width: 1920,
          height: 1080,
          primaries: 'bt2020',
          transfer: 'arib-std-b67',
        )),
        <String>['1080p', 'HLG'],
      );
    });

    test('SDR 只出清晰度——「是 SDR」不是信息，不该占角标位', () {
      expect(
        videoSpecsCoverBadges(factsWith(
          width: 1920,
          height: 1080,
          primaries: 'bt709',
          transfer: 'bt709',
        )),
        <String>['1080p'],
      );
    });

    test('色彩标签缺失（unknown）同样不出动态范围角标', () {
      expect(
        videoSpecsCoverBadges(factsWith(width: 1280, height: 720)),
        <String>['720p'],
      );
    });

    test('无规格 / 无视频流 → 空', () {
      expect(videoSpecsCoverBadges(null), isEmpty);
      expect(videoSpecsCoverBadges(VideoProbeFacts.empty), isEmpty);
      expect(videoSpecsCoverBadges(factsWith(audio: const <AudioTrackFacts>[
        AudioTrackFacts(index: 0, codec: 'flac'),
      ])), isEmpty, reason: '纯音频没有视频流');
    });

    test('最多两个，不会因为编码多出第三个', () {
      final List<String> badges = videoSpecsCoverBadges(factsWith(
        width: 3840,
        height: 2160,
        codec: 'hevc',
        primaries: 'bt2020',
        transfer: 'smpte2084',
      ));
      expect(badges, hasLength(2));
    });
  });

  group('紧凑摘要', () {
    test('清晰度 · 动态范围 · 编码', () {
      expect(
        videoSpecsInlineSummary(factsWith(
          width: 3840,
          height: 2160,
          codec: 'hevc',
          primaries: 'bt2020',
          transfer: 'smpte2084',
        )),
        '4K · HDR10 · HEVC',
      );
    });

    test('SDR 时省掉动态范围', () {
      expect(
        videoSpecsInlineSummary(factsWith(
          width: 1920,
          height: 1080,
          codec: 'h264',
          primaries: 'bt709',
          transfer: 'bt709',
        )),
        '1080p · H.264',
      );
    });

    test('无可显示项返回 null 而不是空串（调用方据此整行不渲染）', () {
      expect(videoSpecsInlineSummary(null), isNull);
      expect(videoSpecsInlineSummary(VideoProbeFacts.empty), isNull);
    });
  });

  group('详情字段', () {
    test('4K 后面补真实像素（档位不等于尺寸）', () {
      final List<(VideoSpecField, String)> fields =
          videoSpecsFields(factsWith(width: 4096, height: 1716));
      expect(fields.first.$1, VideoSpecField.resolution);
      expect(fields.first.$2, '4K (4096×1716)');
    });

    test('探不到的项整行不出现，不显示「未知」', () {
      final List<(VideoSpecField, String)> fields =
          videoSpecsFields(factsWith(width: 1920, height: 1080));
      final Set<VideoSpecField> present =
          fields.map(((VideoSpecField, String) f) => f.$1).toSet();
      expect(present, contains(VideoSpecField.resolution));
      expect(present, isNot(contains(VideoSpecField.bitDepth)));
      expect(present, isNot(contains(VideoSpecField.frameRate)));
      expect(present, isNot(contains(VideoSpecField.dynamicRange)),
          reason: 'unknown 不该被写成一行');
    });

    test('码率优先流级，缺失时回退容器级（mkv 不给流级）', () {
      expect(
        videoSpecsFields(factsWith(
          width: 1920,
          videoBitrate: 8000000,
          containerBitrate: 9000000,
        )).where((( VideoSpecField, String) f) =>
            f.$1 == VideoSpecField.bitrate).single.$2,
        '8.0 Mbps',
      );
      expect(
        videoSpecsFields(factsWith(width: 1920, containerBitrate: 15586453))
            .where(((VideoSpecField, String) f) =>
                f.$1 == VideoSpecField.bitrate)
            .single
            .$2,
        '16 Mbps',
      );
    });

    test('null facts → 空', () {
      expect(videoSpecsFields(null), isEmpty);
    });
  });

  group('帧率格式化', () {
    test('整数帧率不留小数点', () {
      expect(formatFrameRate(24000), '24 fps');
      expect(formatFrameRate(60000), '60 fps');
    });

    test('23.976 保留三位', () {
      expect(formatFrameRate(23976), '23.976 fps');
    });

    test('尾随 0 去掉', () {
      expect(formatFrameRate(25500), '25.5 fps');
    });

    test('null / 0 → null', () {
      expect(formatFrameRate(null), isNull);
      expect(formatFrameRate(0), isNull);
    });
  });

  group('码率格式化', () {
    test('10 Mbps 以上取整（差 0.1 无意义）', () {
      expect(formatBitrate(15586453), '16 Mbps');
      expect(formatBitrate(10000000), '10 Mbps');
    });

    test('10 Mbps 以下留一位小数', () {
      expect(formatBitrate(8000000), '8.0 Mbps');
      expect(formatBitrate(1500000), '1.5 Mbps');
    });

    test('1 Mbps 以下用 kbps', () {
      expect(formatBitrate(800000), '800 kbps');
      expect(formatBitrate(128000), '128 kbps');
    });

    test('用十进制而不是 1024 进制（与 ffprobe/发布组标题对齐）', () {
      // 1024 进制会得到 15.4 Mbps，与用户在别处看到的数字对不上。
      expect(formatBitrate(16000000), '16 Mbps');
    });

    test('null / 0 → null', () {
      expect(formatBitrate(null), isNull);
      expect(formatBitrate(0), isNull);
    });
  });

  group('轨道展示', () {
    test('音轨：名字 · 编码 · 声道 + 标志位', () {
      final TrackDisplay d = audioTrackDisplay(const AudioTrackFacts(
        index: 1,
        codec: 'flac',
        channels: 6,
        channelLayout: '5.1',
        language: 'jpn',
        title: '日本語',
        isDefault: true,
      ));
      expect(d.headline, '日本語 · FLAC · 5.1');
      expect(d.isDefault, isTrue);
      expect(d.isCommentary, isFalse);
    });

    test('名字回落：title → language → #序号', () {
      expect(trackDisplayName('Commentary', 'eng', 3), 'Commentary');
      expect(trackDisplayName(null, 'eng', 3), 'ENG');
      expect(trackDisplayName('  ', null, 3), '#3');
      expect(trackDisplayName(null, null, 3), '#3');
    });

    test('字幕轨：名字 · 格式', () {
      final TrackDisplay d = subtitleTrackDisplay(const SubtitleTrackFacts(
        index: 4,
        codec: 'subrip',
        language: 'chi',
        isForced: true,
      ));
      expect(d.headline, 'CHI · SRT');
      expect(d.isForced, isTrue);
    });

    test('没有技术细节时 headline 只剩名字（不留悬空分隔符）', () {
      final TrackDisplay d = subtitleTrackDisplay(
        const SubtitleTrackFacts(index: 2, language: 'jpn'),
      );
      expect(d.headline, 'JPN');
      expect(d.detail, isEmpty);
    });
  });
}
