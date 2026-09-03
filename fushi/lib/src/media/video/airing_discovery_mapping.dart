/// 放送日历条目 → 发现条目的纯映射。
///
/// 日历重做（2026-08-21 用户点名「现在根本下载不出来」）的关键一刀：任何日历
/// 条目都能合成一个 [VideoDiscoveryItem]，点开即是发现详情页——搜索资源 /
/// 订阅 / 搜索字幕 / 在库播放全部走那里的既有装配（home_page 的
/// `_productionVideoDiscoveryActions`），日历页自己不再长任何下载逻辑。
library;

import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;

/// AniList MediaFormat → 持久化 movie/tv 归类。只有 MOVIE 是电影；TV_SHORT/
/// SPECIAL/OVA/ONA 等一律按 tv（episodic）处理，未知/缺失也按 tv——放送日历里
/// 出现的本来就以连载剧集为主。
VideoMetadataMediaKind mediaKindFromAniListFormat(String? format) =>
    format?.trim().toUpperCase() == 'MOVIE'
        ? VideoMetadataMediaKind.movie
        : VideoMetadataMediaKind.tv;

/// 合成发现条目。identity 与发现页 AniList 适配器同口径（providerId
/// `anilist` + mediaId = AniList id），因此详情页的 loadDetails 补全、订阅 /
/// 在库状态匹配（`_discoveryIdentityMatches`）都直接可用。
VideoDiscoveryItem discoveryItemFromAiringEpisode(
  AniListAiringEpisode episode,
) {
  final AniListMedia media = episode.media;
  final String title = media.displayTitle;
  final List<String> aliases = <String>[
    for (final String? alias in <String?>[
      media.romaji,
      media.english,
      media.native,
    ])
      if (alias != null && alias.trim().isNotEmpty && alias != title) alias,
  ];
  return VideoDiscoveryItem(
    reference: VideoMediaReference(
      providerId: 'anilist',
      mediaId: '${episode.mediaId}',
      mediaKind: mediaKindFromAniListFormat(media.format),
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: title,
      aliases: aliases,
      year: media.seasonYear,
      anilistId: episode.mediaId,
      externalIds: <String, String>{'anilist': '${episode.mediaId}'},
    ),
    posterUrl: media.coverUrl,
  );
}
