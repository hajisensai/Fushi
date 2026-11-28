/// 书 / 漫画 / 游戏合集（合集网格详情页）的「横幅…」面板装配，面板本体见
/// `banner_picker_sheet.dart`。合集自己的横幅是附加图组（`media_images` 的
/// collection 归属）里的 backdrop：合集详情页 hero、书架 / 首页的合集色块都读它。
///
/// - **在线**：按合集的领头成员认作品——有书就取第一本书的系列横幅（与书的面板同一
///   条：AniList / MangaBaka，`book_banner_sources.dart`），否则第一个游戏的 VNDB
///   截图（`game_banner_sources.dart`）。只在「在线服务」模块开着时提供。
/// - **合集内**：各成员已有的横幅（书 / 游戏的 `item_images` backdrop、视频成员的附加
///   图组与作品图组 backdrop），只留横版的。
/// - **写入**：[MediaImageUserStore] 用户口径（v184 来源锁）；移除 = 只移除用户选的
///   那张并解锁。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:fushi_engine/media/metadata/image_download.dart'
    show downloadImageToTempFile;
import 'package:fushi_engine/media/video/media_image_user_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataImageKind;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/banner/banner_local_images.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/media/banner/banner_target_writes.dart';
import 'package:fushi/src/media/banner/book_banner_sources.dart';
import 'package:fushi/src/media/banner/game_banner_sources.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/mining/metadata/adapters/vndb_adapter.dart';
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;

/// 合集内候选：按成员顺序收各成员已有的横幅（每个成员 position 序），只留横版的。
Future<List<BannerCandidate>> loadCollectionBannerFromMembers({
  required FushiDatabase db,
  required int collectionId,
}) async {
  final List<BannerLocalImage> images = <BannerLocalImage>[];
  int member = 0;
  for (final MediaCollectionItemRow item in await db.getCollectionItems(
    collectionId,
  )) {
    member++;
    final String label = t.media_banner_image_label(index: member);
    final List<String> paths = <String>[];
    if (item.mediaType == MediaKind.video.dbValue) {
      for (final MediaImageRow row in await db.getMediaImagesForBook(
        item.entryKey,
      )) {
        if (row.kind == MediaImageKind.backdrop.dbValue) paths.add(row.path);
      }
      final VideoMetadataWorkRow? work = await db.getVideoMetadataWorkByBook(
        item.entryKey,
      );
      if (work != null) {
        for (final VideoMetadataImageRow row in await db.getVideoMetadataImages(
          workId: work.id,
        )) {
          if (row.kind == VideoMetadataImageKind.backdrop.name) {
            if (row.localPath case final String path) paths.add(path);
          }
        }
      }
    } else if (MediaKind.tryParse(item.mediaType) case final MediaKind kind
        when kind == MediaKind.epub ||
            kind == MediaKind.srt ||
            kind == MediaKind.game) {
      final List<ItemImageRow> rows =
          (await db.getItemImages(kind, item.entryKey))
              .where(
                (ItemImageRow r) => r.kind == MediaImageKind.backdrop.dbValue,
              )
              .toList()
            ..sort(
              (ItemImageRow a, ItemImageRow b) =>
                  a.position.compareTo(b.position),
            );
      paths.addAll(rows.map((ItemImageRow r) => r.path));
    }
    for (final String path in paths) {
      images.add((path: path, label: label));
    }
  }
  return loadLocalBannerCandidates(images, idPrefix: 'collection-member');
}

/// 装配合集 [collection] 的面板。[onlineEnabled] = 「在线服务」模块开着；
/// [thumbnailsDirectory] 给书的系列识别读卷封面刮削层。其余是测试接缝。
Future<BannerPickerTarget> loadCollectionBannerPickerTarget({
  required FushiDatabase db,
  required MediaCollectionRow collection,
  required bool onlineEnabled,
  required Directory thumbnailsDirectory,
  MediaImageUserStore? store,
  BookMetadataScraper Function()? scraperFactory,
  VndbMetadataAdapter Function()? vndbFactory,
  Future<File> Function(String url) download = downloadImageToTempFile,
}) async {
  final MediaImageOwner owner = MediaImageOwner.collection(collection.id);
  final MediaImageUserStore writer =
      store ?? MediaImageUserStore(db, downloadImage: download);
  final MediaImageRow? current = await currentMediaImageBackdrop(db, owner);
  final List<MediaCollectionItemRow> items = await db.getCollectionItems(
    collection.id,
  );
  final String? leadBook = items
      .where(
        (MediaCollectionItemRow r) => r.mediaType == MediaKind.epub.dbValue,
      )
      .map((MediaCollectionItemRow r) => r.entryKey)
      .firstOrNull;
  final String? leadGame = items
      .where(
        (MediaCollectionItemRow r) => r.mediaType == MediaKind.game.dbValue,
      )
      .map((MediaCollectionItemRow r) => r.entryKey)
      .firstOrNull;
  Future<List<BannerCandidate>> Function()? online;
  if (onlineEnabled && leadBook != null) {
    online = () async {
      final EpubBookRow? book = await db.getEpubBookByUid(leadBook);
      final BookMetadataScraper scraper =
          scraperFactory?.call() ?? BookMetadataScraper();
      try {
        return await loadBookBannerOnlineCandidates(
          ids: await identifyBookBannerSeries(
            db: db,
            key: ItemScrapeKey(MediaKind.epub, leadBook),
            bookKey: book?.bookKey,
            artStore: BookArtStore.of(thumbnailsDirectory),
          ),
          title: collection.name,
          scraper: scraper,
          download: download,
        );
      } finally {
        if (scraperFactory == null) scraper.close();
      }
    };
  } else if (onlineEnabled && leadGame != null) {
    online = () => loadGameBannerOnlineCandidates(
      db: db,
      gameId: leadGame,
      vndbFactory: vndbFactory,
      download: download,
    );
  }
  return BannerPickerTarget(
    fromWorkLabel: t.media_banner_source_from_collection,
    fromWorkEmptyMessage: t.media_banner_collection_empty,
    fromWorkFailedMessage: t.media_banner_local_failed,
    onlineEmptyMessage: leadBook == null
        ? t.media_banner_game_online_empty
        : null,
    current: current == null ? null : resizedFileImage(File(current.path)),
    currentUserChosen: current?.userChosen ?? false,
    loadOnline: online,
    loadFromWork: () =>
        loadCollectionBannerFromMembers(db: db, collectionId: collection.id),
    attribution: bookBannerAttribution,
    download: download,
    apply: (File file, {String? sourceUrl}) =>
        applyMediaImageBannerFile(writer, owner, file, sourceUrl: sourceUrl),
    clear: current?.userChosen ?? false
        ? () => writer.clearUserImage(owner, MediaImageKind.backdrop)
        : null,
  );
}

/// 合集「横幅…」的完整一步：装配 → 弹面板。返回横幅是否变了（宿主据此刷新书架 /
/// 游戏库的合集色块）。书架与游戏库两个宿主共用。
Future<bool> pickCollectionBanner({
  required BuildContext context,
  required FushiDatabase db,
  required MediaCollectionRow collection,
  required bool onlineEnabled,
  required Directory thumbnailsDirectory,
}) async {
  final BannerPickerTarget target = await loadCollectionBannerPickerTarget(
    db: db,
    collection: collection,
    onlineEnabled: onlineEnabled,
    thumbnailsDirectory: thumbnailsDirectory,
  );
  if (!context.mounted) return false;
  return showBannerPickerSheet(context: context, target: target);
}
