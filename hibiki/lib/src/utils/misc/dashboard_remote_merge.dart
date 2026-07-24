import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 新首页仪表盘互联数据混排的纯函数层（「继续/活动也走 hibiki 互联」）。
///
/// - 「继续」：远端候选只补**本地没有**的条目——本地已有同 bookKey/bookUid 时以
///   本地为准（进度 live 同步本就把 host 更新的进度拉进本地 DB，双端都展示只会
///   出重复行）。
/// - 「活动」：远端事件转成 [ActivityEventRow]（id=0 哨兵，不落库）与本地事件
///   一起流入既有聚合 `aggregateActivityEvents`——同日同标题的双端 session 合并
///   计数，与聚合统计跨端合并同哲学。
///
/// 纯 Dart 无 IO，便于单测。
class RemoteContinueCandidate {
  const RemoteContinueCandidate({
    required this.isVideo,
    required this.id,
    required this.title,
    required this.recentMs,
    this.percent = 0,
    this.coverUrl,
    this.collectionName,
  });

  final bool isVideo;

  /// 稳定身份：书=downloadId（bookKey 或 title），视频=bookUid。远端封面磁盘
  /// 缓存键 + 去重键。
  final String id;

  final String title;

  /// 最近活动时刻（epoch 毫秒；0=host 无记录，混排时沉底）。
  final int recentMs;

  /// 阅读进度百分比（仅书用，0..100）。
  final int percent;

  final String? coverUrl;

  /// host 端主合集归属的合集名（[RemoteCollectionMembership.collectionName]；
  /// null = 散卡/旧 host 不带）。「继续」卡按显示名规则拼「合集名 + 条目名」用。
  final String? collectionName;
}

/// 从互联 host 清单里挑「继续」远端候选：
/// - 书：host 在读（0 < progressPercent < 100）且本地无同 key；
/// - 视频：host 有断点（positionMs > 0）且本地无同 uid。
List<RemoteContinueCandidate> remoteContinueCandidates({
  required Set<String> localBookKeys,
  required Set<String> localVideoUids,
  required List<RemoteBookInfo> remoteBooks,
  required List<RemoteVideoInfo> remoteVideos,
}) {
  final List<RemoteContinueCandidate> out = <RemoteContinueCandidate>[];
  for (final RemoteBookInfo b in remoteBooks) {
    if (b.progressPercent <= 0 || b.progressPercent >= 100) continue;
    if (localBookKeys.contains(b.downloadId)) continue;
    out.add(RemoteContinueCandidate(
      isVideo: false,
      id: b.downloadId,
      title: b.title,
      recentMs: b.progressUpdatedAtMs,
      percent: b.progressPercent,
      coverUrl: b.coverUrl,
      collectionName: b.collection?.collectionName,
    ));
  }
  for (final RemoteVideoInfo v in remoteVideos) {
    if (v.positionMs <= 0) continue;
    if (localVideoUids.contains(v.id)) continue;
    out.add(RemoteContinueCandidate(
      isVideo: true,
      id: v.id,
      title: v.title,
      recentMs: v.positionUpdatedAtMs,
      coverUrl: v.coverUrl,
      collectionName: v.collection?.collectionName,
    ));
  }
  return out;
}

/// 远端活动事件 → 本地行结构（id=0 哨兵，display-only **不落库**——追加式
/// `activity_events` 表无跨端去重键，落库会在每次浏览时重复导入）。
List<ActivityEventRow> remoteActivityAsRows(List<RemoteActivityEvent> events) {
  return <ActivityEventRow>[
    for (final RemoteActivityEvent e in events)
      ActivityEventRow(
        id: 0,
        eventType: e.eventType,
        mediaType: e.mediaType,
        title: e.title,
        mediaKey: e.mediaKey,
        dateKey: e.dateKey,
        timestampMs: e.timestampMs,
        durationMs: e.durationMs,
        charsDelta: e.charsDelta,
      ),
  ];
}

/// 本地 + 远端活动事件混排（按精确时刻倒序，截断到 [limit]——与本地
/// `getRecentActivityEvents(limit: 200)` 对齐，避免远端灌爆时间轴）。
List<ActivityEventRow> mergeActivityEvents(
  List<ActivityEventRow> local,
  List<ActivityEventRow> remote, {
  int limit = 200,
}) {
  final List<ActivityEventRow> merged = <ActivityEventRow>[...local, ...remote]
    ..sort((ActivityEventRow a, ActivityEventRow b) =>
        b.timestampMs.compareTo(a.timestampMs));
  return merged.length <= limit ? merged : merged.sublist(0, limit);
}
