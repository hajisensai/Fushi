import 'dart:async';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
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

/// [providerId]（含持久化形式 `<format>:<instance>` 与旧内置源的裸 `nyaa`）
/// 是不是用户 BT 站那几种格式的 provider。
bool isBtSiteProviderId(String providerId) =>
    BtSiteFormat.fromWire(providerId.trim().split(':').first) != null;

/// 资源搜索的共享入口。发现详情页、下载模块“资源”页和订阅调度都使用同一实例，
/// 因而「用户 BT 站按各自生效的域参与、Torznab 全域参与」的规则不会在三处漂移。
/// 域归属由 provider 自报（[VideoResourceProvider.categories]），本类只做交集，
/// 不持有任何站点的知识。没有用户站点也没配 Torznab 时 [providers] 为空。
class VideoResourceRegistry {
  VideoResourceRegistry(Iterable<VideoResourceProvider> providers)
      : providers = List<VideoResourceProvider>.unmodifiable(providers);

  final List<VideoResourceProvider> providers;

  /// 持久化的 provider id（订阅 / 下载任务 / 订阅条目上记的那个）→ 当前注册表里
  /// 实际负责它的 provider。**存量 provider id 的解析只在这一处**：订阅服务、
  /// 下载流水线重解析、无头服务端都走这里。
  ///
  /// * 非 BT 站格式（`torznab:<indexer>` 等）：沿用原规则——id 相同或以
  ///   `<provider.id>:` 开头。
  /// * BT 站格式（`nyaa` / `apibay` / `knaben` 前缀）：
  ///   1. 精确命中 `<format>:<siteId>` 且该站对 [category] 生效 → 就是它；
  ///   2. 否则（旧内置源的 `nyaa:nyaa.si` / `nyaa:default` / 裸 `nyaa`，或站点已
  ///      删除 / 停用 / 不再覆盖该域）→ **第一个**同格式、对 [category] 生效的
  ///      用户站点（注册表只含启用站点，顺序 = 用户设置里的顺序）；
  ///   3. 找不到 → null（调用方据此暂停并提示「请先添加 BT 站」）。
  ///
  /// [category] 为 null（没有作品身份）时不按域筛。
  VideoResourceProvider? resolveProvider(
    String persistedProviderId, {
    VideoDiscoveryCategory? category,
  }) {
    final String selected = persistedProviderId.trim();
    final BtSiteFormat? format = BtSiteFormat.fromWire(
      selected.split(':').first,
    );
    if (format == null) {
      for (final VideoResourceProvider provider in providers) {
        if (_providerMatches(provider.id, selected)) return provider;
      }
      return null;
    }
    bool covers(VideoResourceProvider provider) =>
        category == null || videoResourceProviderApplies(provider, category);
    for (final VideoResourceProvider provider in providers) {
      if (provider.id == selected && covers(provider)) return provider;
    }
    for (final VideoResourceProvider provider in providers) {
      if (provider.id.startsWith('${format.name}:') && covers(provider)) {
        return provider;
      }
    }
    return null;
  }

  /// 返回值带按源回执（[VideoResourceSearchResult.sources]，按 provider 优先级
  /// 排序、每个参与的 provider 一份）：资源页据此逐源显示「N 条（查询词）/ 失败
  /// 原因」，成功但 0 条也看得见（BUG-2794）。
  Future<VideoResourceSearchResult> search(
    VideoResourceSearchRequest request,
  ) async {
    final VideoDiscoveryCategory? category = request.media?.discoveryCategory;
    final List<VideoResourceProvider> applicable = providers
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
    return VideoResourceSearchResult(
      sources: <VideoResourceSourceReport>[
        for (int index = 0; index < applicable.length; index++)
          videoResourceSourceReportOf(
            providerId: applicable[index].id,
            result: results[index],
            fallbackQuery: request.effectiveQuery,
          ).withDisplayName(
            switch (applicable[index]) {
              final LabeledVideoResourceProvider labeled =>
                labeled.displayName,
              _ => null,
            },
          ),
      ],
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
  /// 校验 metainfo。provider 经 [resolveProvider] 找（存量 BT 站 id 会解析到
  /// 当前同格式的用户站点）。
  Future<TorrentAddPayload> resolveSelection({
    required VideoResourceSelection selection,
    required VideoResourceSearchRequest request,
  }) async {
    final VideoResourceProvider? provider = resolveProvider(
      selection.providerId,
      category: request.media?.discoveryCategory,
    );
    if (provider != null) {
      // BT 站：候选按解析到的那个站认（persisted id == provider.id）；其余按原
      // 持久化 id 认。
      final String expected = isBtSiteProviderId(selection.providerId)
          ? provider.id
          : selection.providerId;
      final ProviderBatchResult<VideoResourceCandidate> result =
          await provider.search(request);
      for (final VideoResourceCandidate candidate in result.items) {
        if (candidate.remoteId == selection.remoteId &&
            (candidate.providerId == expected ||
                persistedVideoResourceProviderId(candidate) == expected)) {
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
