import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';

// =============================================================================
// 视频作品的系列色块元数据（[FushiSeriesMeta]）——视频库（系列 / 首页主卡）与
// 应用首页（「继续」「最近添加」色块）共用这一份取图 / 拼串逻辑，调用方只负责
// 把自己手里的行喂进来（视频库全量预取、首页只为要画的条目单查）。
// =============================================================================

/// 本地文件 → 图源；存在性还在探测时返回 [kPendingCoverImage]，不存在为 null。
typedef VideoSeriesLocalImage = ImageProvider? Function(String? path);

/// 刮削作品图组里**带片名**的背景图地址：TMDB 给印着文字的 backdrop 打语言
/// 标签（`iso_639_1` 非空），无字版为 null（Jellyfin 据此把带字的分流成 Thumb，
/// `MediaImageKind.titleCard` 的文档同一口径）。附加图组（`media_images`）没有
/// 语言列，按 `sourceUrl` 对回这里查。
Set<String> videoTextBackdropUrls(Iterable<VideoMetadataImageRow>? workImages) {
  if (workImages == null) return const <String>{};
  return <String>{
    for (final VideoMetadataImageRow row in workImages)
      if (row.kind == 'backdrop' &&
          (row.language?.trim().isNotEmpty ?? false) &&
          row.remoteUrl.isNotEmpty)
        row.remoteUrl,
  };
}

/// 一部视频作品的系列色块元数据。
///
/// - 背景图：先取**无字**的（附加图组 backdrop → 作品图组 backdrop，语言标签为空
///   的优先）；只有带字的才退而用它，并置 [FushiSeriesMeta.backdropHasText]——原图
///   的字就是标题，色块不再叠 logo（2026-11-20 用户拍板设计稿 #3 ① ②）；
/// - logo：附加图组 logo → 作品图组 logo；
/// - 作品封面：[ownPoster]（合集自有 / 原盘竖版封面）→ 作品图组 cover / poster；
/// - chip：作品类型（TV / 电影）· 年份 · 总集数；概览：刮削标签前两个 · ★ 评分。
///
/// 图一律先本地文件、再远程地址（[AppCachedHttpImage] 磁盘缓存，与作品详情页
/// 同一条取图链）；某张本地图还在探测存在性时先不落到远程（等探测完重建，免得
/// 本地有图还去下载一遍）。
FushiSeriesMeta videoSeriesMeta({
  required VideoMetadataWorkRow? work,
  required List<MediaImageRow>? mediaImages,
  required List<VideoMetadataImageRow>? workImages,
  required CollectionScrapeMetaRow? scrape,
  required VideoSeriesLocalImage localImage,
  ImageProvider? ownPoster,
  int? fallbackYear,
}) {
  ImageProvider? settled(ImageProvider? image) =>
      image == kPendingCoverImage ? null : image;
  final List<VideoMetadataImageRow> orderedWork =
      (workImages ?? const <VideoMetadataImageRow>[]).toList()..sort(
        (VideoMetadataImageRow a, VideoMetadataImageRow b) =>
            a.position.compareTo(b.position),
      );
  ImageProvider? workImage(
    List<String> kinds, {
    required int decodeWidth,
    bool Function(VideoMetadataImageRow row)? where,
  }) {
    if (work == null) return null;
    final List<VideoMetadataImageRow> rows = <VideoMetadataImageRow>[
      for (final VideoMetadataImageRow row in orderedWork)
        if (where?.call(row) ?? true) row,
    ];
    bool probing = false;
    for (final String kind in kinds) {
      for (final VideoMetadataImageRow row in rows) {
        if (row.kind != kind) continue;
        final ImageProvider? local = localImage(row.localPath);
        if (local == kPendingCoverImage) {
          probing = true;
        } else if (local != null) {
          return local;
        }
      }
    }
    if (probing) return null;
    for (final String kind in kinds) {
      for (final VideoMetadataImageRow row in rows) {
        if (row.kind != kind || row.remoteUrl.isEmpty) continue;
        return ResizeImage.resizeIfNeeded(
          decodeWidth,
          null,
          AppCachedHttpImage(row.remoteUrl),
        );
      }
    }
    return null;
  }

  ImageProvider? mediaImage(
    MediaImageKind kind, {
    bool Function(MediaImageRow row)? where,
  }) {
    if (mediaImages == null) return null;
    for (final MediaImageRow row in mediaImages) {
      if (row.kind != kind.dbValue || row.path.isEmpty) continue;
      if (where != null && !where(row)) continue;
      final ImageProvider? image = localImage(row.path);
      if (image != null) return image;
    }
    return null;
  }

  final Set<String> textUrls = videoTextBackdropUrls(workImages);
  bool textless(String? url) => url == null || !textUrls.contains(url);
  ImageProvider? backdropOf({required bool withText}) =>
      settled(
        mediaImage(
          MediaImageKind.backdrop,
          where: (MediaImageRow row) => textless(row.sourceUrl) != withText,
        ),
      ) ??
      workImage(
        const <String>['backdrop'],
        decodeWidth: 1280,
        where: (VideoMetadataImageRow row) =>
            textless(row.remoteUrl) != withText,
      );
  ImageProvider? backdrop = backdropOf(withText: false);
  bool backdropHasText = false;
  if (backdrop == null) {
    backdrop = backdropOf(withText: true);
    backdropHasText = backdrop != null;
  }
  final ImageProvider? logo =
      settled(mediaImage(MediaImageKind.logo)) ??
      workImage(const <String>['logo'], decodeWidth: 640);
  final ImageProvider? poster =
      settled(ownPoster) ??
      workImage(const <String>['cover', 'poster'], decodeWidth: 480);
  final String? kind = switch (work?.mediaType) {
    'tv' => t.shelf_block_video_kind_tv,
    'movie' => t.shelf_block_video_kind_movie,
    _ => null,
  };
  final int? year =
      work?.year ??
      videoAirYear(work?.premiereDate) ??
      videoAirYear(scrape?.airDate) ??
      fallbackYear;
  final int? episodes = work?.mediaType == 'movie'
      ? null
      : scrape?.episodeCount;
  return FushiSeriesMeta.fromParts(
    backdrop: backdrop,
    backdropHasText: backdropHasText,
    logo: logo,
    poster: poster,
    genres: fushiScrapeTagNames(scrape?.tagsJson, limit: 2),
    rating: work?.rating ?? scrape?.rating,
    chipParts: <String>[
      ?kind,
      if (year != null) '$year',
      if (episodes != null && episodes > 0)
        t.video_playlist_episodes(count: episodes),
    ],
  );
}
