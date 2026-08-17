/// 发现源聚合：把一次请求扇出到（按能力筛过的）多个源，保留部分成功。
///
/// 刻意**不做**跨源去重合并——资源发现（种子/直链）不同于视频元数据发现：
/// 同名资源在不同源就是不同的下载物（版本/压制/打包都不同），合并只会
/// 抹掉用户要做的选择。结果按源分片（[DiscoverySourceSlice]）返回，
/// UI 想平铺就用 [DiscoveryAggregateResult.entries]，想分组就用 slices。
library;

import 'dart:async';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';

/// 一个源贡献的结果分片。
class DiscoverySourceSlice {
  const DiscoverySourceSlice({required this.sourceId, required this.page});

  final String sourceId;
  final DiscoveryResultPage page;
}

/// 聚合结果：分片按源 priority 顺序排列；失败与成功并存（部分成功语义
/// 与 `ProviderBatchResult` 一致：单源挂了亮徽标，不拖垮整页）。
class DiscoveryAggregateResult {
  DiscoveryAggregateResult({
    Iterable<DiscoverySourceSlice> slices = const <DiscoverySourceSlice>[],
    Iterable<ExternalProviderFailure> failures =
        const <ExternalProviderFailure>[],
    this.successfulSourceCount = 0,
  })  : slices = List<DiscoverySourceSlice>.unmodifiable(slices),
        failures = List<ExternalProviderFailure>.unmodifiable(failures);

  final List<DiscoverySourceSlice> slices;
  final List<ExternalProviderFailure> failures;
  final int successfulSourceCount;

  /// 平铺视图（保持源 priority 顺序）。
  List<DiscoveryEntry> get entries => <DiscoveryEntry>[
        for (final DiscoverySourceSlice slice in slices) ...slice.page.entries,
      ];

  bool get hasMore =>
      slices.any((DiscoverySourceSlice slice) => slice.page.hasMore);

  bool get hasFailures => failures.isNotEmpty;

  /// 空结果 + 一个源宕机 ≠ 全绿的空结果——语义对齐 `ProviderBatchResult.isPartial`。
  bool get isPartial => successfulSourceCount > 0 && hasFailures;
  bool get isTotalFailure => successfulSourceCount == 0 && hasFailures;
}

/// 发现源注册表 + 请求扇出。无状态（源开关/默认源等用户偏好由组装点筛好
/// 再构造，或经 [sourceById] 单源直查），生命周期由持有者管理。
class MediaDiscoveryService {
  MediaDiscoveryService({required Iterable<MediaDiscoverySource> sources})
      : _sources = List<MediaDiscoverySource>.of(sources)
          ..sort(
            (MediaDiscoverySource a, MediaDiscoverySource b) =>
                a.priority.compareTo(b.priority),
          );

  final List<MediaDiscoverySource> _sources;

  List<MediaDiscoverySource> get sources =>
      List<MediaDiscoverySource>.unmodifiable(_sources);

  MediaDiscoverySource? sourceById(String id) {
    for (final MediaDiscoverySource source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  /// 支持 [kind] 的源，按 priority 排序（源切换下拉的选项列表）。
  List<MediaDiscoverySource> sourcesFor(DiscoveryMediaKind kind) => _sources
      .where(
        (MediaDiscoverySource s) => s.capabilities.kinds.contains(kind),
      )
      .toList();

  /// 执行一次发现请求。
  ///
  /// [sourceId] null = 「全部源」：扇出到所有支持该域、且具备本次请求所需
  /// 能力（搜索/浏览）的源。深层目录浏览（`request.path != null`）的路径是
  /// 源内语义，聚合无意义，必须指定 [sourceId]，否则 [ArgumentError]。
  ///
  /// [disabledSourceIds] 只作用于聚合扇出（默认聚合排除的源，如 18+ 源）；
  /// 显式指定 [sourceId] 时不受它限制——用户点名即同意。
  Future<DiscoveryAggregateResult> load(
    DiscoveryRequest request, {
    String? sourceId,
    Set<String> disabledSourceIds = const <String>{},
  }) async {
    if (request.path != null && sourceId == null) {
      throw ArgumentError(
        'deep browse paths are source-local; pass sourceId',
      );
    }

    final List<MediaDiscoverySource> candidates;
    if (sourceId != null) {
      final MediaDiscoverySource? source = sourceById(sourceId);
      if (source == null) {
        throw ArgumentError.value(sourceId, 'sourceId', 'unknown source');
      }
      candidates = <MediaDiscoverySource>[source];
    } else {
      candidates = sourcesFor(request.kind)
          .where(
            (MediaDiscoverySource s) =>
                !disabledSourceIds.contains(s.id) &&
                (request.isSearch
                    ? s.capabilities.supportsSearch
                    : s.capabilities.supportsBrowse),
          )
          .toList();
    }
    if (candidates.isEmpty) return DiscoveryAggregateResult();

    final List<ProviderBatchResult<DiscoveryResultPage>> results =
        await Future.wait(
      candidates.map(
        (MediaDiscoverySource source) => _invoke(source, request),
      ),
    );

    final List<DiscoverySourceSlice> slices = <DiscoverySourceSlice>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    int successfulSourceCount = 0;
    for (int i = 0; i < candidates.length; i++) {
      final ProviderBatchResult<DiscoveryResultPage> result = results[i];
      for (final DiscoveryResultPage page in result.items) {
        slices.add(
          DiscoverySourceSlice(sourceId: candidates[i].id, page: page),
        );
      }
      failures.addAll(result.failures);
      if (result.successfulProviderCount > 0) successfulSourceCount++;
    }
    return DiscoveryAggregateResult(
      slices: slices,
      failures: failures,
      successfulSourceCount: successfulSourceCount,
    );
  }

  /// 单源调用：源实现抛出的任何东西都收敛成脱敏失败，绝不让一个源的异常
  /// 炸掉整次扇出。
  Future<ProviderBatchResult<DiscoveryResultPage>> _invoke(
    MediaDiscoverySource source,
    DiscoveryRequest request,
  ) async {
    try {
      return request.isSearch
          ? await source.search(request)
          : await source.browse(request);
    } catch (e) {
      return ProviderBatchResult<DiscoveryResultPage>.failure(
        ExternalProviderFailure.fromException(
          providerId: source.id,
          operation: request.isSearch ? 'search' : 'browse',
          error: e,
        ),
      );
    }
  }

  void close() {
    for (final MediaDiscoverySource source in _sources) {
      source.close();
    }
  }
}
