library;

import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:path/path.dart' as p;

class VideoLocalExtraMatch {
  const VideoLocalExtraMatch(this.kind);

  final VideoMetadataExtraKind kind;
}

/// Kodi 目录、常见动画 NCOP/NCED/PV 文件的本地附件分类。
///
/// 这里只判断“不是正片/分集”，不猜作品归属；归属仍由来源索引器依据唯一作品根决定。
VideoLocalExtraMatch? classifyLocalVideoExtra(String path) {
  final List<String> segments = p
      .split(p.normalize(path))
      .map((String value) =>
          value.toLowerCase().replaceAll(RegExp(r'[_-]+'), ' '))
      .toList(growable: false);
  final String stem = p.basenameWithoutExtension(path).toLowerCase();
  VideoMetadataExtraKind? kind;
  for (final String segment in segments.reversed) {
    kind = switch (segment.trim()) {
      'trailers' || 'trailer' => VideoMetadataExtraKind.trailer,
      'featurettes' || 'featurette' => VideoMetadataExtraKind.featurette,
      'behind the scenes' => VideoMetadataExtraKind.behindTheScenes,
      'deleted scenes' ||
      'deleted scene' =>
        VideoMetadataExtraKind.deletedScene,
      'interviews' || 'interview' => VideoMetadataExtraKind.interview,
      'shorts' || 'short' => VideoMetadataExtraKind.short,
      'scenes' || 'scene' => VideoMetadataExtraKind.scene,
      'samples' || 'sample' => VideoMetadataExtraKind.sample,
      'extras' || 'extra' => VideoMetadataExtraKind.extra,
      'menu' || 'menus' => VideoMetadataExtraKind.extra,
      'pv' ||
      'pvs' ||
      'ncop&nced' ||
      'ncop nced' =>
        VideoMetadataExtraKind.clip,
      '迷你动画' || '迷你動畫' => VideoMetadataExtraKind.short,
      '特典' || '特典映像' || '映像特典' => VideoMetadataExtraKind.extra,
      _ => kind,
    };
    if (kind != null) break;
  }
  if (kind == null && RegExp(r'(^|[ ._\-])trailer([ ._\-]|$)').hasMatch(stem)) {
    kind = VideoMetadataExtraKind.trailer;
  }
  if (kind == null &&
      RegExp(
        r'(^|[^a-z0-9])(ncop|nced|creditless[ ._\-]?(op|ed)|pv)\d*'
        r'([^a-z0-9]|$)',
        caseSensitive: false,
      ).hasMatch(stem)) {
    kind = VideoMetadataExtraKind.clip;
  }
  return kind == null ? null : VideoLocalExtraMatch(kind);
}
