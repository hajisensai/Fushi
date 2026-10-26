import 'dart:async';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_relevance.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

class VideoResourceSelection {
  const VideoResourceSelection({
    required this.providerId,
    required this.remoteId,
    required this.title,
  });

  final String providerId;
  final String remoteId;
  final String title;
}

String persistedVideoResourceProviderId(VideoResourceCandidate candidate) =>
    '${candidate.providerId}:${candidate.providerInstanceId}';

/// 资源搜索的共享入口。发现详情页、下载模块“资源”页和订阅调度都使用同一实例，
/// 因而域规则不会在三处漂移。仓库不内置任何 BT 搜索站：来源只有用户自配的
/// RSS 搜索站（每个站自己勾参与哪些视频域，provider 内部逐站裁）与 Torznab
/// （不限域）。域归属由 provider 自报（[VideoResourceProvider.categories]），本类
/// 只做交集，不持有任何 provider id 的知识；启停是各条配置自己的 `enabled`，
/// 「注册了 = 这台设备上配好了」。
class VideoResourceRegistry {
  VideoResourceRegistry(Iterable<VideoResourceProvider> providers)
    : providers = List<VideoResourceProvider>.unmodifiable(providers);

  final List<VideoResourceProvider> providers;

  /// 返回值带按源回执（[VideoResourceSearchResult.sources]，按 provider 优先级
  /// 排序；单实例 provider 一份，RSS 搜索站每个参与的站一份 `rss:<siteId>`）：资源页据此逐源显示「N 条（查询词）/ 失败
  /// 原因」，成功但 0 条也看得见（BUG-2794）。
  Future<VideoResourceSearchResult> search(
    VideoResourceSearchRequest request,
  ) async {
    final VideoDiscoveryCategory? category = request.media?.discoveryCategory;
    final List<VideoResourceProvider> applicable =
        providers
            .where(
              (VideoResourceProvider provider) =>
                  videoResourceProviderApplies(provider, category),
            )
            .toList()
          ..sort(
            (VideoResourceProvider a, VideoResourceProvider b) =>
                a.priority.compareTo(b.priority),
          );
    final List<ProviderBatchResult<VideoResourceCandidate>> results =
        await Future.wait(
          applicable.map((VideoResourceProvider provider) async {
            try {
              return await provider.search(request);
            } on Object catch (error) {
              return ProviderBatchResult<VideoResourceCandidate>.failure(
                ExternalProviderFailure.fromException(
                  providerId: provider.id,
                  operation: 'search',
                  error: error,
                ),
              );
            }
          }),
        );
    final ProviderBatchResult<VideoResourceCandidate> merged =
        ProviderBatchResult.merge(results);
    return VideoResourceSearchResult(
      sources: <VideoResourceSourceReport>[
        for (int index = 0; index < applicable.length; index++)
          ...videoResourceSourceReportsOf(
            providerId: applicable[index].id,
            result: results[index],
            fallbackQuery: request.effectiveQuery,
          ),
      ],
      // 先去重（identityKey + providerPriority），再按季号/标题贴合度重排。
      // 种子站只做模糊词匹配，不重排的话搜 "xxx 2" 会被做种更多的 S1/S3 压在前面。
      items: rankVideoResourcesByRelevance(
        deduplicateVideoResources(merged.items),
        query: request.effectiveQuery,
        season: request.effectiveSeason,
      ),
      failures: merged.failures,
      successfulProviderCount: merged.successfulProviderCount,
    );
  }

  /// 重启后按持久化的 provider+remote id 重新解析资源。HTTP torrent 临时 URL
  /// 不落库；因此 Torznab / RSS 搜索站必须重新 search 找回候选，再由同一个
  /// provider 下载并校验 metainfo。[request] 带上 `providerInstanceId`（持久化
  /// id 冒号后那段）时多实例 provider 只重搜那一个站。
  Future<TorrentAddPayload> resolveSelection({
    required VideoResourceSelection selection,
    required VideoResourceSearchRequest request,
  }) async {
    for (final VideoResourceProvider provider in providers) {
      if (!_providerMatches(provider.id, selection.providerId)) continue;
      final ProviderBatchResult<VideoResourceCandidate> result = await provider
          .search(request);
      for (final VideoResourceCandidate candidate in result.items) {
        if (candidate.remoteId == selection.remoteId &&
            (candidate.providerId == selection.providerId ||
                persistedVideoResourceProviderId(candidate) ==
                    selection.providerId)) {
          return provider.resolve(candidate);
        }
      }
      if (result.isTotalFailure) {
        throw result.failures.first;
      }
    }
    throw ExternalProviderFailure(
      providerId: selection.providerId,
      operation: 'resolve',
      kind: ExternalProviderFailureKind.notFound,
      message: 'selected resource is no longer available',
    );
  }

  void close() {
    for (final VideoResourceProvider provider in providers) {
      provider.close();
    }
  }

  static bool _providerMatches(String providerId, String selectedId) =>
      providerId == selectedId || selectedId.startsWith('$providerId:');
}
