/// 刮削编排的 UI 侧入口：把「用户输入一串文字」变成「一批候选」再变成「一份 draft」。
///
/// 契约 §2.5 的交互规则全在这里：
/// - 输入即 ID（某源 `validateId` 命中）→ 跳过搜索直接 `fetchById`；
/// - 多结果 → 交给调用方弹候选列表（本类只负责把多源候选拼成一条列表）；
/// - mixed 下部分源失败 → 该源降级为空，**全部源失败**才抛。
///
/// > 这是 UI 与 adapter 之间的**薄编排层**。契约 §2 规划的 `GalgameMetadataService`
/// > 落地后，把 [instance] 换成转发到 service 的实现即可，页面代码零改动——页面只依赖
/// > 本类的三个方法，不直接 new adapter。
library;

import 'package:hibiki/src/mining/metadata/adapters/bangumi_adapter.dart';
import 'package:hibiki/src/mining/metadata/adapters/vndb_adapter.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_source.dart';

/// 一次搜索的结果：候选列表 + 各源失败原因（部分失败时用于给用户可读提示）。
class GalgameScrapeSearchResult {
  const GalgameScrapeSearchResult({
    required this.candidates,
    this.failures = const <GalgameMetadataSource, String>{},
  });

  /// 全部源的候选合并列表（按源枚举顺序，源内保序）。
  final List<SourceCandidate> candidates;

  /// 失败的源 → 可读原因。全源失败时 [candidates] 为空且这里非空。
  final Map<GalgameMetadataSource, String> failures;

  bool get isEmpty => candidates.isEmpty;
}

class GalgameScrapeController {
  GalgameScrapeController({List<GalgameMetadataAdapter>? adapters})
      : _adapters = adapters ??
            <GalgameMetadataAdapter>[
              BangumiMetadataAdapter(),
              VndbMetadataAdapter(),
            ];

  /// 进程级单例（页面用）。测试注入假 adapter 时直接替换。
  static GalgameScrapeController instance = GalgameScrapeController();

  final List<GalgameMetadataAdapter> _adapters;

  List<GalgameMetadataAdapter> get adapters =>
      List<GalgameMetadataAdapter>.unmodifiable(_adapters);

  GalgameMetadataAdapter? adapterFor(GalgameMetadataSource source) {
    for (final GalgameMetadataAdapter adapter in _adapters) {
      if (adapter.source == source) return adapter;
    }
    return null;
  }

  /// 该源某 ID 的网页外链；无对应 adapter 返回 null。
  String? externalUrl(GalgameMetadataSource source, String externalId) =>
      adapterFor(source)?.externalUrl(externalId);

  /// 按用户输入搜索候选。
  ///
  /// [sources] 限定参与的源（默认全部）。输入被某源识别为 ID 时**只**查那个源并直接
  /// 取详情（省一次搜索往返，也避免把 ID 当关键词搜出一堆无关条目）。
  Future<GalgameScrapeSearchResult> search(
    String query, {
    Set<GalgameMetadataSource>? sources,
    int limit = 10,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const GalgameScrapeSearchResult(candidates: <SourceCandidate>[]);
    }
    final List<GalgameMetadataAdapter> used = <GalgameMetadataAdapter>[
      for (final GalgameMetadataAdapter a in _adapters)
        if (sources == null || sources.contains(a.source)) a,
    ];

    // 输入即 ID：直接取详情包成单条候选。
    for (final GalgameMetadataAdapter adapter in used) {
      if (!adapter.validateId(trimmed)) continue;
      final GalgameMetadataDraft? draft = await adapter.fetchById(trimmed);
      if (draft == null) {
        return const GalgameScrapeSearchResult(candidates: <SourceCandidate>[]);
      }
      return GalgameScrapeSearchResult(
        candidates: <SourceCandidate>[
          SourceCandidate(
            source: adapter.source,
            externalId: draft.externalId ?? trimmed,
            name: draft.name,
            nameCn: draft.nameCn,
            coverUrl: draft.coverUrl,
            releaseDate: draft.releaseDate,
            summary: summaryExcerpt(draft.summary),
          ),
        ],
      );
    }

    final List<SourceCandidate> candidates = <SourceCandidate>[];
    final Map<GalgameMetadataSource, String> failures =
        <GalgameMetadataSource, String>{};
    for (final GalgameMetadataAdapter adapter in used) {
      try {
        candidates.addAll(await adapter.searchByName(trimmed, limit: limit));
      } on GalgameMetadataException catch (e) {
        // 单源失败降级为空（§2.5），不整体失败。
        failures[adapter.source] = e.message;
      } catch (e) {
        failures[adapter.source] = e.toString();
      }
    }
    if (candidates.isEmpty &&
        failures.length == used.length &&
        used.isNotEmpty) {
      // 全部源都失败：这不是「搜不到」，必须让 UI 报错而不是显示空列表。
      throw GalgameMetadataException(
        failures.values.join('; '),
      );
    }
    return GalgameScrapeSearchResult(
      candidates: candidates,
      failures: failures,
    );
  }

  /// 取某源某 ID 的完整 draft（候选选中后补全）。未找到返回 null。
  Future<GalgameMetadataDraft?> fetchById(
    GalgameMetadataSource source,
    String externalId,
  ) async {
    final GalgameMetadataAdapter? adapter = adapterFor(source);
    if (adapter == null) {
      return null;
    }
    return adapter.fetchById(externalId);
  }
}
