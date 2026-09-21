/// 发现页「入队下载 / 创建订阅」的提交逻辑（从 `home_page.dart` 的组合根抽出）。
///
/// 三个顶层纯函数，不碰 Riverpod / BuildContext：发现页的资源搜索页、订阅页与
/// 后续的 AI 下载流程共用同一份落库形状，保证同一作品无论从哪条入口提交，任务行
/// / 订阅行的字段口径一致。
library;

import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/media/video/download/video_discovery_selection.dart'
    show
        VideoDiscoveryDownloadSelection,
        VideoDiscoverySubscriptionSelection,
        videoDiscoverySubscriptionId;
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        VideoDownloadSubscriptionRow,
        VideoDownloadSubscriptionsCompanion;
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_media_reference_codec.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// 订阅行 `searchQuery` 的默认值：anime 走 Nyaa 首选搜索词（罗马字 / 日文优先），
/// 其它分类直接用标题。原为 `home_page.dart` 的私有 `_videoResourceSearchQuery`，
/// 抽出供发现页本地订阅、host 远程订阅与后续 AI 下载流程共用。
String videoResourceSubscriptionSearchQuery(VideoMediaReference reference) {
  if (reference.discoveryCategory != VideoDiscoveryCategory.anime) {
    return reference.title;
  }
  final List<String> queries = preferredNyaaSearchQueries(
    VideoResourceSearchRequest(media: reference),
  );
  return queries.isEmpty ? reference.title : queries.first;
}

/// 把资源搜索页选中的一条发布交给本地下载管线入队，返回 jobId。
///
/// 原为 `home_page.dart` 资源搜索页 `onSubmit` 内联的
/// `VideoDownloadEnqueueRequest` 构造，抽出供发现页与后续 AI 下载流程共用。
/// [target] 由调用方在提交那一刻取（后端可用性延后到提交时判，PR #1021）。
Future<String> enqueueLocalVideoDownload({
  required VideoDownloadPipelineService pipeline,
  String? coverUrl,
  required VideoDiscoveryDownloadSelection selection,
  required VideoDownloadBackendTarget target,
}) {
  // 保留发现来源提供的 MAL / TMDB 精确身份，导入时优先 MAL。
  final VideoMediaReference media = selection.media;
  return pipeline.enqueue(
    VideoDownloadEnqueueRequest(
      media: media,
      resource: selection.resource,
      backendTarget: target,
      targetSourceId: selection.source.id,
      subtitlePolicy: selection.subtitlePolicy,
      coverUrl: coverUrl,
    ),
  );
}

/// 为发现条目创建（或按同一稳定 id 覆盖）一条本地下载订阅，并立即触发一次检查。
///
/// 原为 `home_page.dart` 订阅页 `onSubmit` 的主体，抽出供发现页与后续 AI 下载
/// 流程共用。再次提交同一作品保留首次 `createdAt`；[searchQuery] 缺省取
/// [videoResourceSubscriptionSearchQuery]；[checkNow] 为订阅服务的立即检查
/// （服务未装配时传 null）；[nowMs] 供测试钉时间。
Future<void> createLocalVideoDownloadSubscription({
  required FushiDatabase database,
  required VideoMediaReference reference,
  String? coverUrl,
  required VideoDiscoverySubscriptionSelection selection,
  required VideoDownloadBackendTarget target,
  String? searchQuery,
  Future<void> Function()? checkNow,
  int? nowMs,
}) async {
  final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final String subscriptionId = videoDiscoverySubscriptionId(reference);
  final VideoDownloadSubscriptionRow? previous = await database
      .getVideoDownloadSubscription(subscriptionId);
  final VideoResourceCandidate resource = selection.download.resource;
  // 订阅快照保留交叉 ID，每集下载可沿用同一个 MAL / TMDB 身份。
  await database.upsertVideoDownloadSubscription(
    VideoDownloadSubscriptionsCompanion.insert(
      subscriptionId: subscriptionId,
      resourceProvider: persistedVideoResourceProviderId(resource),
      metadataProvider: Value<String?>(reference.providerId),
      externalId: Value<String?>(reference.mediaId),
      mediaKind: reference.mediaKind.name,
      discoveryCategory: Value<String?>(reference.discoveryCategory.name),
      title: reference.title,
      year: Value<int?>(reference.year),
      season: Value<int?>(reference.season),
      coverUrl: Value<String?>(coverUrl),
      identityJson: Value<String?>(encodeVideoMediaReference(reference)),
      searchQuery:
          searchQuery ?? videoResourceSubscriptionSearchQuery(reference),
      filterJson: Value<String>(selection.filter.json),
      mode: Value<String>(
        // 整包（用户选中的就是合集 / 全集）与电影一样只下一次：追更语义下整包
        // 永远不是「新的一集」，按追更建出来的规则结构上永不命中（BUG-2619）。
        selection.batchRelease ||
                reference.mediaKind == VideoMetadataMediaKind.movie
            ? 'oneShot'
            : 'ongoing',
      ),
      startAfterEpisode: Value<int?>(selection.startAfterEpisode),
      backendKind: target.kind,
      backendProfileId: Value<String?>(target.profileId),
      fingerprint: target.fingerprint,
      category: Value<String?>(target.category),
      targetSourceId: Value<int?>(selection.download.source.id),
      organizationPolicy: const Value<String>('library'),
      subtitlePolicy: Value<String>(selection.download.subtitlePolicy.name),
      enabled: const Value<bool>(true),
      nextCheckAt: Value<int?>(now),
      claimedBy: const Value<String?>(null),
      claimExpiresAt: const Value<int?>(null),
      retryCount: const Value<int>(0),
      fulfilledAt: const Value<int?>(null),
      lastError: const Value<String?>(null),
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
    ),
  );
  await checkNow?.call();
}
