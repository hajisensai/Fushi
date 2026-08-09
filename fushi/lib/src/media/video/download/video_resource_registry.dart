import 'dart:async';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
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
/// 因而动漫的 Nyaa+Torznab 与电影/剧集的 Torznab 规则不会在三处漂移。
class VideoResourceRegistry {
  VideoResourceRegistry(Iterable<VideoResourceProvider> providers)
      : providers = List<VideoResourceProvider>.unmodifiable(providers);

  final List<VideoResourceProvider> providers;

  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final bool anime =
        request.media?.discoveryCategory == VideoDiscoveryCategory.anime;
    final List<VideoResourceProvider> applicable = providers
        .where(
          (VideoResourceProvider provider) =>
              provider.id == 'torznab' || (anime && provider.id == 'nyaa'),
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
      items: deduplicateVideoResources(merged.items),
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
