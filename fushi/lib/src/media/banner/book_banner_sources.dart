/// 书 / 漫画的「横幅…」面板装配：在线来源、书中来源与写入口
/// （[BannerPickerTarget]），面板本体见 `banner_picker_sheet.dart`。
///
/// - **在线**：先认系列——条目刮削资料的来源 id（AniList / MangaBaka）、追踪映射里
///   这本书的 AniList / MangaBaka 链接、卷封面刮削层记下的 MangaBaka 系列；认出了就
///   取 AniList 的 `bannerImage` 与 MangaBaka 的**全部**横幅（批量卷封面只留最大那
///   张，这里都给用户挑）。一个都认不出时按书名（去卷号）搜，两边各取前几条带横幅
///   的系列、卡片角标写明系列名。只在「在线服务」模块开着时提供（与刮削同一道门；
///   取元数据图不属于 iOS 商店合规受限的三类能力）。
/// - **书中**：漫画横版页 / EPUB 卷首彩页与横版插图（`banner_book_scan.dart`，扫描在
///   后台 isolate）。PDF 不提供（要逐页渲染，代价与收益不成比例）。
/// - **写入**：`ItemScrapeStore` 用户口径（上来源锁，之后的元数据刮削 / 卷封面横幅
///   都不覆盖）；移除 = 解锁。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart'
    show EpubBook, EpubImageRef, kEpubCoverChapterIndex;
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:fushi_engine/media/metadata/books/book_search_query.dart'
    show bookSearchSeriesTitle;
import 'package:fushi_engine/media/metadata/image_download.dart'
    show downloadImageToTempFile;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/banner/banner_book_scan.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/media/banner/banner_target_writes.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/reader/reader_collection_volumes.dart'
    show parseVolumeBookForPeekOffUi;
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;
import 'package:fushi/src/utils/net/app_http_image.dart';

/// 追踪映射 / 刮削来源里 AniList 与 MangaBaka 的名字（`media_tracking_mappings.provider`
/// / `item_scrape_meta.source` / 卷封面刮削层 `source` 同一串）。
const String _aniList = 'anilist';
const String _mangaBaka = 'mangabaka';

/// 按书名搜（认不出系列时）每个源取几条。
const int _searchFallbackAniList = 5;
const int _searchFallbackMangaBaka = 2;

/// 「书中」网格预览的解码宽度（逻辑上一格 ≤ 240dp，2x 屏够用）。
const int _bookPreviewWidth = 480;

/// 一本书认出来的系列（各源 id，书序 / 优先级序，去重）。
@immutable
class BookBannerSeriesIds {
  const BookBannerSeriesIds({
    this.aniList = const <String>[],
    this.mangaBaka = const <String>[],
  });

  final List<String> aniList;
  final List<String> mangaBaka;

  bool get isEmpty => aniList.isEmpty && mangaBaka.isEmpty;
}

/// 认 [key] 的系列：刮削资料来源 id → 追踪映射链接 → 卷封面刮削层的 MangaBaka 系列。
/// [bookKey] 是 EPUB / 漫画的书键（字幕书没有就传 null，只看刮削资料）。
Future<BookBannerSeriesIds> identifyBookBannerSeries({
  required FushiDatabase db,
  required ItemScrapeKey key,
  String? bookKey,
  BookArtStore? artStore,
}) async {
  final List<String> aniList = <String>[];
  final List<String> mangaBaka = <String>[];
  void add(String? source, String? id) {
    final String trimmed = id?.trim() ?? '';
    if (trimmed.isEmpty) return;
    final List<String>? into = switch (source) {
      _aniList => aniList,
      _mangaBaka => mangaBaka,
      _ => null,
    };
    if (into != null && !into.contains(trimmed)) into.add(trimmed);
  }

  final ItemScrapeMetaRow? meta = await db.getItemScrapeMeta(
    key.mediaType,
    key.entryKey,
  );
  add(meta?.source, meta?.subjectId);
  if (bookKey != null && bookKey.isNotEmpty) {
    for (final MediaTrackingMappingRow m in await MediaTrackingRepository(
      db,
    ).bookMappings(bookKey)) {
      add(m.provider, '${m.subjectId}');
    }
    final BookArtRecord? art = artStore?.recordFor(bookKey);
    if (art != null) add(art.source, art.seriesId);
  }
  return BookBannerSeriesIds(aniList: aniList, mangaBaka: mangaBaka);
}

