/// 动画发布标题的结构化资源规格。
///
/// 本文件只解析标题中能可靠辨认的技术标签；音轨语言、字幕语言等通常无法仅凭
/// Nyaa 标题确定的事实刻意不猜。后续订阅过滤、排序和洗版规则都应消费
/// [AnimeReleaseDescriptor]，避免各自重复正则并产生不同判定。
library;

/// 视频来源类型。
enum AnimeVideoSource {
  unknown,
  webDl,
  webRip,
  bluRay,
  remux,
  television,
  dvd,
}

/// 视频编码类型。
enum AnimeVideoCodec { unknown, avc, hevc, av1, vp9, mpeg4 }

/// 高动态范围标签。
///
/// 一条发布可以同时标注 Dolby Vision 与 HDR10，因此描述对象使用集合保存。
enum AnimeDynamicRange { sdr, hdr, hdr10, hdr10Plus, dolbyVision, hlg }

/// 音频编码类型。
enum AnimeAudioCodec {
  aac,
  flac,
  opus,
  ac3,
  eac3,
  trueHd,
  dts,
  dtsHd,
  pcm,
  mp3,
  vorbis,
}

/// 字幕是软字幕还是硬字幕。
enum AnimeSubtitlePresentation { unknown, soft, hard }

/// 从动画发布标题提取出的资源规格。
class AnimeReleaseDescriptor {
  const AnimeReleaseDescriptor({
    required this.releaseGroup,
    required this.resolutionHeight,
    required this.videoSource,
    required this.videoCodec,
    required this.bitDepth,
    required this.dynamicRanges,
    required this.audioCodecs,
    required this.subtitlePresentation,
  });

  /// 标题开头第一个方括号块中的发布组；没有则为 null。
  final String? releaseGroup;

  /// 归一化后的垂直分辨率，如 1080；认不出为 null。
  final int? resolutionHeight;

  /// 视频来源。
  final AnimeVideoSource videoSource;

  /// 视频编码。
  final AnimeVideoCodec videoCodec;

  /// 位深，如 8、10、12；认不出为 null。
  final int? bitDepth;

  /// 标题中出现的 HDR/SDR 标签。
  final Set<AnimeDynamicRange> dynamicRanges;

  /// 标题中出现的音频编码标签。
  final Set<AnimeAudioCodec> audioCodecs;

  /// 标题明确声明的软字幕/硬字幕形态。
  final AnimeSubtitlePresentation subtitlePresentation;

  /// 与旧订阅字段兼容的标准分辨率标签，如 `1080p`。
  String? get resolution =>
      resolutionHeight == null ? null : '${resolutionHeight}p';

  /// 是否带任意 HDR 标签。
  bool get isHdr => dynamicRanges.any(
        (AnimeDynamicRange range) => range != AnimeDynamicRange.sdr,
      );
}

final RegExp _leadingReleaseGroup = RegExp(r'^\s*\[([^\]]+)\]');

