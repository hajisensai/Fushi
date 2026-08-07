import 'package:fushi/src/media/tracking/media_tracking_service.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/utils.dart';
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

/// 「上次同步」外显：从未跑过同步时明确说「从未同步」，否则给相对时间。
///
/// 这一行是「看完了没反应」的第一诊断位：只要它显示「从未同步」，问题就在同步根本
/// 没被触发（多数是没连令牌），而不在映射或远端。
String trackingLastSyncLabel(MediaTrackingStatus status, DateTime now) {
  if (status.hasNeverSynced) return t.media_tracking_never_synced;
  return formatActivityRelativeTime(status.lastSyncAt, now);
}

/// 一条映射的副标题：类别 · Bangumi 条目名 · 进度单位。
String trackingMappingSubtitle(MediaTrackingMappingRow mapping) => <String>[
      trackingKindLabel(mapping.kind),
      mapping.subjectName,
      trackingProgressModeLabel(mapping.progressMode),
    ].join(' · ');