/// 在线候选：认出了系列就取这些系列的横幅；一个都没认出时按 [title]（去卷号）搜。
/// 某个源失败不挡别的源；全部失败且一张都没有时抛第一个错误。
Future<List<BannerCandidate>> loadBookBannerOnlineCandidates({
  required BookBannerSeriesIds ids,
  required String title,
  required BookMetadataScraper scraper,
  required Future<File> Function(String url) download,
}) async {
  final List<BannerCandidate> out = <BannerCandidate>[];
  final Set<String> seenUrls = <String>{};
  final List<BookScrapeException> errors = <BookScrapeException>[];

  void addCandidate({
    required String id,
    required String url,
    required String label,
    String? thumbnailUrl,
    int? width,
    int? height,
  }) {
    if (!seenUrls.add(url)) return;
    out.add(
      BannerCandidate(
        id: id,
        preview: AppHttpImage(thumbnailUrl ?? url),
        resolve: () => download(url),
        label: label,
        width: width,
        height: height,
        sourceUrl: url,
      ),
    );
  }

  Future<void> guard(Future<void> Function() body) async {
    try {
      await body();
    } on BookScrapeException catch (e) {
      errors.add(e);
    }
  }

  Future<void> mangaBakaSeries(String seriesId, String label) =>
      guard(() async {
        final List<BookBannerImage> banners = await scraper
            .fetchMangaBakaBanners(seriesId);
        for (int i = 0; i < banners.length; i++) {
          addCandidate(
            id: 'mangabaka-$seriesId-$i',
            url: banners[i].url,
            label: label,
            thumbnailUrl: banners[i].thumbnailUrl,
            width: banners[i].width,
            height: banners[i].height,
          );
        }
      });

  if (!ids.isEmpty) {
    for (final String id in ids.aniList) {
      await guard(() async {
        final BookScrapeCandidate? c = await scraper.fetchCatalogById(
          BookScrapeSource.anilist,
          id,
        );
        final String? url = c?.bannerUrl;
        if (url != null && url.isNotEmpty) {
          addCandidate(id: 'anilist-$id', url: url, label: 'AniList');
        }
      });
    }
    for (final String id in ids.mangaBaka) {
      await mangaBakaSeries(id, 'MangaBaka');
    }
  } else {
    final String query = bookSearchSeriesTitle(title).trim();
    if (query.isNotEmpty) {
      await guard(() async {
        for (final BookScrapeCandidate c in await scraper.searchAniList(
          query,
          limit: _searchFallbackAniList,
        )) {
          final String? url = c.bannerUrl;
          if (url == null || url.isEmpty) continue;
          addCandidate(
            id: 'anilist-${c.subjectId}',
            url: url,
            label: 'AniList · ${c.title}',
          );
        }
      });
      await guard(() async {
        for (final BookScrapeCandidate c in await scraper.searchMangaBaka(
          query,
          limit: _searchFallbackMangaBaka,
        )) {
          await mangaBakaSeries(c.subjectId, 'MangaBaka · ${c.title}');
        }
      });
    }
  }
  if (out.isEmpty && errors.isNotEmpty) throw errors.first;
  return out;
}

