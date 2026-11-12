import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show formatActivityRelativeTime;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi_core/fushi_core.dart';

/// 追踪状态的 i18n 外显（设置页与首页 Bangumi 同步卡共用）。
///
/// 这些标签原先是设置页的文件私有函数，首页卡片一并需要；抽到这里而不是复制一份，
/// 避免两处对同一枚举值给出不同说法。

/// 条目类别外显（`TrackingKind` 的持久化值）。
String trackingKindLabel(String value) {
  switch (value) {
    case 'anime':
      return t.media_tracking_anime;
    case 'manga':
      return t.media_tracking_manga;
    case 'game':
      return t.media_tracking_game;
    default:
      return t.media_tracking_novel;
  }
}

/// 进度单位外显（`TrackingProgressMode` 的持久化值）。
String trackingProgressModeLabel(String value) {
  switch (value) {
    case 'episode':
      return t.media_tracking_episode;
    case 'volume':
      return t.media_tracking_volume;
    case 'status':
      return t.media_tracking_status;
    default:
      return t.media_tracking_chapter;
  }
}

/// One signed-in site's sync state for Settings > Sync and the control
/// channel: last sync, pending updates, failed updates, a rejected sign-in.
String trackingSiteSyncSummary(
  MediaTrackingProviderStatus site,
  DateTime now,
) => <String>[
  t.media_tracking_site_sync_summary(
    when: trackingSiteLastSyncLabel(site, now),
    n: '${site.pending}',
  ),
  if (site.failures.isNotEmpty)
    trackingFailedUpdatesCount(site.failures.length),
  if (site.unauthorized) t.media_tracking_site_sign_in_expired,
].join(' · ');

/// [site]'s last sync attempt, relative; "Never synced" when it never ran.
String trackingSiteLastSyncLabel(
  MediaTrackingProviderStatus site,
  DateTime now,
) => trackingLastSyncAtLabel(site.lastSyncAt, now);

/// A last sync attempt at [lastSyncAt] (epoch ms), relative; "Never
/// synced" for 0.
String trackingLastSyncAtLabel(int lastSyncAt, DateTime now) =>
    lastSyncAt <= 0
    ? t.media_tracking_never_synced
    : formatActivityRelativeTime(lastSyncAt, now);

/// 一条映射的副标题：类别 · Bangumi 条目名 · 进度单位。
String trackingMappingSubtitle(MediaTrackingMappingRow mapping) => <String>[
  trackingKindLabel(mapping.kind),
  mapping.subjectName,
  trackingProgressModeLabel(mapping.progressMode),
].join(' · ');

/// How a Tracking page row names its kind ([trackingRowKindOf]).
String trackingRowKindLabel(TrackingRowKind kind) => switch (kind) {
  TrackingRowKind.anime => t.media_tracking_anime,
  TrackingRowKind.liveAction => t.media_tracking_kind_live_action,
  TrackingRowKind.video => t.media_tracking_kind_video,
  TrackingRowKind.manga => t.media_tracking_manga,
  TrackingRowKind.novel => t.media_tracking_novel,
  TrackingRowKind.game => t.media_tracking_game,
};

/// "1 volume" / "3 volumes" (T2 G12: the strings take no plural forms, so
/// the singular is its own key).
String trackingVolumesCount(int n) => n == 1
    ? t.media_tracking_track_volumes_one(count: '$n')
    : t.media_tracking_track_volumes(count: '$n');

/// "1 episode" / "12 episodes".
String trackingEpisodesCount(int n) => n == 1
    ? t.media_tracking_link_episodes_one(count: '$n')
    : t.media_tracking_link_episodes(count: '$n');

/// "1 chapter" / "40 chapters".
String trackingChaptersCount(int n) => n == 1
    ? t.media_tracking_track_chapters_one(count: '$n')
    : t.media_tracking_track_chapters(count: '$n');

/// "1 update failed" / "3 updates failed".
String trackingFailedUpdatesCount(int n) => n == 1
    ? t.media_tracking_site_failed_count_one(n: '$n')
    : t.media_tracking_site_failed_count(n: '$n');
