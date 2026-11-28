/// 「横幅…」面板各媒体装配共用的「当前横幅 / 用户写入」两件事，按横幅存在哪张表分：
///
/// - `item_images`（书 / 漫画 / 字幕书 / 游戏，v183 来源锁）：经 [ItemScrapeStore]
///   用户口径；
/// - `media_images`（视频作品 / 合集，v184 来源锁）：经 [MediaImageUserStore]。
///
/// 写入后都清本地图片缓存（同一归属再换一张同扩展名的图会落在同一路径），详情页 /
/// 首页立刻画新图。与设计系统无关（纯数据装配）。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:fushi_engine/media/video/media_image_user_store.dart';

import 'package:fushi/src/utils/cover_image.dart' show evictLocalCoverCache;

/// [key] 当前铺着的横幅：backdrop 里 position 最小、文件还在的那行；没有为 null。
Future<ItemImageRow?> currentItemBackdrop(
  FushiDatabase db,
  ItemScrapeKey key,
) async {
  ItemImageRow? current;
  for (final ItemImageRow row in await db.getItemImages(
    key.mediaType,
    key.entryKey,
  )) {
    if (row.kind != MediaImageKind.backdrop.dbValue) continue;
    if (current != null && row.position >= current.position) continue;
    if (await File(row.path).exists()) current = row;
  }
  return current;
}

/// 用户把 [file] 设为 [key] 的横幅（上锁），清图片缓存。
Future<void> applyItemBannerFile(
  ItemScrapeStore store,
  ItemScrapeKey key,
  File file, {
  String? sourceUrl,
}) async {
  final String dest = await store.setUserImageFromFile(
    key,
    MediaImageKind.backdrop,
    file,
    sourceUrl: sourceUrl,
  );
  await evictLocalCoverCache(dest);
}

/// [owner] 的附加图组里文件还在的横幅：用户选的那张优先，否则 position 最小的；
/// [userChosenOnly] = 只认用户选的。没有为 null。
Future<MediaImageRow?> currentMediaImageBackdrop(
  FushiDatabase db,
  MediaImageOwner owner, {
  bool userChosenOnly = false,
}) async {
  final List<MediaImageRow> rows =
      (owner.collectionId != null
              ? await db.getMediaImagesForCollection(owner.collectionId!)
              : await db.getMediaImagesForBook(owner.bookUid!))
          .where(
            (MediaImageRow r) =>
                r.kind == MediaImageKind.backdrop.dbValue &&
                r.path.isNotEmpty &&
                (r.userChosen || !userChosenOnly),
          )
          .toList()
        ..sort((MediaImageRow a, MediaImageRow b) {
          if (a.userChosen != b.userChosen) return a.userChosen ? -1 : 1;
          return a.position.compareTo(b.position);
        });
  for (final MediaImageRow row in rows) {
    if (await File(row.path).exists()) return row;
  }
  return null;
}

/// 用户把 [file] 设为 [owner] 的横幅（上锁），清图片缓存。
Future<void> applyMediaImageBannerFile(
  MediaImageUserStore store,
  MediaImageOwner owner,
  File file, {
  String? sourceUrl,
}) async {
  final String dest = await store.setUserImageFromFile(
    owner,
    MediaImageKind.backdrop,
    file,
    sourceUrl: sourceUrl,
  );
  await evictLocalCoverCache(dest);
}
