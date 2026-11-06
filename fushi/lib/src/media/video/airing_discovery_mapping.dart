/// 放送日历条目 → 发现条目的纯映射。
///
/// 日历重做（2026-08-21 用户点名「现在根本下载不出来」）的关键一刀：任何日历
/// 条目都能合成一个 [VideoDiscoveryItem]，点开即是发现详情页——搜索资源 /
/// 订阅 / 搜索字幕 / 在库播放全部走那里的既有装配（home_page 的
/// `_productionVideoDiscoveryActions`），日历页自己不再长任何下载逻辑。
library;

import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi_core/fushi_core.dart' show VideoDownloadSubscriptionRow;
import 'package:fushi_engine/media/video/download/video_media_reference_codec.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
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
  // 与发现页 AniList 适配器同口径：日文原名作标题，罗马字 / 英文进 aliases
  // （资源 / 字幕搜索靠 aliases 里的罗马字命中）。
  final String title = media.nativeFirstTitle;
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

/// 发现页订阅行（`video_download_subscriptions`）→ AniList id；拿不到 = null。
///
/// 日历的「相关」集合要认这张表：从日历点进发现详情页订阅，写的就是它，
/// 只读旧版 `AnimeDownloadSubscriptionStore` 会让刚订阅的番在日历里「不相关」。
/// 先认 identity_json 里的 anilistId（任何元数据源都可能带上），再认
/// metadata_provider 本身就是 anilist 的 external_id；Bangumi / TMDB 的 id
/// 不是 AniList id，绝不能拿来当 mediaId_in 查。
int? anilistIdOfVideoDownloadSubscription(VideoDownloadSubscriptionRow row) {
  final int? fromIdentity = decodeVideoMediaReference(
    row.identityJson,
  )?.anilistId;
  if (fromIdentity != null) return fromIdentity;
  if (row.metadataProvider?.trim().toLowerCase() != 'anilist') return null;
  final String? externalId = row.externalId?.trim();
  return externalId == null ? null : int.tryParse(externalId);
}
