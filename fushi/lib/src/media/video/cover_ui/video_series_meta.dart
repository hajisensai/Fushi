import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_image_provider.dart';

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

/// [videoSeriesMetaPlan] 的输入：一部作品（合集或散片）的刮削行。
typedef VideoSeriesMetaInput = ({
  VideoMetadataWorkRow? work,
  List<MediaImageRow>? mediaImages,
  List<VideoMetadataImageRow>? workImages,
  CollectionScrapeMetaRow? scrape,
});

/// 两份 [VideoSeriesMetaInput] 是否同一份（逐字段对象同一）：刮削映射增量刷新时
/// 没变的键保持原行对象（`VideoLibraryScrapeMaps.patched`），据此判「不用重算」。
bool videoSeriesMetaInputSame(VideoSeriesMetaInput a, VideoSeriesMetaInput b) =>
    identical(a.work, b.work) &&
    identical(a.mediaImages, b.mediaImages) &&
    identical(a.workImages, b.workImages) &&
    identical(a.scrape, b.scrape);

/// 一个图位的候选（按优先序）：附加图组的本地路径，再是作品图组的行
/// （本地路径 + 远程地址，已按 kind 优先、`position` 排好）。
@immutable
class VideoSeriesImageSlot {
  const VideoSeriesImageSlot({
    this.mediaPaths = const <String>[],
    this.workRows = const <({String? localPath, String remoteUrl})>[],
    required this.decodeWidth,
  });

  final List<String> mediaPaths;
  final List<({String? localPath, String remoteUrl})> workRows;
  final int decodeWidth;
}

/// 视频系列色块元数据的**纯数据**部分（BUG-5253 余项）：排序刮削图组、分出有字 /
/// 无字背景图、`jsonDecode` 标签、拼年份 / 集数，都在 [videoSeriesMetaPlan] 里做完，
/// 可以放到后台 isolate；卡片 build 只调 [resolveVideoSeriesMeta] 按候选查本地文件
/// 存在性（哈希查找）拼出 [FushiSeriesMeta]。不含 ImageProvider / 翻译串，能跨
/// isolate 拷贝。
@immutable
class VideoSeriesMetaPlan {
  const VideoSeriesMetaPlan({
    required this.textlessBackdrop,
    required this.textBackdrop,
    required this.logo,
    required this.poster,
    required this.mediaType,
    required this.year,
    required this.episodeCount,
    required this.genres,
    required this.rating,
  });

  /// 没有任何刮削资料（只剩自有封面 / 回落年份）。
  static const VideoSeriesMetaPlan empty = VideoSeriesMetaPlan(
    textlessBackdrop: VideoSeriesImageSlot(
      decodeWidth: kMetadataBackdropDecodePixelWidth,
    ),
    textBackdrop: VideoSeriesImageSlot(
      decodeWidth: kMetadataBackdropDecodePixelWidth,
    ),
    logo: VideoSeriesImageSlot(decodeWidth: kMetadataLogoDecodePixelWidth),
    poster: VideoSeriesImageSlot(decodeWidth: 480),
    mediaType: null,
    year: null,
    episodeCount: null,
    genres: <String>[],
    rating: null,
  );

  final VideoSeriesImageSlot textlessBackdrop;
  final VideoSeriesImageSlot textBackdrop;
  final VideoSeriesImageSlot logo;
  final VideoSeriesImageSlot poster;

  /// 刮削作品类型原值（`tv` / `movie` / 其它），翻译在 UI 侧做。
  final String? mediaType;

  /// 作品年份（作品 → 首播日 → 合集 airDate）；都没有为 null，UI 侧再回落。
  final int? year;

  /// 总集数（电影不画）。
  final int? episodeCount;
  final List<String> genres;
  final double? rating;
}

/// 算 [VideoSeriesMetaPlan]（纯函数，可在后台 isolate 跑）。
VideoSeriesMetaPlan videoSeriesMetaPlan(VideoSeriesMetaInput input) {
  final VideoMetadataWorkRow? work = input.work;
  final CollectionScrapeMetaRow? scrape = input.scrape;
  final List<MediaImageRow> mediaImages =
      input.mediaImages ?? const <MediaImageRow>[];
  final List<VideoMetadataImageRow> orderedWork = work == null
      ? const <VideoMetadataImageRow>[]
      : ((input.workImages ?? const <VideoMetadataImageRow>[]).toList()..sort(
          (VideoMetadataImageRow a, VideoMetadataImageRow b) =>
              a.position.compareTo(b.position),
        ));
  final Set<String> textUrls = videoTextBackdropUrls(input.workImages);
  bool textless(String? url) => url == null || !textUrls.contains(url);

  List<String> mediaPaths(
    MediaImageKind kind, {
    bool Function(MediaImageRow row)? where,
  }) => <String>[
    for (final MediaImageRow row in mediaImages)
      if (row.kind == kind.dbValue &&
          row.path.isNotEmpty &&
          (where == null || where(row)))
        row.path,
  ];
  List<({String? localPath, String remoteUrl})> workRows(
    List<String> kinds, {
    bool Function(VideoMetadataImageRow row)? where,
  }) => <({String? localPath, String remoteUrl})>[
    for (final String kind in kinds)
      for (final VideoMetadataImageRow row in orderedWork)
        if (row.kind == kind && (where?.call(row) ?? true))
          (localPath: row.localPath, remoteUrl: row.remoteUrl),
  ];
  VideoSeriesImageSlot backdrop({required bool withText}) =>
      VideoSeriesImageSlot(
        mediaPaths: mediaPaths(
          MediaImageKind.backdrop,
          where: (MediaImageRow row) => textless(row.sourceUrl) != withText,
        ),
        workRows: workRows(
          const <String>['backdrop'],
          where: (VideoMetadataImageRow row) =>
              textless(row.remoteUrl) != withText,
        ),
        decodeWidth: kMetadataBackdropDecodePixelWidth,
      );

  return VideoSeriesMetaPlan(
    textlessBackdrop: backdrop(withText: false),
    textBackdrop: backdrop(withText: true),
    logo: VideoSeriesImageSlot(
      mediaPaths: mediaPaths(MediaImageKind.logo),
      workRows: workRows(const <String>['logo']),
      decodeWidth: kMetadataLogoDecodePixelWidth,
    ),
    poster: VideoSeriesImageSlot(
      workRows: workRows(const <String>['cover', 'poster']),
      decodeWidth: 480,
    ),
    mediaType: work?.mediaType,
    year:
        work?.year ??
        videoAirYear(work?.premiereDate) ??
        videoAirYear(scrape?.airDate),
    episodeCount: work?.mediaType == 'movie' ? null : scrape?.episodeCount,
    genres: fushiScrapeTagNames(scrape?.tagsJson, limit: 2),
    rating: work?.rating ?? scrape?.rating,
  );
}

