/// 读取旧 `collection_scrape_meta` 投影，供合集详情继续展示历史资料。
library;

import 'dart:convert';

import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi_core/fushi_core.dart';

/// 将历史合集资料行还原为只读领域对象；未知来源只按本地资料兼容。
ScrapeMetadata? decodeCollectionScrapeMeta(CollectionScrapeMetaRow? row) {
  if (row == null) return null;
  return ScrapeMetadata(
    source: ScrapeSource.values.asNameMap()[row.source] ?? ScrapeSource.local,
    subjectId: row.subjectId,
    title: row.title,
    originalTitle: row.originalTitle,
    summary: row.summary,
    airDate: row.airDate,
    rating: row.rating,
    ratingCount: row.ratingCount,
    episodeCount: row.episodeCount,
    tags: _decodeJsonList<ScrapeTag>(row.tagsJson, ScrapeTag.fromJson),
    infobox: _decodeJsonList<ScrapeInfoboxEntry>(
      row.infoboxJson,
      ScrapeInfoboxEntry.fromJson,
    ),
    detailUrl: row.detailUrl,
  );
}

List<T> _decodeJsonList<T>(String? json, T? Function(Object?) fromJson) {
  if (json == null || json.isEmpty) return <T>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } catch (_) {
    return <T>[];
  }
  if (decoded is! List<Object?>) return <T>[];
  return <T>[
    for (final Object? item in decoded)
      if (fromJson(item) case final T value) value,
  ];
}
