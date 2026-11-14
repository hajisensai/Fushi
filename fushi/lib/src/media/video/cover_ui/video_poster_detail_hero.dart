import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart'
    show PendingCoverImage;
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/media/video/cover_ui/cover_orientation_builder.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/video_home_layout.dart'
    show VideoCardOrientation;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 视频作品详情的海报面板 hero（系列 / 独立作品 / 远端作品三处共用）：在
/// [MediaPosterDetailHero] 之上补视频这一侧的两条纪律——
///
/// - 竖版海报位只放竖图（仓库所有者「竖版位只放海报，横版剧照不许裁成竖条」）：
///   封面朝向由 [CoverOrientationBuilder] 判定（与库墙同一个探针），横版截帧
///   不进海报位，改当背景图用（没有刮削背景图时）；
/// - 小标签行 = 作品类型（TV / 电影，与库页色块 chip 同一份文案）· 刮削源给的
///   放送状态。
class VideoPosterDetailHero extends StatelessWidget {
  const VideoPosterDetailHero({
    required this.title,
    required this.primaryAction,
    this.cover,
    this.backdrop,
    this.backdropKey,
    this.logo,
    this.logoSemanticsName,
    this.mediaType,
    this.status,
    this.originalTitle,
    this.pills = const <MediaDetailChip>[],
    this.continueLabel,
    this.summary,
    this.secondaryActions = const <Widget>[],
    this.footer,
    this.aside,
    super.key,
  });

  final String title;
  final Widget primaryAction;

  /// 作品封面（海报位与面板取色同源）；[PendingCoverImage] 视同还没有。
  final ImageProvider? cover;

  /// 刮削背景图（横版）。
  final ImageProvider? backdrop;
  final Object? backdropKey;
  final ImageProvider? logo;
  final String? logoSemanticsName;

  /// 规范作品的 `media_type`（`tv` / `movie`）。
  final String? mediaType;
  final String? status;
  final String? originalTitle;
  final List<MediaDetailChip> pills;
  final String? continueLabel;
  final String? summary;
  final List<Widget> secondaryActions;
  final Widget? footer;

  /// 尾侧附栏，见 [MediaPosterDetailHero.aside]。
  final Widget? aside;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? cover = this.cover is PendingCoverImage
        ? null
        : this.cover;
    return CoverOrientationBuilder(
      image: cover,
      builder: (BuildContext context, VideoCardOrientation orientation) =>
          _build(
            cover: cover,
            portrait: orientation == VideoCardOrientation.portrait,
          ),
    );
  }

  Widget _build({required ImageProvider? cover, required bool portrait}) {
    final ImageProvider? posterImage = portrait ? cover : null;
    final bool usePoster = posterImage != null;
    final String? kind = switch (mediaType) {
      'tv' => t.shelf_block_video_kind_tv,
      'movie' => t.shelf_block_video_kind_movie,
      _ => null,
    };
    final String? status = this.status?.trim();
    return MediaPosterDetailHero(
      title: title,
      kicker: <String>[
        ?kind,
        if (status != null && status.isNotEmpty) status,
      ].join(' · '),
      originalTitle: originalTitle,
      poster: posterImage != null
          ? SizedBox.expand(
              key: const ValueKey<String>('collection-hero-poster'),
              child: PortraitCoverImage(
                image: posterImage,
                errorBuilder: (BuildContext _) =>
                    const MediaDetailCoverPlaceholder(icon: FushiIcons.video),
              ),
            )
          : null,
      posterImage: posterImage,
      // 横版截帧封面自己就是一张横图：没有刮削背景图时直接当背景图（不模糊）。
      backdrop: backdrop ?? (usePoster ? null : cover),
      backdropKey: backdropKey,
      backdropFallback: cover,
      logo: logo,
      logoSemanticsName: logoSemanticsName,
      pills: pills,
      continueLabel: continueLabel,
      summary: summary,
      summaryKey: const ValueKey<String>('collection-hero-summary'),
      primaryAction: primaryAction,
      secondaryActions: secondaryActions,
      footer: footer,
      aside: aside,
    );
  }
}
