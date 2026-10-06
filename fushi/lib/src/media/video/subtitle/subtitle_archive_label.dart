import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_archive.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

/// 整季压缩包候选在列表里的标注；不是压缩包返回 null。
///
/// 解不开的格式（RAR / 7z）也照样列出、并在这里直说「暂不支持解包」：用户至少知道
/// 来源上有字幕、可以自己去网站下，而不是看到一句「找不到字幕」。
String? subtitleArchivePackLabel(VideoSubtitleCandidate candidate) {
  final SubtitleArchiveFormat? format = candidate.archiveFormat;
  if (format == null) return null;
  return format.isSupported
      ? t.video_subtitle_archive_pack(format: format.label)
      : t.video_subtitle_archive_pack_unsupported(format: format.label);
}
