/// 把 [VideoProbeFacts] 变成给人看的字符串（v95）。
///
/// 单独一层是因为**同一份事实有两种展示密度**：库页卡片只有一个角落放得下两个词，
/// 作品详情页要摊开成十来行。格式化写在各自的 widget 里，两边迟早对同一个码率给出
/// 不同写法（一边 15.6 Mbps 一边 15586 kbps）。
///
/// **本层不碰 i18n**：slang 生成的 `t` 是 library-private 类型，跨文件当参数传不了；
/// 更重要的是值的格式化（`23.976 fps`、`5.1`、`10 bit`）本来就与语言无关，而 label
/// 与标志词才需要翻译。所以这里只产出「字段 + 值」，label 的映射留给 widget 层——
/// 顺带让这一整层可以脱离 widget 测试。
library;

import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/media/video/video_dynamic_range.dart';

/// 详情页规格表里的一项。widget 层据此取对应的 i18n label。
enum VideoSpecField {
  resolution,
  dynamicRange,
  videoCodec,
  bitDepth,
  frameRate,
  bitrate,
  audioTracks,
  subtitleTracks,
}

/// 卡片封面角标：**最多两个**，依次是清晰度与动态范围。
///
/// 刻意只给两个：封面是给人认片子的，不是规格表。四个角已被标签/集数/云/进度条占住，
/// 再多塞就开始盖画面。完整规格在作品详情页。
///
/// SDR 不出角标——「这片子是 SDR」不是信息，绝大多数片源都是；只有 HDR10 / HLG 值得
/// 占位（unknown 更是绝不出，见 [VideoDynamicRange] 的 unknown≠sdr 说明）。
List<String> videoSpecsCoverBadges(VideoProbeFacts? facts) {
  final VideoStreamFacts? video = facts?.video;
  if (video == null) return const <String>[];
  final List<String> out = <String>[];
  final String? resolution = video.resolutionLabel;
  if (resolution != null) out.add(resolution);
  final VideoDynamicRange range = video.dynamicRange;
  if (range.isHdr) {
    final String? label = range.badgeLabel;
    if (label != null) out.add(label);
  }
  return List<String>.unmodifiable(out);
}

