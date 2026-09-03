/// `VideoMediaReference` 的 JSON 编解码——v94 `identity_json` 列的唯一 wire
/// 形状（BUG-2003）。
///
/// 编解码放在一起：入队/建订阅写它，管线 subtitle/scrape 阶段与订阅轮询读它，
/// 两侧共用同一份字段名，避免各写一次而悄悄漂开。解码对任何损坏/缺字段都退化
/// 成 null（调用方回退旧的「任务列重建」路径），绝不让一条陈旧行把管线炸掉。
library;

import 'dart:convert';

import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';

String encodeVideoMediaReference(VideoMediaReference reference) =>
    jsonEncode(<String, Object?>{
      'providerId': reference.providerId,
      'mediaId': reference.mediaId,
      'mediaKind': reference.mediaKind.name,
      'discoveryCategory': reference.discoveryCategory.name,
      'title': reference.title,
      if (reference.originalTitle != null)
        'originalTitle': reference.originalTitle,
      if (reference.aliases.isNotEmpty) 'aliases': reference.aliases,
      if (reference.year != null) 'year': reference.year,
      if (reference.season != null) 'season': reference.season,
      if (reference.episode != null) 'episode': reference.episode,
      if (reference.tmdbId != null) 'tmdbId': reference.tmdbId,
      if (reference.imdbId != null) 'imdbId': reference.imdbId,
      if (reference.tvdbId != null) 'tvdbId': reference.tvdbId,
      if (reference.anidbId != null) 'anidbId': reference.anidbId,
      if (reference.anilistId != null) 'anilistId': reference.anilistId,
      if (reference.bangumiId != null) 'bangumiId': reference.bangumiId,
      if (reference.externalIds.isNotEmpty)
        'externalIds': reference.externalIds,
    });

VideoMediaReference? decodeVideoMediaReference(String? json) {
  if (json == null || json.trim().isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final Map<String, Object?> map = decoded;
  final String? providerId = map['providerId'] as String?;
  final String? mediaId = map['mediaId'] as String?;
  final String? title = map['title'] as String?;
  final VideoMetadataMediaKind? mediaKind = VideoMetadataMediaKind.values
      .asNameMap()[map['mediaKind'] as String? ?? ''];
  final VideoDiscoveryCategory? category = VideoDiscoveryCategory.values
      .asNameMap()[map['discoveryCategory'] as String? ?? ''];
  if (providerId == null ||
      mediaId == null ||
      title == null ||
      mediaKind == null ||
      category == null) {
    return null;
  }
  int? intAt(String key) {
    final Object? value = map[key];
    return value is int ? value : null;
  }

  return VideoMediaReference(
    providerId: providerId,
    mediaId: mediaId,
    mediaKind: mediaKind,
    discoveryCategory: category,
    title: title,
    originalTitle: map['originalTitle'] as String?,
    aliases: <String>[
      for (final Object? alias
          in map['aliases'] as List<Object?>? ?? const <Object?>[])
        if (alias is String) alias,
    ],
    year: intAt('year'),
    season: intAt('season'),
    episode: intAt('episode'),
    tmdbId: intAt('tmdbId'),
    imdbId: map['imdbId'] as String?,
    tvdbId: intAt('tvdbId'),
    anidbId: intAt('anidbId'),
    anilistId: intAt('anilistId'),
    bangumiId: intAt('bangumiId'),
    externalIds: <String, String>{
      for (final MapEntry<String, Object?> entry
          in (map['externalIds'] as Map<String, Object?>? ??
                  const <String, Object?>{})
              .entries)
        if (entry.value is String) entry.key: entry.value as String,
    },
  );
}
