import 'dart:io';

import 'package:drift/drift.dart' show BooleanExpressionOperators, OrderingTerm;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/metadata/book_metadata_scraper.dart'
    show BookScrapeSource;
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;

/// 单个条目（书 / 漫画 / 字幕书 / 游戏）在详情页要展示的刮削数据：
/// `item_scrape_meta` 行 + `item_images` 里 position 最小且文件还在的横版背景 /
/// 艺术字（schema v155）。详情页一次 [load] 取好、文件存在性异步探好，build 零 IO。
@immutable
class ItemScrapeDetail {
  const ItemScrapeDetail({this.meta, this.backdropPath, this.logoPath});

  /// 没有任何刮削数据。
  static const ItemScrapeDetail empty = ItemScrapeDetail();

  final ItemScrapeMetaRow? meta;
  final String? backdropPath;
  final String? logoPath;

  /// 资料行 / 背景图 / 艺术字一项都没有（详情页据此给「刮削」行动点）。
  bool get isEmpty => meta == null && backdropPath == null && logoPath == null;

  ImageProvider? get backdrop =>
      backdropPath == null ? null : resizedFileImage(File(backdropPath!));

  ImageProvider? get logo =>
      logoPath == null ? null : resizedFileImage(File(logoPath!));

  /// 读 [key] 的资料行与附加图。
  static Future<ItemScrapeDetail> load(
    FushiDatabase db,
    ItemScrapeKey key,
  ) async {
    final ItemScrapeMetaRow? meta = await db.getItemScrapeMeta(
      key.mediaType,
      key.entryKey,
    );
    final List<ItemImageRow> images = await db.getItemImages(
      key.mediaType,
      key.entryKey,
    );
    Future<String?> firstExisting(MediaImageKind kind) async {
      final List<ItemImageRow> rows =
          images
              .where(
                (ItemImageRow r) => r.kind == kind.dbValue && r.path.isNotEmpty,
              )
              .toList()
            ..sort(
              (ItemImageRow a, ItemImageRow b) =>
                  a.position.compareTo(b.position),
            );
      for (final ItemImageRow row in rows) {
        if (await File(row.path).exists()) return row.path;
      }
      return null;
    }

    return ItemScrapeDetail(
      meta: meta,
      backdropPath: await firstExisting(MediaImageKind.backdrop),
      logoPath: await firstExisting(MediaImageKind.logo),
    );
  }

  /// 先读 [key] 自己的资料；一项都没有时退到它所属合集（作品）的刮削资料
  /// （`collection_scrape_meta` + 合集附加图组 `media_images`），漫画卷 / 系列里的
  /// 单本没单独刮过也能显示作品资料。合集身份按成员表 `(mediaType, entryKey)`
  /// 找，[legacyEntryKeys] 补旧口径的成员键（v83 前 epub 成员存 bookKey）；属于
  /// 多个合集时取 id 最小的那个有资料的。
  static Future<ItemScrapeDetail> loadWithCollectionFallback(
    FushiDatabase db,
    ItemScrapeKey key, {
    List<String> legacyEntryKeys = const <String>[],
  }) async {
    final ItemScrapeDetail own = await load(db, key);
    if (!own.isEmpty) return own;
    final List<String> keys = <String>[
      key.entryKey,
      for (final String k in legacyEntryKeys)
        if (k.isNotEmpty && k != key.entryKey) k,
    ];
    final List<MediaCollectionItemRow> members =
        await (db.select(db.mediaCollectionItems)
              ..where(
                ($MediaCollectionItemsTable m) =>
                    m.mediaType.equals(key.mediaType.dbValue) &
                    m.entryKey.isIn(keys),
              )
              ..orderBy(<OrderingTerm Function($MediaCollectionItemsTable)>[
                ($MediaCollectionItemsTable m) =>
                    OrderingTerm(expression: m.collectionId),
              ]))
            .get();
    for (final int collectionId in <int>{
      for (final MediaCollectionItemRow m in members) m.collectionId,
    }) {
      final ItemScrapeDetail work = await _loadCollection(
        db,
        collectionId,
        key,
      );
      if (!work.isEmpty) return work;
    }
    return own;
  }

  /// 合集资料按单本资料的形状读（展示层只认一种行）：资料行映射成
  /// [ItemScrapeMetaRow]，背景 / 艺术字取合集附加图组里 position 最小且文件还在
  /// 的那张，背景再退到资料行自带的 `backdropPath`。
  static Future<ItemScrapeDetail> _loadCollection(
    FushiDatabase db,
    int collectionId,
    ItemScrapeKey key,
  ) async {
    final CollectionScrapeMetaRow? row = await db.getCollectionScrapeMeta(
      collectionId,
    );
    final List<MediaImageRow> images = await db.getMediaImagesForCollection(
      collectionId,
    );
    Future<String?> firstExisting(MediaImageKind kind) async {
      for (final MediaImageRow r in images) {
        if (r.kind != kind.dbValue || r.path.isEmpty) continue;
        if (await File(r.path).exists()) return r.path;
      }
      return null;
    }

    String? backdrop = await firstExisting(MediaImageKind.backdrop);
    final String? rowBackdrop = row?.backdropPath;
    if (backdrop == null &&
        rowBackdrop != null &&
        rowBackdrop.isNotEmpty &&
        await File(rowBackdrop).exists()) {
      backdrop = rowBackdrop;
    }
    return ItemScrapeDetail(
      meta: row == null
          ? null
          : ItemScrapeMetaRow(
              mediaType: key.mediaType.dbValue,
              entryKey: key.entryKey,
              source: row.source,
              subjectId: row.subjectId,
              title: row.title,
              originalTitle: row.originalTitle,
              summary: row.summary,
              airDate: row.airDate,
              rating: row.rating,
              ratingCount: row.ratingCount,
              tagsJson: row.tagsJson,
              detailUrl: row.detailUrl,
              scrapedAt: row.scrapedAt.millisecondsSinceEpoch,
            ),
      backdropPath: backdrop,
      logoPath: await firstExisting(MediaImageKind.logo),
    );
  }
}

/// `item_scrape_meta.source` 的显示名（品牌名，不进 i18n）：书籍刮削源按
/// [BookScrapeSource.name]，游戏元数据源 key（bgm / vndb / dlsite）与脚本 / 控制通道
/// 写入的常见源 key（anilist / mal / mangabaka …，大小写不敏感）各自映射成品牌写法；
/// 手动写入（[ItemScrapeStore.manualSource]）与空值不显示（null）；不认识的 key
/// 原样显示。
String? itemScrapeSourceLabel(String? source) {
  final String raw = source?.trim() ?? '';
  if (raw.isEmpty || raw == ItemScrapeStore.manualSource) return null;
  for (final BookScrapeSource s in BookScrapeSource.values) {
    if (s.name == raw) return s.label;
  }
  return switch (raw.toLowerCase()) {
    'bgm' || 'bangumi' => BookScrapeSource.bangumi.label,
    'dlsite' => BookScrapeSource.dlsite.label,
    'vndb' => 'VNDB',
    'anilist' => 'AniList',
    'mal' || 'myanimelist' => 'MyAnimeList',
    'mangabaka' => 'MangaBaka',
    'mangaupdates' || 'mu' => 'MangaUpdates',
    'kitsu' => 'Kitsu',
    'mangadex' => 'MangaDex',
    'tmdb' => 'TMDB',
    'anidb' => 'AniDB',
    'openlibrary' => 'Open Library',
    'googlebooks' || 'google_books' => 'Google Books',
    _ => raw,
  };
}