/// 书中候选：漫画横版页 / EPUB 彩页与横版插图（扫描在后台 isolate）。PDF 与解压
/// 目录为空的行（字幕书配对壳等）为空表。
Future<List<BannerCandidate>> loadBookBannerFromBook(EpubBookRow row) async {
  if (row.extractDir.isEmpty) return const <BannerCandidate>[];
  final List<BannerBookPick> picks;
  switch (BookFormat.parseOrEpub(row.format)) {
    case BookFormat.pdf:
      return const <BannerCandidate>[];
    case BookFormat.manga:
      picks = await compute(scanMangaBookForBanners, (
        extractDir: row.extractDir,
        epubPath: row.epubPath,
      ));
    case BookFormat.epub:
      final EpubBook book = await parseVolumeBookForPeekOffUi(row.extractDir);
      final List<EpubImageRef> refs = book.images;
      picks = await compute(scanEpubImagesForBanners, (
        extractDir: row.extractDir,
        srcs: <String>[for (final EpubImageRef r in refs) r.src],
        cover: <bool>[
          for (final EpubImageRef r in refs)
            r.chapterIndex == kEpubCoverChapterIndex,
        ],
      ));
  }
  return <BannerCandidate>[
    for (final BannerBookPick pick in picks)
      BannerCandidate(
        id: 'book-${pick.ordinal}',
        preview: resizedFileImage(File(pick.path), width: _bookPreviewWidth),
        resolve: () async => File(pick.path),
        label: pick.isPage
            ? t.media_banner_page_label(page: pick.ordinal)
            : t.media_banner_image_label(index: pick.ordinal),
        width: pick.width,
        height: pick.height,
      ),
  ];
}

/// 书的在线候选里有 MangaBaka 的图时要显示的署名（数据源许可要求）；没有为 null。
String? bookBannerAttribution(List<BannerCandidate> online) =>
    online.any((BannerCandidate c) => c.id.startsWith('mangabaka-'))
    ? t.book_scrape_mangabaka_attribution
    : null;

/// 装配一本书 / 漫画（/ 字幕书）的面板：读当前横幅与来源锁，接上在线 / 书中来源与
/// [ItemScrapeStore] 用户口径的写入口。
///
/// [title] 是显示名（认不出系列时的搜索词）；[onlineEnabled] = 「在线服务」模块开着。
/// [scraperFactory] / [store] / [download] 是测试接缝。
Future<BannerPickerTarget> loadBookBannerPickerTarget({
  required FushiDatabase db,
  required ItemScrapeKey key,
  required String title,
  required bool onlineEnabled,
  required Directory thumbnailsDirectory,
  ItemScrapeStore? store,
  BookMetadataScraper Function()? scraperFactory,
  Future<File> Function(String url) download = downloadImageToTempFile,
}) async {
  final ItemScrapeStore writer =
      store ?? ItemScrapeStore(db, downloadImage: download);
  final ItemImageRow? current = await currentItemBackdrop(db, key);
  final EpubBookRow? book = key.mediaType == MediaKind.epub
      ? await db.getEpubBookByUid(key.entryKey)
      : null;
  final bool fromBook =
      book != null &&
      book.extractDir.isNotEmpty &&
      BookFormat.parseOrEpub(book.format) != BookFormat.pdf;
  return BannerPickerTarget(
    fromWorkLabel: t.media_banner_source_from_book,
    current: current == null ? null : resizedFileImage(File(current.path)),
    currentUserChosen: current?.userChosen ?? false,
    loadOnline: onlineEnabled
        ? () async {
            final BookMetadataScraper scraper =
                scraperFactory?.call() ?? BookMetadataScraper();
            try {
              return await loadBookBannerOnlineCandidates(
                ids: await identifyBookBannerSeries(
                  db: db,
                  key: key,
                  bookKey: book?.bookKey,
                  artStore: BookArtStore.of(thumbnailsDirectory),
                ),
                title: title,
                scraper: scraper,
                download: download,
              );
            } finally {
              if (scraperFactory == null) scraper.close();
            }
          }
        : null,
    loadFromWork: fromBook ? () => loadBookBannerFromBook(book) : null,
    attribution: bookBannerAttribution,
    download: download,
    apply: (File file, {String? sourceUrl}) =>
        applyItemBannerFile(writer, key, file, sourceUrl: sourceUrl),
    clear: () => writer.clearUserImage(key, MediaImageKind.backdrop),
  );
}
