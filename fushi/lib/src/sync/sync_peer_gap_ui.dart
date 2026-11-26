import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_peer_gap.dart';

/// 「对端缺能力」那一行在同步任务面板里的本地化文案。
///
/// [SyncPeerGap.message] 是写进同步报告 / 错误日志的英文原句（日志要一字不变、便于
/// 检索），任务面板拿到的也只是这串文字。面板展示时经 [localizedSyncTaskError] 还原
/// 回 [SyncPeerGap]，再按维度给出用户语言的说明；还原只做**精确等值**比对（候选集
/// 就是全部「维度 × 过旧 / 不支持」生成的原句），不做模糊匹配，别的错误行原样显示。
String syncPeerGapLine(SyncPeerGap gap) {
  final String what = syncPeerGapDimensionLabel(gap.dimension);
  if (!gap.outdated) return t.sync_peer_gap_unsupported(what: what);
  return gap.dimension.degraded
      ? t.sync_peer_gap_outdated_degraded(what: what)
      : t.sync_peer_gap_outdated(what: what);
}

/// 维度的用户可读名（[syncPeerGapLine] 的主语）。
String syncPeerGapDimensionLabel(
  SyncPeerGapDimension dimension,
) => switch (dimension) {
  SyncPeerGapDimension.collections => t.sync_peer_gap_dim_collections,
  SyncPeerGapDimension.tags => t.sync_peer_gap_dim_tags,
  SyncPeerGapDimension.mediaLinks => t.sync_peer_gap_dim_media_links,
  SyncPeerGapDimension.onlineLibrary => t.sync_peer_gap_dim_online_library,
  SyncPeerGapDimension.videoMetadata => t.sync_peer_gap_dim_video_metadata,
  SyncPeerGapDimension.serviceConfig => t.sync_peer_gap_dim_service_config,
  SyncPeerGapDimension.deletionTombstones =>
    t.sync_peer_gap_dim_deletion_tombstones,
  SyncPeerGapDimension.videoDeletion => t.sync_peer_gap_dim_video_deletion,
  SyncPeerGapDimension.videoSubtitles => t.sync_peer_gap_dim_video_subtitles,
  SyncPeerGapDimension.pdfBooks => t.sync_peer_gap_dim_pdf_books,
  SyncPeerGapDimension.localAudioIdentity => t.sync_peer_gap_dim_local_audio,
};

/// 任务面板的一条错误行：是「对端缺能力」原句就换成本地化说明，否则原样返回。
String localizedSyncTaskError(String message) {
  final SyncPeerGap? gap = SyncPeerGap.fromMessage(message);
  return gap == null ? message : syncPeerGapLine(gap);
}
