/// galgame 元数据编排层（契约 §2.5）：搜索 / 按 ID 取 / mixed 多源解析。
///
/// **本层不碰数据库**：只产出 [GalgameMetadataDraft]（每源快照 → `galgame_sources`）与
/// 合并结果（→ 展示 / `galgames` 上提列），落库由调用方负责。
library;

import 'package:fushi/src/mining/metadata/adapters/bangumi_adapter.dart';
import 'package:fushi/src/mining/metadata/adapters/vndb_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';

/// mixed 解析结果：各源快照 + 合并后的展示 draft + 逐源失败原因。
class GalgameMixedResolution {
  const GalgameMixedResolution({
    required this.merged,
    required this.bySource,
    required this.failures,
    required this.notFound,
  });

  /// 合并 + custom 覆盖后的展示用 draft。
  final GalgameMetadataDraft merged;

  /// 抓成功的源快照（逐条写 `galgame_sources`）。
  final Map<GalgameMetadataSource, GalgameMetadataDraft> bySource;

  /// 抓失败的源 → 可读原因（UI 提示「bgm 抓取失败：…」，**不吞**）。
  final Map<GalgameMetadataSource, String> failures;

  /// 抓成功但源侧无此条目的源（404 / 空结果，与失败区分开）。
  final Set<GalgameMetadataSource> notFound;

  /// 是否有任何一个源拿到了数据。
  bool get hasAnyData => bySource.isNotEmpty;

  /// 是否有源失败（部分失败仍返回结果，只是带着这个标记）。
  bool get hasFailures => failures.isNotEmpty;
}

/// 元数据编排服务。adapter registry 可注入，测试传 mock adapter 即可全程离线。
class GalgameMetadataService {
  GalgameMetadataService({
    Map<GalgameMetadataSource, GalgameMetadataAdapter>? adapters,
    String? bangumiAccessToken,
  }) : _adapters = adapters ??
            <GalgameMetadataSource, GalgameMetadataAdapter>{
              GalgameMetadataSource.bgm:
                  BangumiMetadataAdapter(accessToken: bangumiAccessToken),
              GalgameMetadataSource.vndb: VndbMetadataAdapter(),
            };

  final Map<GalgameMetadataSource, GalgameMetadataAdapter> _adapters;

  /// 当前已注册的源（UI 列源选项直接读这个，加源零改动）。
  List<GalgameMetadataSource> get availableSources => <GalgameMetadataSource>[
        for (final GalgameMetadataSource s in GalgameMetadataSource.values)
          if (_adapters.containsKey(s)) s,
      ];

  /// 取某源的 adapter；未注册抛 [GalgameMetadataException]（配置错误，不该静默）。
  GalgameMetadataAdapter adapterFor(GalgameMetadataSource source) {
    final GalgameMetadataAdapter? adapter = _adapters[source];
    if (adapter == null) {
      throw GalgameMetadataException(
        'no adapter registered for source "${source.key}"',
        source: source,
      );
    }
    return adapter;
  }

  /// 该源某 ID 的网页外链。
  String externalUrl(GalgameMetadataSource source, String externalId) =>
      adapterFor(source).externalUrl(externalId);