/// 解析动画发布标题为结构化资源规格。
///
/// 结果只来自纯字符串分析，无 IO、无站点状态，适合作为订阅规则的稳定输入。
AnimeReleaseDescriptor parseAnimeReleaseDescriptor(String title) {
  final String upper = title.toUpperCase();
  final String tokens = upper
      .replaceAll(RegExp(r'[^A-Z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return AnimeReleaseDescriptor(
    releaseGroup: _leadingReleaseGroup.firstMatch(title)?.group(1)?.trim(),
    resolutionHeight: _parseResolutionHeight(title),
    videoSource: _parseVideoSource(tokens),
    videoCodec: _parseVideoCodec(tokens),
    bitDepth: _parseBitDepth(tokens),
    dynamicRanges: Set<AnimeDynamicRange>.unmodifiable(
      _parseDynamicRanges(upper, tokens),
    ),
    audioCodecs: Set<AnimeAudioCodec>.unmodifiable(
      _parseAudioCodecs(tokens),
    ),
    subtitlePresentation: _parseSubtitlePresentation(tokens),
  );
}

int? _parseResolutionHeight(String title) {
  final RegExpMatch? progressive = RegExp(
    r'(?:^|[^0-9])(\d{3,4})\s*[pP](?:[^0-9]|$)',
  ).firstMatch(title);
  if (progressive != null) {
    final int height = int.parse(progressive.group(1)!);
    if (height >= 240 && height <= 4320) return height;
  }

  final RegExpMatch? dimensions = RegExp(
    r'(?:^|[^0-9])(\d{3,4})\s*[xX×]\s*(\d{3,4})(?:[^0-9]|$)',
  ).firstMatch(title);
  if (dimensions != null) {
    final int height = int.parse(dimensions.group(2)!);
    if (height >= 240 && height <= 4320) return height;
  }

  if (RegExp(r'(?:^|[^A-Za-z0-9])8K(?:[^A-Za-z0-9]|$)', caseSensitive: false)
      .hasMatch(title)) {
    return 4320;
  }
  if (RegExp(r'(?:^|[^A-Za-z0-9])4K(?:[^A-Za-z0-9]|$)', caseSensitive: false)
      .hasMatch(title)) {
    return 2160;
  }
  return null;
}

AnimeVideoSource _parseVideoSource(String tokens) {
  if (RegExp(r'\bREMUX\b').hasMatch(tokens)) {
    return AnimeVideoSource.remux;
  }
  if (RegExp(r'\b(?:BDRIP|BDMV|BLURAY|BLU RAY)\b').hasMatch(tokens)) {
    return AnimeVideoSource.bluRay;
  }
  if (RegExp(r'\bWEB\s*DL\b').hasMatch(tokens)) {
    return AnimeVideoSource.webDl;
  }
  if (RegExp(r'\bWEB\s*RIP\b').hasMatch(tokens)) {
    return AnimeVideoSource.webRip;
  }
  if (RegExp(r'\b(?:HDTV|TVRIP)\b').hasMatch(tokens)) {
    return AnimeVideoSource.television;
  }
  if (RegExp(r'\b(?:DVDRIP|DVD)\b').hasMatch(tokens)) {
    return AnimeVideoSource.dvd;
  }
  return AnimeVideoSource.unknown;
}

AnimeVideoCodec _parseVideoCodec(String tokens) {
  if (RegExp(r'\b(?:AV1|AV01)\b').hasMatch(tokens)) {
    return AnimeVideoCodec.av1;
  }
  if (RegExp(r'\b(?:X265|H\s*265|HEVC)\b').hasMatch(tokens)) {
    return AnimeVideoCodec.hevc;
  }
  if (RegExp(r'\b(?:X264|H\s*264|AVC)\b').hasMatch(tokens)) {
    return AnimeVideoCodec.avc;
  }
  if (RegExp(r'\bVP9\b').hasMatch(tokens)) return AnimeVideoCodec.vp9;
  if (RegExp(r'\b(?:MPEG\s*4|XVID|DIVX)\b').hasMatch(tokens)) {
    return AnimeVideoCodec.mpeg4;
  }
  return AnimeVideoCodec.unknown;
}

int? _parseBitDepth(String tokens) {
  final RegExpMatch? explicit =
      RegExp(r'\b(8|10|12)\s*BITS?\b').firstMatch(tokens);
  if (explicit != null) return int.parse(explicit.group(1)!);
  if (RegExp(r'\b(?:HI10P|MA10P|MAIN10|YUV420P10(?:LE)?)\b').hasMatch(tokens)) {
    return 10;
  }
  return null;
}

Set<AnimeDynamicRange> _parseDynamicRanges(String upper, String tokens) {
  final Set<AnimeDynamicRange> ranges = <AnimeDynamicRange>{};
  if (RegExp(r'\bSDR\b').hasMatch(tokens)) {
    ranges.add(AnimeDynamicRange.sdr);
  }
  if (RegExp(r'\b(?:DOLBY\s*VISION|DOVI|DV)\b').hasMatch(tokens)) {
    ranges.add(AnimeDynamicRange.dolbyVision);
  }
  if (RegExp(r'\bHDR10\s*\+').hasMatch(upper)) {
    ranges.add(AnimeDynamicRange.hdr10Plus);
  } else if (RegExp(r'\bHDR\s*10\b').hasMatch(tokens)) {
    ranges.add(AnimeDynamicRange.hdr10);
  } else if (RegExp(r'\bHDR\b').hasMatch(tokens)) {
    ranges.add(AnimeDynamicRange.hdr);
  }
  if (RegExp(r'\bHLG\b').hasMatch(tokens)) {
    ranges.add(AnimeDynamicRange.hlg);
  }
  return ranges;
}

Set<AnimeAudioCodec> _parseAudioCodecs(String tokens) {
  final Set<AnimeAudioCodec> codecs = <AnimeAudioCodec>{};
  final bool dtsHd = RegExp(r'\bDTS\s*HD\b').hasMatch(tokens);
  final bool eac3 = RegExp(r'\b(?:EAC3|E\s*AC\s*3|DDP)\b').hasMatch(tokens);
  if (RegExp(r'\bAAC\b').hasMatch(tokens)) codecs.add(AnimeAudioCodec.aac);
  if (RegExp(r'\bFLAC\b').hasMatch(tokens)) codecs.add(AnimeAudioCodec.flac);
  if (RegExp(r'\bOPUS\b').hasMatch(tokens)) codecs.add(AnimeAudioCodec.opus);
  if (eac3) {
    codecs.add(AnimeAudioCodec.eac3);
  } else if (RegExp(r'\bAC\s*3\b').hasMatch(tokens)) {
    codecs.add(AnimeAudioCodec.ac3);
  }
  if (RegExp(r'\bTRUE\s*HD\b').hasMatch(tokens)) {
    codecs.add(AnimeAudioCodec.trueHd);
  }
  if (dtsHd) {
    codecs.add(AnimeAudioCodec.dtsHd);
  } else if (RegExp(r'\bDTS\b').hasMatch(tokens)) {
    codecs.add(AnimeAudioCodec.dts);
  }
  if (RegExp(r'\bPCM\b').hasMatch(tokens)) codecs.add(AnimeAudioCodec.pcm);
  if (RegExp(r'\bMP3\b').hasMatch(tokens)) codecs.add(AnimeAudioCodec.mp3);
  if (RegExp(r'\bVORBIS\b').hasMatch(tokens)) {
    codecs.add(AnimeAudioCodec.vorbis);
  }
  return codecs;
}

AnimeSubtitlePresentation _parseSubtitlePresentation(String tokens) {
  final bool soft = RegExp(r'\bSOFT\s*SUBS?\b').hasMatch(tokens);
  final bool hard = RegExp(r'\bHARD\s*SUBS?\b').hasMatch(tokens);
  if (soft == hard) return AnimeSubtitlePresentation.unknown;
  return soft ? AnimeSubtitlePresentation.soft : AnimeSubtitlePresentation.hard;
}
