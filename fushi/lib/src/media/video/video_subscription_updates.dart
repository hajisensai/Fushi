import 'package:fushi_core/fushi_core.dart'
    show
        MediaCollectionRow,
        VideoDownloadJobRow,
        VideoDownloadSubscriptionItemRow,
        VideoDownloadSubscriptionRow;

import 'package:fushi/src/media/video/video_home_layout.dart';

/// 视频首页「已更新未看」行的纯函数：订阅 → 合集解析 + 合集内未看目标集选取。
///
/// 用户视角（2026-09-06）：「订阅的动漫更新了就看，跟收菜一样」——首页要有一行
/// 列出**订阅过、且有集数还没看**的作品，点开直接播第一集没看的。两套订阅链路
/// 各自落合集的方式不同，这里统一解析成合集 id 集合，页面按合集折叠成员即可，
/// 与「下一集」「最近添加」两行同一成员序列口径。
///
/// 全部无副作用，单测在 `test/media/video/video_subscription_updates_test.dart`。

/// 新链路（Drift `video_download_subscriptions`）+ 旧链路（AniList JSON 订阅）的
/// 订阅作品 → 已入库合集 id。
///
/// 解析顺序（同一订阅多条路径命中取并集，不互斥）：
/// * `subscriptions[i].collectionId` 直绑（列存在但 pipeline 目前不回写，留作前向
///   兼容）；
/// * 订阅条目 → 任务 → `VideoDownloadJobs.collectionId`（pipeline 入库后回写，是
///   新链路的主路径）；
/// * 订阅的元数据身份 `(metadataProvider, externalId)` → 同身份的任务 → 合集
///   （与订阅服务 `_managedEpisodeKeys` 同口径：条目 `jobId` 因任务删除被
///   setNull 后仍能靠身份找回）；
/// * 订阅的元数据身份 → 刮削作品 → 合集（[collectionIdByProviderIdentity] 由
///   调用方按订阅逐条查好，键 `'$provider|$externalId'`）；
/// * 旧链路：订阅 `anilistId` → `MediaCollections.anilistId` 直绑。
///
/// **不看 `enabled`**：暂停/已完成（oneShot fulfilled）的订阅仍是「订阅过的作品」，
/// 已下载未看的集数照样该出现在这一行。
Set<int> subscribedVideoCollectionIds({
  required List<VideoDownloadSubscriptionRow> subscriptions,
  required Map<String, List<VideoDownloadSubscriptionItemRow>>
      itemsBySubscription,
  required List<VideoDownloadJobRow> jobs,
  required Map<String, int> collectionIdByProviderIdentity,
  required Iterable<int> legacyAnilistIds,
  required Iterable<MediaCollectionRow> collections,
}) {
  final Set<int> out = <int>{};
  final Map<String, int> collectionByJob = <String, int>{
    for (final VideoDownloadJobRow job in jobs)
      if (job.collectionId case final int cid) job.jobId: cid,
  };
  final Map<String, Set<int>> collectionsByJobIdentity = <String, Set<int>>{};
  for (final VideoDownloadJobRow job in jobs) {
    final String? provider = job.metadataProvider;
    final String? externalId = job.externalId;
    final int? cid = job.collectionId;
    if (provider == null || externalId == null || cid == null) continue;
    collectionsByJobIdentity
        .putIfAbsent(providerIdentityKey(provider, externalId), () => <int>{})
        .add(cid);
  }
  for (final VideoDownloadSubscriptionRow sub in subscriptions) {
    if (sub.collectionId case final int cid) out.add(cid);
    for (final VideoDownloadSubscriptionItemRow item
        in itemsBySubscription[sub.subscriptionId] ??
            const <VideoDownloadSubscriptionItemRow>[]) {
      final String? jobId = item.jobId;
      if (jobId == null) continue;
      if (collectionByJob[jobId] case final int cid) out.add(cid);
    }
    final String? provider = sub.metadataProvider;
    final String? externalId = sub.externalId;
    if (provider != null && externalId != null) {
      final String key = providerIdentityKey(provider, externalId);
      out.addAll(collectionsByJobIdentity[key] ?? const <int>{});
      if (collectionIdByProviderIdentity[key] case final int cid) out.add(cid);
    }
  }
  final Set<int> anilist = legacyAnilistIds.toSet();
  if (anilist.isNotEmpty) {
    for (final MediaCollectionRow c in collections) {
      if (c.anilistId case final int id when anilist.contains(id)) {
        out.add(c.id);
      }
    }
  }
  return out;
}

/// [subscribedVideoCollectionIds] 的 `collectionIdByProviderIdentity` 键。
String providerIdentityKey(String provider, String externalId) =>
    '$provider|$externalId';

/// 一个订阅合集在「已更新未看」行里的展示事实。
class VideoSubscriptionUpdate {
  const VideoSubscriptionUpdate({
    required this.targetIndex,
    required this.unwatchedCount,
    required this.latestUnwatchedImportedAtMs,
  });

  /// 点卡片要播的那集（合集稳定集序下标，0 起）。
  final int targetIndex;

  /// 还没看的集数（`!completed && positionMs <= 0`，与库页「未看」筛选同判据）。
  final int unwatchedCount;

  /// 未看成员里最新的入库时刻（行内排序键；成员都没有入库时刻 = 0）。
  final int latestUnwatchedImportedAtMs;
}

/// 选出合集的「已更新未看」事实；一集未看的都没有 → null（不占行）。
///
/// 目标集：最近实际播放的那集**之后**的第一集未看（Next-Up 口径，与
/// [nextEpisodeAfterLatestPlayed] 同源——用户跳着看时不把已跳过的旧集塞回来）；
/// 之后没有未看（或从没播过）→ 整个合集里第一集未看。
///
/// [members] 与 [importedAtMs] 按合集稳定集序对齐、等长；入库时刻 null（远端旧
/// host 不带）按 0 计。
VideoSubscriptionUpdate? selectVideoSubscriptionUpdate(
  List<VideoSeriesPlaybackState> members,
  List<int?> importedAtMs,
) {
  assert(members.length == importedAtMs.length);
  int unwatched = 0;
  int latestImported = 0;
  int? firstUnwatched;
  final int? latestPlayed = latestPlayedSeriesIndex(members);
  int? firstUnwatchedAfterPlayed;
  for (int index = 0; index < members.length; index++) {
    final VideoSeriesPlaybackState state = members[index];
    final bool isUnwatched = !state.completed && state.positionMs <= 0;
    if (!isUnwatched) continue;
    unwatched++;
    firstUnwatched ??= index;
    if (latestPlayed != null && index > latestPlayed) {
      firstUnwatchedAfterPlayed ??= index;
    }
    final int imported = importedAtMs[index] ?? 0;
    if (imported > latestImported) latestImported = imported;
  }
  if (firstUnwatched == null) return null;
  return VideoSubscriptionUpdate(
    targetIndex: firstUnwatchedAfterPlayed ?? firstUnwatched,
    unwatchedCount: unwatched,
    latestUnwatchedImportedAtMs: latestImported,
  );
}
