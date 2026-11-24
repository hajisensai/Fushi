/// 刮削作品图（海报 / 背景 / 艺术字 / 剧照）的 [ImageProvider] 与解码上限。
///
/// BUG-959 的刮削图半边（#3722 video-18 / video-s3-13）：TMDB / AniDB 等刮削源默认给
/// 原图（BUG-1082 拍板默认满分辨率，海报常 2000×3000、背景 3840×2160），磁盘字节不动，
/// 但解码必须按显示需要封顶——裸 [AppCachedHttpImage] / [FileImage] 整帧解进
/// [ImageCache]（默认 100MB），一张 4K 背景约 33MB，几张就把缓存压满，库页滚动时
/// LRU 反复淘汰重解码。本地封面早就恒过 [resizedFileImage]，远端回落与作品详情页
/// 没理由例外。
///
/// 只降解码尺寸，**不**给 [AppCachedHttpImage] 传 `maxWidth`（那会让缓存管理器另存
/// 一份缩放后的磁盘文件），也不改刮削源的尺寸档。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart'
    show kPendingCoverImage;
import 'package:fushi/src/media/video/video_home_layout.dart'
    show VideoFileEpisodeStills, resumedFileEpisodeStills;
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataImageKind;

/// 横版背景（hero 大图）的解码上限：与库页作品 hero 的背景同一口径。
const int kMetadataBackdropDecodePixelWidth = 1280;

/// 艺术字 logo 的解码上限：与库页作品 hero 的 logo 同一口径。
const int kMetadataLogoDecodePixelWidth = 640;

/// 刮削图种类（`video_metadata_images.kind`）→ 解码上限（物理像素宽）。
///
/// 背景铺满 hero 区，给 [kMetadataBackdropDecodePixelWidth]；logo 只占 hero 一角，
/// 给 [kMetadataLogoDecodePixelWidth]；其余（海报 / 封面 / 剧照 / 横版卡图等）都是
/// 卡槽尺寸，给 [kLocalCoverDecodePixelWidth]。
int videoMetadataImageDecodeWidth(String kind) => switch (kind) {
  'backdrop' => kMetadataBackdropDecodePixelWidth,
  'logo' => kMetadataLogoDecodePixelWidth,
  _ => kLocalCoverDecodePixelWidth,
};

/// [VideoMetadataImageKind] 版的 [videoMetadataImageDecodeWidth]（远端作品资料页）。
int videoMetadataImageKindDecodeWidth(VideoMetadataImageKind kind) =>
    videoMetadataImageDecodeWidth(kind.name);

/// 刮削图远程地址的 provider：[AppCachedHttpImage] 磁盘缓存 + 只缩不放的解码上限。
///
/// 同一 url + 同一 [width] = 同一个 [ResizeImage] 键，[ImageCache] 里只有一份解码。
ImageProvider metadataRemoteImage(
  String url, {
  int width = kLocalCoverDecodePixelWidth,
}) => ResizeImage(AppCachedHttpImage(url), width: width, allowUpscaling: false);

/// 作品图组里取 [kind] 的第一张可用图：本地文件已知存在 → 带上限的文件图；
/// 否则有远程地址 → 带上限的远程图。都没有返回 null。
///
/// [localExists] 由调用方提供（详情页在 `_load` 里异步探好的集合），这里零同步 IO。
ImageProvider? videoMetadataRowImage(
  Iterable<VideoMetadataImageRow> rows,
  String kind, {
  required bool Function(String path) localExists,
}) {
  final int width = videoMetadataImageDecodeWidth(kind);
  for (final VideoMetadataImageRow image in rows) {
    if (image.kind != kind) continue;
    final String? path = image.localPath;
    if (path != null && localExists(path)) {
      return resizedFileImage(File(path), width: width);
    }
    if (image.remoteUrl.isNotEmpty) {
      return metadataRemoteImage(image.remoteUrl, width: width);
    }
  }
  return null;
}

/// 一个本地视频文件「这一集自己的剧照」：[resumedFileEpisodeStills] 定位续播点
/// 所在那一集（一文件一集时就是它），取那一集的 thumb 图，本地文件优先、其次远程
/// URL（解码上限同 [metadataRemoteImage]）。首页主卡与合集选集页共用这一份
/// （拍板 GLMHiavo0y）。
///
/// [localExists] 是调用方的零 IO 存在性缓存（`AsyncFileExistenceCache.lookupOptional`
/// 口径：null = 还在探测，空路径答 false）。某张本地图还在探测时返回
/// [kPendingCoverImage]，不先闪成远程图或别的回落。那一集没有剧照返回 null——
/// 不拿别的集的剧照冒充，由调用方回落。
ImageProvider? videoFileEpisodeStillImage(
  Iterable<VideoFileEpisodeStills>? episodes, {
  required int positionMs,
  required bool? Function(String? path) localExists,
}) {
  if (episodes == null) return null;
  for (final VideoMetadataImageRow row in resumedFileEpisodeStills(
    episodes,
    positionMs: positionMs,
  )) {
    switch (localExists(row.localPath)) {
      case null:
        return kPendingCoverImage;
      case true:
        return resizedFileImage(File(row.localPath!));
      case false:
        break;
    }
    // 远程回落与本地分支同一解码上限（#3722 video-18：刮削剧照是原图）。
    if (row.remoteUrl.isNotEmpty) return metadataRemoteImage(row.remoteUrl);
  }
  return null;
}

/// 选集页一集缩略图的候选序（拍板 GLMHiavo0y）：用户手动设置的封面 > 分集剧照 >
/// 自动截图。
///
/// [cover] 是这一集的封面（`video_books.cover_path`，自动截帧与手动封面同一个槽），
/// [coverIsUserChosen] 由封面来源（`CoverOrigin.isUserChosen`）判定。返回去掉空值后
/// 的候选，渲染端从第一张起显示，加载 / 解码失败依次回落下一张（剧照远程地址失效
/// 时退回截图；手动封面文件坏了时退回剧照）。
///
/// [coverIsUserChosen] 为 null 表示封面来源表（`cover_meta.json`）还在后台读：封面与
/// 剧照**都有**时先后顺序取决于它，此时停在 [kPendingCoverImage]（与
/// `AsyncFileExistenceCache` 探测中同一口径），不先闪成剧照再跳回手动封面；只有其中
/// 一张时顺序无关，直接给出。
List<ImageProvider> videoEpisodeThumbCandidates({
  required ImageProvider? cover,
  required bool? coverIsUserChosen,
  required ImageProvider? still,
}) {
  if (coverIsUserChosen == null && cover != null && still != null) {
    return const <ImageProvider>[kPendingCoverImage];
  }
  return <ImageProvider>[
    for (final ImageProvider? image
        in (coverIsUserChosen ?? false)
            ? <ImageProvider?>[cover, still]
            : <ImageProvider?>[still, cover])
      ?image,
  ];
}