/// 一行紧凑摘要，给卡片文字区/集卡状态行用：`1080p · HDR10 · HEVC`。
///
/// 没有任何可显示项时返回 null 而不是空串——调用方据此决定「整行不渲染」，空串会白
/// 占一行高度。
String? videoSpecsInlineSummary(VideoProbeFacts? facts) {
  final VideoStreamFacts? video = facts?.video;
  if (video == null) return null;
  final List<String> parts = <String>[
    ...videoSpecsCoverBadges(facts),
    if (video.codecLabel != null) video.codecLabel!,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 详情页的规格项（字段 + 已格式化的值）。
///
/// **探不到的项整行不出现**，不显示「未知」——一行「色深：未知」对用户毫无价值，
/// 只会把真正有信息的行挤下去。
List<(VideoSpecField field, String value)> videoSpecsFields(
  VideoProbeFacts? facts,
) {
  if (facts == null) return const <(VideoSpecField, String)>[];
  final List<(VideoSpecField, String)> rows = <(VideoSpecField, String)>[];
  final VideoStreamFacts? video = facts.video;

  if (video != null) {
    final String? resolution = video.resolutionLabel;
    if (resolution != null) {
      // 「4K」后面补真实像素：4K 是档位不是尺寸（3840×2160 与 4096×1716 同档不同
      // 形），而用户比较片源时在意的正是这个差别。
      final String pixels = (video.width != null && video.height != null)
          ? ' (${video.width}×${video.height})'
          : '';
      rows.add((VideoSpecField.resolution, '$resolution$pixels'));
    }

    final String? rangeLabel = video.dynamicRange.badgeLabel;
    if (rangeLabel != null) {
      rows.add((VideoSpecField.dynamicRange, rangeLabel));
    }

    final String? codec = video.codecLabel;
    if (codec != null) rows.add((VideoSpecField.videoCodec, codec));

    final int? bitDepth = video.bitDepth;
    if (bitDepth != null) rows.add((VideoSpecField.bitDepth, '$bitDepth bit'));

    final String? frameRate = formatFrameRate(video.frameRateMilli);
    if (frameRate != null) rows.add((VideoSpecField.frameRate, frameRate));
  }

  // 码率优先用视频流自己的；mkv 不给流级码率，退回容器级（见 VideoProbeFacts 注释）。
  final String? bitrate =
      formatBitrate(video?.bitrate ?? facts.containerBitrate);
  if (bitrate != null) rows.add((VideoSpecField.bitrate, bitrate));

  return List<(VideoSpecField, String)>.unmodifiable(rows);
}

/// 一条音轨的展示形态。标志位留给 widget 层配语言（「默认」「评论音轨」「强制」）。
class TrackDisplay {
  const TrackDisplay({
    required this.name,
    required this.detail,
    required this.isDefault,
    required this.isForced,
    required this.isCommentary,
  });

  /// 已按「自报标题 → 语言 tag → #序号」回落好的名字。
  final String name;

  /// `FLAC · 5.1` 这类技术细节；无可显示项时为空串。
  final String detail;

  final bool isDefault;
  final bool isForced;
  final bool isCommentary;

  /// `日本語 · FLAC · 5.1`（不含标志位）。
  String get headline => detail.isEmpty ? name : '$name · $detail';
}

/// 音轨 → 展示形态。
///
/// 轨道名的回落链与播放器侧音轨菜单一致（title → language → 序号），免得同一条轨道
/// 在详情页叫「Japanese 5.1」、在播放器里叫「音轨 2」。
TrackDisplay audioTrackDisplay(AudioTrackFacts track) => TrackDisplay(
      name: trackDisplayName(track.title, track.language, track.index),
      detail: <String>[
        if (track.codecLabel != null) track.codecLabel!,
        if (track.channelLabel != null) track.channelLabel!,
      ].join(' · '),
      isDefault: track.isDefault,
      isForced: track.isForced,
      isCommentary: track.isCommentary,
    );

/// 字幕轨 → 展示形态。
TrackDisplay subtitleTrackDisplay(SubtitleTrackFacts track) => TrackDisplay(
      name: trackDisplayName(track.title, track.language, track.index),
      detail: track.codecLabel ?? '',
      isDefault: track.isDefault,
      isForced: track.isForced,
      isCommentary: false,
    );

/// 轨道名回落：自报标题 → 语言 tag（大写）→ `#序号`。
String trackDisplayName(String? title, String? language, int index) {
  final String? trimmedTitle = title?.trim();
  if (trimmedTitle != null && trimmedTitle.isNotEmpty) return trimmedTitle;
  final String? trimmedLanguage = language?.trim();
  if (trimmedLanguage != null && trimmedLanguage.isNotEmpty) {
    return trimmedLanguage.toUpperCase();
  }
  return '#$index';
}

/// 帧率：23976 → `23.976 fps`；24000 → `24 fps`（整数不留小数点）。
String? formatFrameRate(int? frameRateMilli) {
  if (frameRateMilli == null || frameRateMilli <= 0) return null;
  if (frameRateMilli % 1000 == 0) return '${frameRateMilli ~/ 1000} fps';
  final String text = (frameRateMilli / 1000).toStringAsFixed(3);
  // 去掉尾随 0：23.976 原样保留，25.500 → 25.5。
  String trimmed = text.replaceAll(RegExp(r'0+$'), '');
  if (trimmed.endsWith('.')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return '$trimmed fps';
}

/// 码率：15586453 → `15.6 Mbps`；800000 → `800 kbps`。
///
/// 用 1000 而不是 1024 进制：码率历来按十进制记（ffprobe、播放器、发布组标题都是），
/// 按 1024 折算会与用户在别处看到的数字对不上。
String? formatBitrate(int? bitsPerSecond) {
  if (bitsPerSecond == null || bitsPerSecond <= 0) return null;
  if (bitsPerSecond >= 1000000) {
    final double mbps = bitsPerSecond / 1000000;
    // 10 Mbps 以上不留小数位：差 0.1 Mbps 对用户没有意义。
    return mbps >= 10
        ? '${mbps.round()} Mbps'
        : '${mbps.toStringAsFixed(1)} Mbps';
  }
  return '${(bitsPerSecond / 1000).round()} kbps';
}
