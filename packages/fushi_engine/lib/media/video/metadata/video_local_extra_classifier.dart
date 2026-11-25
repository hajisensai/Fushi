library;

import 'package:fushi_engine/media/video/metadata/video_extra_markers.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:path/path.dart' as p;

class VideoLocalExtraMatch {
  const VideoLocalExtraMatch(this.kind);

  final VideoMetadataExtraKind kind;
}

/// Kodi 目录、发布组特典目录，以及文件名带特典标记（NCOP/NCED/PV/CM/Menu/
/// Trailer 等，见 [videoExtraMarkerKind]）的本地附件分类。
///
/// 这里只判断“不是正片/分集”，不猜作品归属；归属仍由来源索引器依据唯一作品根决定。
VideoLocalExtraMatch? classifyLocalVideoExtra(String path) {
  final List<String> segments = p
      .split(p.normalize(path))
      .map(
        (String value) => value.toLowerCase().replaceAll(RegExp(r'[_-]+'), ' '),
      )
      .toList(growable: false);
  VideoMetadataExtraKind? kind;
  for (final String segment in segments.reversed) {
    kind = switch (segment.trim()) {
      'trailers' || 'trailer' => VideoMetadataExtraKind.trailer,
      'featurettes' || 'featurette' => VideoMetadataExtraKind.featurette,
      'behind the scenes' => VideoMetadataExtraKind.behindTheScenes,
      'deleted scenes' ||
      'deleted scene' => VideoMetadataExtraKind.deletedScene,
      'interviews' || 'interview' => VideoMetadataExtraKind.interview,
      'shorts' || 'short' => VideoMetadataExtraKind.short,
      'scenes' || 'scene' => VideoMetadataExtraKind.scene,
      'samples' || 'sample' => VideoMetadataExtraKind.sample,
      'extras' || 'extra' => VideoMetadataExtraKind.extra,
      'menu' || 'menus' => VideoMetadataExtraKind.extra,
      'pv' ||
      'pvs' ||
      'ncop&nced' ||
      'ncop nced' => VideoMetadataExtraKind.clip,
      '迷你动画' || '迷你動畫' => VideoMetadataExtraKind.short,
      '特典' || '特典映像' || '映像特典' => VideoMetadataExtraKind.extra,
      // 发布组 BDRip 的特典目录（DBD-Raws / VCB-Studio 等的 `SP` / `SPs`），与下载
      // 整理器的特典目录词表同口径。不认的话目录里 `[Grp][Title][SP][01]` 会被
      // 当成独立剧集进刮削计划，按解析出的标题「SP」误绑到无关剧（BUG-5035）。
      'sp' || 'sps' => VideoMetadataExtraKind.extra,
      _ => kind,
    };
    if (kind != null) break;
  }
  // 文件名兜底：与发布级「只有特典」判据共用一份标记词表（BUG-5260），
  // `[Menu]` `[CM]` `[NCED]` `PV2` 这类同目录特典文件也认得出。
  kind ??= videoExtraMarkerKind(p.basenameWithoutExtension(path));
  return kind == null ? null : VideoLocalExtraMatch(kind);
}
