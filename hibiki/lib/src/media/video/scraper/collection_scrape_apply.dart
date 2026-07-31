/// 合集刮削产物落库（BUG-1305）：封面 + 横版背景 + 条目资料 + 合集名回写。
///
/// 单独成文件而不是塞进页面：这是**领域写入规则**（三张写入必须同成同败、名字何时
/// 该被回写），页面只是它的一个调用点。放这里让 widget 测试与 DB 测试都能直接调，
/// 不必把整个视频库页拖起来。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 把一次合集刮削的产物写进库。
///
/// 三处写入包在一个事务里**同成同败**：封面列、资料行、合集名。半截状态（封面换了
/// 但资料没写 / 名字改了但封面还是旧的）会让用户看到一个自相矛盾的详情页，且
/// 「已刮过」的判据（资料行是否存在）与实际不符，下次进页面又当成没刮过。
///
/// **名字回写**：合集刮削只有手动入口——用户主动打开「在线匹配封面」、亲手选中某个
/// 条目点「使用」，这就是「这个合集就是这部作品」的明确表达，把文件夹名换成条目正名
/// 正是他要的结果（自动刮削 `VideoScrapeAutoService` 全程不碰合集，不存在后台悄悄
/// 改名这条路）。条目正名为空则**保留原名**——绝不把合集改成空名字。
///
/// 原始条目名同时独立存在 `collection_scrape_meta.title` 里：用户事后再手动改合集名
/// 不会篡改「刮到的条目叫什么」这一事实。
Future<void> applyCollectionScrape(
  HibikiDatabase db,
  int collectionId,
  CollectionScrapeResult result,
) {
  final ScrapeMetadata meta = result.metadata;
  final String scrapedTitle = meta.title.trim();
  return db.transaction(() async {
    await db.updateMediaCollectionCoverPath(collectionId, result.coverPath);
    await db.upsertCollectionScrapeMeta(
      CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(collectionId),
        source: meta.source.name,
        subjectId: meta.subjectId,
        title: meta.title,
        originalTitle: Value<String?>(meta.originalTitle),
        summary: Value<String?>(meta.summary),
        airDate: Value<String?>(meta.airDate),
        rating: Value<double?>(meta.rating),
        ratingCount: Value<int?>(meta.ratingCount),
        episodeCount: Value<int?>(meta.episodeCount),
        tagsJson: Value<String?>(encodeScrapeTags(meta.tags)),
        infoboxJson: Value<String?>(encodeScrapeInfobox(meta.infobox)),
        backdropPath: Value<String?>(result.backdropPath),
        detailUrl: Value<String?>(meta.detailUrl),
        scrapedAt: DateTime.now(),
      ),
    );
    if (scrapedTitle.isNotEmpty) {
      await db.renameMediaCollection(collectionId, scrapedTitle);
    }
  });
}

/// 标签列表 → JSON 列；空列表存 NULL（区别于「刮到了但一个标签都没有」的空数组，
/// 读回时二者都是空列表，存 NULL 更省且与 video_scrape_meta 同规矩）。
String? encodeScrapeTags(List<ScrapeTag> tags) => tags.isEmpty
    ? null
    : jsonEncode(<Map<String, Object?>>[
        for (final ScrapeTag t in tags) t.toJson(),
      ]);

/// infobox 列表 → JSON 列；空列表存 NULL。
String? encodeScrapeInfobox(List<ScrapeInfoboxEntry> infobox) => infobox.isEmpty
    ? null
    : jsonEncode(<Map<String, Object?>>[
        for (final ScrapeInfoboxEntry e in infobox) e.toJson(),
      ]);

/// 读回合集刮削资料为领域对象 + 横版背景路径；未刮过返回 null。
///
/// JSON 列损坏时该列降级为空列表（其余字段照常返回），不因一列坏掉丢整条资料——
/// 与 `VideoBookRepository.scrapeMetadata` 同一容错规矩。
({ScrapeMetadata metadata, String? backdropPath})? decodeCollectionScrapeMeta(
  CollectionScrapeMetaRow? row,
) {
  if (row == null) return null;
  return (
    metadata: ScrapeMetadata(
      source:
          ScrapeSource.values.asNameMap()[row.source] ?? ScrapeSource.bangumi,
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
    ),
    backdropPath: row.backdropPath,
  );
}

/// 解 JSON 数组列为领域对象列表；null / 非数组 / 解析异常一律降级为空列表。
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
