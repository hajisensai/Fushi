import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/collections/collection_continue.dart';

/// 新首页仪表盘互联数据混排的纯函数层（「继续/活动也走 hibiki 互联」）。
///
/// - 「继续」：远端候选只补**本地没有**的条目——本地已有同 bookKey/bookUid 时以
///   本地为准（进度 live 同步本就把 host 更新的进度拉进本地 DB，双端都展示只会
///   出重复行）。
/// - 「活动」：远端事件转成 [ActivityEventRow]（id=0 哨兵，不落库）与本地事件
///   一起流入既有聚合 `aggregateActivityEvents`——聚合键含设备维（provenance），
///   双端 session 各自成条不合并；同设备同日同条目（mediaKey，缺失回落标题）
///   才合并计数（BUG-1350 后语义）。
///
/// 纯 Dart 无 IO，便于单测。
class RemoteContinueCandidate {
  const RemoteContinueCandidate({
    required this.kind,
    required this.id,
    required this.title,
    required this.recentMs,
    this.percent = 0,
    this.coverUrl,
    this.collectionName,
  });

  /// 远端条目的媒体种类（BUG-1119：此前是 `bool isVideo` 二元降维，SRT 书会被
  /// 当成 epub、第三种媒体结构上装不下——与 BUG-1111 本地侧同病）。书清单侧是
  /// host additive wire 字段 `'kind'` 的落点（旧 host 缺失 → epub），视频清单
  /// 天然 video。
  final MediaKind kind;