  /// 搜索候选。
  ///
  /// 契约 §2.5：**输入本身就是合法 ID 时跳过搜索**，直接 `fetchById` 并把结果包成
  /// 单条候选——用户贴了 `v1234` 却让他从搜索结果里再挑一次很蠢。ID 查不到时回退空表。
  Future<List<SourceCandidate>> searchCandidates(
    GalgameMetadataSource source,
    String query, {
    int limit = 10,
  }) async {
    final GalgameMetadataAdapter adapter = adapterFor(source);
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const <SourceCandidate>[];
    }
    if (adapter.validateId(trimmed)) {
      final GalgameMetadataDraft? draft = await adapter.fetchById(trimmed);
      if (draft == null) {
        return const <SourceCandidate>[];
      }
      return <SourceCandidate>[candidateFromDraft(source, trimmed, draft)];
    }
    return adapter.searchByName(trimmed, limit: limit);
  }

  /// 按外部 ID 取完整 draft；源侧没有该条目返回 null，网络 / 解析失败抛
  /// [GalgameMetadataException]（带可读消息）。
  Future<GalgameMetadataDraft?> fetchDraft(
    GalgameMetadataSource source,
    String externalId,
  ) {
    return adapterFor(source).fetchById(externalId);
  }

  /// mixed 解析：并发抓多个源，逐源容错。
  ///
  /// 失败语义（§2.5）：
  /// - 部分源失败 → 降级为「该源为空」，结果照常返回，失败原因进 [GalgameMixedResolution.failures]；
  /// - **全部源都失败**（且没有任何一个源成功）→ 抛 [GalgameMetadataException]，消息里带上逐源原因；
  /// - 源侧「没这条」不算失败，进 [GalgameMixedResolution.notFound]。
  ///
  /// [externalIds] 为空时不算失败，直接返回只含 [custom] 覆盖层的结果。
  Future<GalgameMixedResolution> resolveMixed({
    required Map<GalgameMetadataSource, String> externalIds,
    GalgameCustomData? custom,
  }) async {
    final Map<GalgameMetadataSource, GalgameMetadataDraft> bySource =
        <GalgameMetadataSource, GalgameMetadataDraft>{};
    final Map<GalgameMetadataSource, String> failures =
        <GalgameMetadataSource, String>{};
    final Set<GalgameMetadataSource> notFound = <GalgameMetadataSource>{};

    // 不同源之间互不干扰，并发发起；每源内部各自的限流桶会把节奏压住。
    final List<GalgameMetadataSource> sources = externalIds.keys.toList();
    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      for (final GalgameMetadataSource s in sources)
        _tryFetch(s, externalIds[s]!),
    ]);

    for (int i = 0; i < sources.length; i++) {
      final GalgameMetadataSource s = sources[i];
      final Object? result = results[i];
      if (result is GalgameMetadataDraft) {
        bySource[s] = result;
      } else if (result is GalgameMetadataException) {
        failures[s] = result.toString();
      } else {
        notFound.add(s);
      }
    }

    if (bySource.isEmpty && notFound.isEmpty && failures.isNotEmpty) {
      final String detail = failures.entries
          .map((MapEntry<GalgameMetadataSource, String> e) =>
              '${e.key.label}: ${e.value}')
          .join('; ');
      throw GalgameMetadataException('all metadata sources failed — $detail');
    }

    return GalgameMixedResolution(
      merged: mergeDrafts(bySource, custom: custom),
      bySource: bySource,
      failures: failures,
      notFound: notFound,
    );
  }

  /// 抓一个源：成功 → draft，源侧无此条目 → null，失败 → 返回（而不是抛）异常对象，
  /// 由 [resolveMixed] 统一判定「部分失败」还是「全军覆没」。
  Future<Object?> _tryFetch(
    GalgameMetadataSource source,
    String externalId,
  ) async {
    try {
      return await fetchDraft(source, externalId);
    } on GalgameMetadataException catch (e) {
      return e;
    } catch (e) {
      return GalgameMetadataException(
        'unexpected failure: $e',
        source: source,
      );
    }
  }

  /// 释放所有 adapter 的 HTTP 资源。
  void close() {
    for (final GalgameMetadataAdapter adapter in _adapters.values) {
      adapter.close();
    }
  }
}

/// 把一份 draft 降级成候选项（ID 直取路径复用候选列表 UI）。纯函数。
SourceCandidate candidateFromDraft(
  GalgameMetadataSource source,
  String externalId,
  GalgameMetadataDraft draft,
) {
  return SourceCandidate(
    source: source,
    externalId: draft.externalId ?? externalId,
    name: draft.name,
    nameCn: draft.nameCn,
    coverUrl: draft.coverUrl,
    releaseDate: draft.releaseDate,
    summary: summaryExcerpt(draft.summary),
  );
}
