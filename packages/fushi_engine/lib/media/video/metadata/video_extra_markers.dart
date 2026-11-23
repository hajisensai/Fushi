/// 文件名 / 发布标题里的「特典」标记词表——唯一一份。
///
/// 两处共用：本地附件分类器的文件名兜底（`classifyLocalVideoExtra`，决定一个
/// 视频是挂到父作品当花絮还是单独进刮削计划）和发布级「只有特典」判据
/// （`looksLikeExtrasOnlyRelease`）。原来两边各写一份，发布级收了 CM / Menu /
/// Trailer / Bonus，文件级只认 NCOP / NCED / PV，`[Menu]` `[CM]` 文件因此被当成
/// 正片单独刮削（BUG-5260）。
///
/// 只收发布组专门用来标特典的词。`Special` `Extra` `SP` `OVA` `Movie` 这类宽词
/// **一律不收**：它们天然出现在正片标题里（`Special A`、`Extra Olympia
/// Kyklos`，BUG-1969）。`SP` / `SPs` 只在**目录名**整段出现时才算特典目录，由
/// 分类器的目录判据负责，不进这份文件名词表。
library;

import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// 拉丁字母标记：小写后按字母数字边界匹配，允许尾随数字（`PV2` `NCOP1` `CM03`）。
final RegExp _latinMarker = RegExp(
  r'(?<![a-z0-9])'
  r'(ncop|nced|creditless|pvs?|cms?|trailers?|teasers?|menus?|bonus(?:es)?)'
  r'\d*(?![a-z0-9])',
);

/// 中日文标记：子串匹配（CJK 没有词边界，`予告編` `BDメニュー` `特典映像` 都应
/// 命中）。按书写顺序检查，先命中先算。
const Map<String, VideoMetadataExtraKind> _cjkMarkers =
    <String, VideoMetadataExtraKind>{
      'ノンクレジット': VideoMetadataExtraKind.clip,
      '予告': VideoMetadataExtraKind.trailer,
      'メニュー': VideoMetadataExtraKind.extra,
      '特典': VideoMetadataExtraKind.extra,
    };

/// 明写「这是正片」的标记：`[正片+特典映像]` 这类打包标题同时出现特典词，
/// 但它本身是正片。CJK 子串匹配没有边界可依，靠这条反证排除。
final RegExp _mainFeatureMarker = RegExp('正片|本編|本篇');

/// [text]（文件名去扩展名后的部分，或一条发布标题）里的特典标记对应的附件
/// 类型；没有标记、或明写了「正片」时返回 null。
VideoMetadataExtraKind? videoExtraMarkerKind(String text) {
  final String lower = text.toLowerCase();
  if (_mainFeatureMarker.hasMatch(lower)) return null;
  final RegExpMatch? latin = _latinMarker.firstMatch(lower);
  if (latin != null) return _latinKind(latin.group(1)!);
  for (final MapEntry<String, VideoMetadataExtraKind> marker
      in _cjkMarkers.entries) {
    if (lower.contains(marker.key)) return marker.value;
  }
  return null;
}

VideoMetadataExtraKind _latinKind(String token) {
  if (token.startsWith('trailer')) return VideoMetadataExtraKind.trailer;
  if (token.startsWith('teaser')) return VideoMetadataExtraKind.teaser;
  if (token.startsWith('menu') || token.startsWith('bonus')) {
    return VideoMetadataExtraKind.extra;
  }
  // ncop / nced / creditless / pv / cm：片头片尾、宣传片、广告。
  return VideoMetadataExtraKind.clip;
}
