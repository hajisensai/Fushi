import 'dart:async';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/torrent/video_resource_relevance.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';

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
/// 因而「动漫走 Nyaa、电影/剧集走内置公共索引器、Torznab 全域参与」的规则不会在
/// 三处漂移。域归属由 provider 自报（[VideoResourceProvider.categories]），本类
/// 只做交集 + 停用清单，不再持有任何 provider id 的知识。
class VideoResourceRegistry {
  VideoResourceRegistry(
    Iterable<VideoResourceProvider> providers, {
    Set<String> disabledProviderIds = const <String>{},
  })  : providers = List<VideoResourceProvider>.unmodifiable(providers),
        disabledProviderIds = Set<String>.unmodifiable(disabledProviderIds);

  final List<VideoResourceProvider> providers;

  /// 用户在设置里停用的内置源 id。停用是**不参与查询**，不是「查了再过滤掉」
  /// ——后者会让停用的源照样打出网络请求，失败照样进 failures 吓用户。
  final Set<String> disabledProviderIds;

  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final VideoDiscoveryCategory? category = request.media?.discoveryCategory;
    final List<VideoResourceProvider> applicable = providers
        .where(
          (VideoResourceProvider provider) =>
              !disabledProviderIds.contains(provider.id) &&
              videoResourceProviderApplies(provider, category),
        )
        .toList()
      ..sort(
        (VideoResourceProvider a, VideoResourceProvider b) =>
            a.priority.compareTo(b.priority),
      );
    final List<ProviderBatchResult<VideoResourceCandidate>> results =
        await Future.wait(
      applicable.map(
        (VideoResourceProvider provider) async {
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
        },
      ),
    );
    final ProviderBatchResult<VideoResourceCandidate> merged =
        ProviderBatchResult.merge(results);
    return ProviderBatchResult<VideoResourceCandidate>(
      // 先去重（identityKey + providerPriority），再按季号/标题贴合度重排。
      // Nyaa 只做模糊词匹配，不重排的话搜 "xxx 2" 会被做种更多的 S1/S3 压在前面。
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
  /// 不落库；因此 Torznab 必须重新 search 找回候选，再由同一个 provider 下载并
  /// 校验 metainfo。
  Future<TorrentAddPayload> resolveSelection({
    required VideoResourceSelection selection,
    required VideoResourceSearchRequest request,
  }) async {
    for (final VideoResourceProvider provider in providers) {
      if (!_providerMatches(provider.id, selection.providerId)) continue;
      final ProviderBatchResult<VideoResourceCandidate> result =
          await provider.search(request);
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
