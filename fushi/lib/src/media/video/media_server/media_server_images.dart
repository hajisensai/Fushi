import 'package:flutter/painting.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/utils/cover_image.dart'
    show kLocalCoverDecodePixelWidth;

// =============================================================================
// 媒体服务器（Jellyfin / Emby / Plex）条目图片的 [ImageProvider] 工厂。
//
// 服务器自己的页面与应用首页「继续」行共用这一份：取图一律经浏览器本身
// （[MediaServerBrowser] implements `RemoteCoverFetcher`，带鉴权）+ [RemoteCoverImage]
// 的内存 / 磁盘两层缓存，缓存键按「条目 id : 图种 (: 请求宽度)」稳定——同一部剧的
// 背景图 / logo 在服务器页与首页之间只取一次。构造 provider 不发请求，只有真正画出来
// 的 [Image] 才会 resolve。无图返回 null：页面画占位，不拿一个必 404 的地址去请求。
// =============================================================================

/// 服务器条目封面（缩放到 [kLocalCoverDecodePixelWidth] 以内解码）。
ImageProvider? mediaServerCoverImage(
  MediaServerBrowser browser,
  MediaServerItem item, {
  MediaServerImageKind kind = MediaServerImageKind.primary,
}) {
  final String? url = browser.coverUrl(item, kind: kind);
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    RemoteCoverImage(url, browser, cacheKey: '${item.id}:${kind.name}'),
    width: kLocalCoverDecodePixelWidth,
    allowUpscaling: false,
  );
}

/// 详情页 hero 用的大图（横版背景 / 标题 logo）：请求宽度与解码宽度都比网格卡大
/// ——背景要铺满 1600+ 逻辑像素宽的 hero，720 像素放大后一片糊；logo 在 hero 里
/// 最大 460×110 逻辑像素 × dpr。缓存键带上请求宽度，与网格卡的 720 版本互不串。
/// 其它 [kind] 退回 [mediaServerCoverImage] 的常规尺寸。无图返回 null。
ImageProvider? mediaServerHeroImage(
  MediaServerBrowser browser,
  MediaServerItem item, {
  required MediaServerImageKind kind,
}) {
  final (int requestWidth, int decodeWidth) = switch (kind) {
    MediaServerImageKind.backdrop => (1920, 2560),
    MediaServerImageKind.logo => (800, 800),
    MediaServerImageKind.primary || MediaServerImageKind.thumb => (
      kMediaServerCoverMaxWidth,
      kLocalCoverDecodePixelWidth,
    ),
  };
  final String? url = browser.coverUrl(
    item,
    kind: kind,
    maxWidth: requestWidth,
  );
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    RemoteCoverImage(
      url,
      browser,
      cacheKey: '${item.id}:${kind.name}:$requestWidth',
    ),
    width: decodeWidth,
    allowUpscaling: false,
  );
}

/// 媒体库自身的封面（[MediaServerLibrary.hasCover] 为 false 时 null）。
ImageProvider? mediaServerLibraryCoverImage(
  MediaServerBrowser browser,
  MediaServerLibrary library,
) {
  final String? url = browser.libraryCoverUrl(library);
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    RemoteCoverImage(url, browser, cacheKey: 'library:${library.id}'),
    width: kLocalCoverDecodePixelWidth,
    allowUpscaling: false,
  );
}

/// 只带一种图片旗子的上级条目（通常是剧）：把服务器报的上级图所在 id 包成条目交给
/// [MediaServerBrowser.coverUrl]，不用给契约再开「按 id 取图」的口子，缓存键也自然
/// 按剧共享。
MediaServerItem mediaServerParentImageItem(
  String id,
  MediaServerImageKind kind,
) => MediaServerItem(
  id: id,
  name: '',
  type: MediaServerItemType.series,
  hasCover: kind == MediaServerImageKind.primary,
  hasBackdrop: kind == MediaServerImageKind.backdrop,
  hasThumb: kind == MediaServerImageKind.thumb,
  hasLogo: kind == MediaServerImageKind.logo,
);

/// 作品级图片（[mediaServerWorkImageItemId] 选出的 [itemId]）的 provider：背景图
/// 走网格尺寸（[mediaServerCoverImage]），logo 走 hero 尺寸（[mediaServerHeroImage]）
/// ——与服务器页同一缓存键（条目 id : 图种 (: 宽度)），同一部剧在服务器页、首页与
/// 视频库之间只取一次。
ImageProvider? mediaServerWorkArtImage(
  MediaServerBrowser browser,
  String itemId,
  MediaServerImageKind kind,
) {
  final MediaServerItem source = mediaServerParentImageItem(itemId, kind);
  return switch (kind) {
    MediaServerImageKind.logo => mediaServerHeroImage(
      browser,
      source,
      kind: MediaServerImageKind.logo,
    ),
    _ => mediaServerCoverImage(browser, source, kind: kind),
  };
}

/// 条目的横版背景图（无字剧照）：集用所属剧的（[MediaServerItem.parentBackdropItemId]），
/// 剧没有才用集自己的；其余自身有就用自身的，没有再借上级。没有为 null。
ImageProvider? mediaServerBackdropImage(
  MediaServerBrowser browser,
  MediaServerItem item,
) {
  final String? id = mediaServerWorkImageItemId(
    item,
    MediaServerImageKind.backdrop,
  );
  return id == null
      ? null
      : mediaServerWorkArtImage(browser, id, MediaServerImageKind.backdrop);
}

/// 条目的标题艺术字（logo，hero 尺寸）：集用所属剧的
/// （[MediaServerItem.parentLogoItemId]），剧没有才用集自己的；其余自身有就用自身的，
/// 没有再借上级。没有为 null。
ImageProvider? mediaServerLogoImage(
  MediaServerBrowser browser,
  MediaServerItem item,
) {
  final String? id = mediaServerWorkImageItemId(
    item,
    MediaServerImageKind.logo,
  );
  return id == null
      ? null
      : mediaServerWorkArtImage(browser, id, MediaServerImageKind.logo);
}