  /// 派生便捷判据（旧消费点零改动）。
  bool get isVideo => kind == MediaKind.video;

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
/// - 书散卡：host 在读（0 < progressPercent < 100）且本地无同 key；
/// - 视频散卡：host 有断点（positionMs > 0）、未看完且本地无同 uid；
/// - **合集成员**（host 携带主合集归属 [RemoteCollectionMembership]）：同一合集
///   在「继续」区**最多一张卡**，与本地合集同一判据 [continueMemberIndex]
///   （锚点 = 最近播放 / 阅读的成员，它看完就推进下一个）。整组没开始过、或目标
///   仍是看完的成员（整组看完）→ 不出卡。
///
/// 用户实报（反馈 GonyeE75Kd）：子设备首页「继续」被一排完全相同的
/// 「K-ON! 播放列表 · 远端」卡刷屏——host 上这个播放列表每看过一集就一条
/// `positionMs > 0` 的视频行，旧实现逐行出卡，而小卡标题按显示名规则取合集名，
/// N 集就是 N 张同名同封面的卡。本地合集早在 dashboard 按合集收敛成一张。
List<RemoteContinueCandidate> remoteContinueCandidates({
  required Set<String> localBookKeys,
  required Set<String> localVideoUids,
  required List<RemoteBookInfo> remoteBooks,
  required List<RemoteVideoInfo> remoteVideos,
}) {
  final List<RemoteContinueCandidate> out = <RemoteContinueCandidate>[];
  final Map<String, List<RemoteBookInfo>> bookGroups =
      <String, List<RemoteBookInfo>>{};
  for (final RemoteBookInfo b in remoteBooks) {
    if (localBookKeys.contains(b.downloadId)) continue;
    // BUG-1638：不可下载条目（hasContent=false——host 在读的漫画/PDF 等无 EPUB
    // 内容树的行）不进「继续」：书架远端列表早已按 hasContent 过滤，这里漏了 →
    // 点卡片只会切到书架 tab，而书架上根本没有这张卡（死路卡）。
    if (!b.hasContent) continue;
    final RemoteCollectionMembership? membership = b.collection;
    if (membership != null) {
      (bookGroups[_membershipKey(membership)] ??= <RemoteBookInfo>[]).add(b);
      continue;
    }
    if (b.progressPercent <= 0 || b.progressPercent >= 100) continue;
    out.add(_bookCandidate(b, recentMs: b.progressUpdatedAtMs));
  }
  for (final List<RemoteBookInfo> group in bookGroups.values) {
    final List<RemoteBookInfo> sorted = List<RemoteBookInfo>.of(group)
      ..sort(
        (RemoteBookInfo a, RemoteBookInfo b) => _compareMembers(
          a.collection!,
          a.downloadId,
          b.collection!,
          b.downloadId,
        ),
      );
    final List<CollectionMemberProgress> progress = <CollectionMemberProgress>[
      for (final RemoteBookInfo b in sorted)
        CollectionMemberProgress(
          positionMs: b.progressPercent,
          completed: b.progressPercent >= 100,
          lastPlayedAt: b.progressUpdatedAtMs,
        ),
    ];
    final int? idx = _collectionContinueIndex(progress);
    if (idx == null) continue;
    out.add(
      _bookCandidate(
        sorted[idx],
        recentMs: _maxOf(
          sorted.map((RemoteBookInfo b) => b.progressUpdatedAtMs),
        ),
      ),
    );
  }

  final Map<String, List<RemoteVideoInfo>> videoGroups =
      <String, List<RemoteVideoInfo>>{};
  for (final RemoteVideoInfo v in remoteVideos) {
    if (localVideoUids.contains(v.id)) continue;
    final RemoteCollectionMembership? membership = v.collection;
    if (membership != null) {
      (videoGroups[_membershipKey(membership)] ??= <RemoteVideoInfo>[]).add(v);
      continue;
    }
    // 与本地视频散卡同口径：有断点且未看完。
    if (v.positionMs <= 0 || v.completedAt != null) continue;
    out.add(_videoCandidate(v, recentMs: v.positionUpdatedAtMs));
  }
  for (final List<RemoteVideoInfo> group in videoGroups.values) {
    final List<RemoteVideoInfo> sorted = List<RemoteVideoInfo>.of(group)
      ..sort(
        (RemoteVideoInfo a, RemoteVideoInfo b) =>
            _compareMembers(a.collection!, a.id, b.collection!, b.id),
      );
    final List<CollectionMemberProgress> progress = <CollectionMemberProgress>[
      for (final RemoteVideoInfo v in sorted)
        CollectionMemberProgress(
          positionMs: v.positionMs,
          completed: v.completedAt != null,
          lastPlayedAt: v.positionUpdatedAtMs,
          durationMs: v.durationMs,
        ),
    ];
    final int? idx = _collectionContinueIndex(progress);
    if (idx == null) continue;
    out.add(
      _videoCandidate(
        sorted[idx],
        // 单元活跃时刻 = 组内最近一次播放（含看完的那集——Next-Up 卡按「刚看完
        // 上一集」的时刻参与混排），与本地合集卡同口径。
        recentMs: _maxOf(
          sorted.map((RemoteVideoInfo v) => v.positionUpdatedAtMs),
        ),
      ),
    );
  }
  return out;
}

/// 去掉本地已出合集卡的远端合集单元（「继续」区一个合集最多一张卡）。
///
/// host 合集按自然键（名字）收养进本地同名合集，所以本地成员与远端成员可以同在
/// 一个合集里：本地那张合集卡已经代表了这个单元，远端再补一张就是两张同名卡。
/// 与 [remoteContinueCandidates]「本地已有以本地为准」同一取舍。只比同媒体侧
/// （视频对视频、书对书），散卡（[RemoteContinueCandidate.collectionName] 为
/// null）不受影响。
List<RemoteContinueCandidate> withoutLocallyCoveredCollections(
  List<RemoteContinueCandidate> remote, {
  required Set<String> localVideoCollectionNames,
  required Set<String> localBookCollectionNames,
}) {
  return <RemoteContinueCandidate>[
    for (final RemoteContinueCandidate c in remote)
      if (c.collectionName == null ||
          !(c.isVideo ? localVideoCollectionNames : localBookCollectionNames)
              .contains(c.collectionName))
        c,
  ];
}

/// 合集单元的续播 / 续读目标下标；不出卡时为 null。与本地合集同一判据：整组
/// 没开始过（不劝人从头开始）或目标仍是看完的成员（整组看完）→ null。
int? _collectionContinueIndex(List<CollectionMemberProgress> sorted) {
  if (!sorted.any((CollectionMemberProgress m) => m.hasStarted)) return null;
  final int idx = continueMemberIndex(sorted);
  if (sorted[idx].isFinished) return null;
  return idx;
}

/// 合集归组键：host 合集的自然键（类型 + 名字，与收养进本地合集的口径一致）。
String _membershipKey(RemoteCollectionMembership m) =>
    '${m.collectionType}|${m.collectionName}';

/// 组内顺序：host 组内 sortIndex，平局按身份键稳定排序。
int _compareMembers(
  RemoteCollectionMembership a,
  String aId,
  RemoteCollectionMembership b,
  String bId,
) {
  final int bySort = a.sortIndex.compareTo(b.sortIndex);
  return bySort != 0 ? bySort : aId.compareTo(bId);
}

int _maxOf(Iterable<int> values) =>
    values.fold<int>(0, (int a, int b) => a > b ? a : b);

RemoteContinueCandidate _bookCandidate(
  RemoteBookInfo b, {
  required int recentMs,
}) => RemoteContinueCandidate(
  kind: b.kind,
  id: b.downloadId,
  // BUG-1488：[title] 是 display-only（去重/封面缓存键走 [id]），所以取 host
  // 下发的显示名——母设备改过的书名在子设备首页「继续」上也得跟着变。
  title: b.displayName,
  recentMs: recentMs,
  percent: b.progressPercent,
  coverUrl: b.coverUrl,
  collectionName: b.collection?.collectionName,
);

RemoteContinueCandidate _videoCandidate(
  RemoteVideoInfo v, {
  required int recentMs,
}) => RemoteContinueCandidate(
  kind: MediaKind.video,
  id: v.id,
  title: v.title,
  recentMs: recentMs,
  coverUrl: v.coverUrl,
  collectionName: v.collection?.collectionName,
);

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
    ..sort(
      (ActivityEventRow a, ActivityEventRow b) =>
          b.timestampMs.compareTo(a.timestampMs),
    );
  return merged.length <= limit ? merged : merged.sublist(0, limit);
}