/// 按 [plan] 的候选拼出 [FushiSeriesMeta]（UI 侧，只查本地文件存在性）。
///
/// - 背景图：先取**无字**的（附加图组 backdrop → 作品图组 backdrop，语言标签为空
///   的优先）；只有带字的才退而用它，并置 [FushiSeriesMeta.backdropHasText]——原图
///   的字就是标题，色块不再叠 logo（2026-11-20 用户拍板设计稿 #3 ① ②）；
/// - logo：附加图组 logo → 作品图组 logo；
/// - 作品封面：[ownPoster]（合集自有 / 原盘竖版封面）→ 作品图组 cover / poster；
/// - chip：作品类型（TV / 电影）· 年份 · 总集数；概览：刮削标签前两个 · ★ 评分。
///
/// 图一律先本地文件、再远程地址（[metadataRemoteImage]：AppCachedHttpImage 磁盘缓存 + 解码上限，与作品详情页
/// 同一条取图链）；某张本地图还在探测存在性时先不落到远程（等探测完重建，免得
/// 本地有图还去下载一遍）。
FushiSeriesMeta resolveVideoSeriesMeta(
  VideoSeriesMetaPlan plan, {
  required VideoSeriesLocalImage localImage,
  ImageProvider? ownPoster,
  int? fallbackYear,
}) {
  ImageProvider? settled(ImageProvider? image) =>
      image == kPendingCoverImage ? null : image;
  ImageProvider? mediaImage(VideoSeriesImageSlot slot) {
    for (final String path in slot.mediaPaths) {
      final ImageProvider? image = localImage(path);
      if (image != null) return image;
    }
    return null;
  }

  ImageProvider? workImage(VideoSeriesImageSlot slot) {
    bool probing = false;
    for (final ({String? localPath, String remoteUrl}) row in slot.workRows) {
      final ImageProvider? local = localImage(row.localPath);
      if (local == kPendingCoverImage) {
        probing = true;
      } else if (local != null) {
        return local;
      }
    }
    if (probing) return null;
    for (final ({String? localPath, String remoteUrl}) row in slot.workRows) {
      if (row.remoteUrl.isEmpty) continue;
      // 远程回落与本地分支同一解码上限（#3722 video-18：刮削图默认是 TMDB
      // 原图，裸解码几张就压满 ImageCache）。
      return metadataRemoteImage(row.remoteUrl, width: slot.decodeWidth);
    }
    return null;
  }

  ImageProvider? slotImage(VideoSeriesImageSlot slot) =>
      settled(mediaImage(slot)) ?? workImage(slot);

  ImageProvider? backdrop = slotImage(plan.textlessBackdrop);
  bool backdropHasText = false;
  if (backdrop == null) {
    backdrop = slotImage(plan.textBackdrop);
    backdropHasText = backdrop != null;
  }
  final ImageProvider? logo = slotImage(plan.logo);
  final ImageProvider? poster = settled(ownPoster) ?? workImage(plan.poster);
  final String? kind = switch (plan.mediaType) {
    'tv' => t.shelf_block_video_kind_tv,
    'movie' => t.shelf_block_video_kind_movie,
    _ => null,
  };
  final int? year = plan.year ?? fallbackYear;
  final int? episodes = plan.episodeCount;
  return FushiSeriesMeta.fromParts(
    backdrop: backdrop,
    backdropHasText: backdropHasText,
    logo: logo,
    poster: poster,
    genres: plan.genres,
    rating: plan.rating,
    chipParts: <String>[
      ?kind,
      if (year != null) '$year',
      if (episodes != null && episodes > 0)
        t.video_playlist_episodes(count: episodes),
    ],
  );
}

/// 一部视频作品的系列色块元数据：[videoSeriesMetaPlan] + [resolveVideoSeriesMeta]
/// 一步走完（应用首页在异步加载里按条目单查时用；视频库卡片 build 只读后台
/// 预算好的 [VideoSeriesMetaPlan]，不走这里）。
FushiSeriesMeta videoSeriesMeta({
  required VideoMetadataWorkRow? work,
  required List<MediaImageRow>? mediaImages,
  required List<VideoMetadataImageRow>? workImages,
  required CollectionScrapeMetaRow? scrape,
  required VideoSeriesLocalImage localImage,
  ImageProvider? ownPoster,
  int? fallbackYear,
}) => resolveVideoSeriesMeta(
  videoSeriesMetaPlan((
    work: work,
    mediaImages: mediaImages,
    workImages: workImages,
    scrape: scrape,
  )),
  localImage: localImage,
  ownPoster: ownPoster,
  fallbackYear: fallbackYear,
);
