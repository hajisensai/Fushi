/// 跨来源自动匹配：给一条 AniList 发现条目，在全部已启用来源里找出最像的
/// 可读条目（用户决策：全自动，不要手动搜索兜底当主路径）。
///
/// 本文件只做**纯编排**：来源被抽象成「名字 + 语言 + 一个搜索函数」，Mihon /
/// Aidoku 的真实调用由页面适配后注入——编排逻辑因此可以用假来源做单元测试，
/// 与 `MangaGlobalSearchPage` 的每源独立、限并发扇出同一套纪律。
library;

import 'dart:collection';

import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/manga/discovery/manga_title_matcher.dart';

/// 匹配分低于此值的结果直接丢弃：三指标加权下 0.55 以下基本是同题材蹭词。
const double kMangaSourceMatchMinScore = 0.55;

/// 一个可参与匹配的来源：页面把 Mihon 在线源 / Aidoku 包适配成这个形状。
class MangaMatchSource {
  const MangaMatchSource({
    required this.id,
    required this.name,
    required this.language,
    required this.search,
  });

  final String id;
  final String name;

  /// 来源语言码（决定先用哪个标题去搜：日文源先原文，其余先英文/罗马字）。
  final String language;

  /// 按关键词搜索本来源，返回候选命中。抛错由编排层兜住，只影响本来源。
  final Future<List<MangaMatchHit>> Function(String query) search;
}

/// 来源搜索出的一条候选：标题参与打分，[payload] 原样带回给页面打开详情。
class MangaMatchHit {
  const MangaMatchHit({required this.title, required this.payload});

  final String title;
  final Object payload;
}

/// 一条匹配结果：某来源里分数最高的候选。
class MangaSourceMatch {
  const MangaSourceMatch({
    required this.source,
    required this.hit,
    required this.score,
  });

  final MangaMatchSource source;
  final MangaMatchHit hit;
  final double score;
}

/// 对 [entry] 在 [sources] 里做全自动匹配。
///
/// 每个来源：按语言挑标题顺序逐个查询，第一个有结果的查询即定（不叠加多查询
/// 的结果——同源多查询近乎重复，徒增请求）；候选按 [mangaTitleMatchScore] 对
/// 全部标题打分，留下该来源最高分且 ≥ [minScore] 的一条。来源间限并发扇出，
/// 单源失败静默跳过（发现页匹配是尽力而为，不是必达）。
Future<List<MangaSourceMatch>> matchMangaAcrossSources({
  required MangaDiscoveryEntry entry,
  required List<MangaMatchSource> sources,
  int maxConcurrent = 4,
  double minScore = kMangaSourceMatchMinScore,
}) async {
  final List<String> targets = entry.allTitles;
  if (targets.isEmpty || sources.isEmpty) return const <MangaSourceMatch>[];
  final List<MangaSourceMatch?> results =
      List<MangaSourceMatch?>.filled(sources.length, null);
  final Queue<int> pending =
      Queue<int>.of(List<int>.generate(sources.length, (int i) => i));
  Future<void> worker() async {
    while (pending.isNotEmpty) {
      final int index = pending.removeFirst();
      results[index] = await _matchOne(
        entry,
        sources[index],
        targets,
        minScore,
      );
    }
  }

  final int workers =
      maxConcurrent < sources.length ? maxConcurrent : sources.length;
  await Future.wait<void>(
    <Future<void>>[for (int i = 0; i < workers; i++) worker()],
  );
  final List<MangaSourceMatch> matches = results
      .whereType<MangaSourceMatch>()
      .toList()
    ..sort(
      (MangaSourceMatch a, MangaSourceMatch b) => b.score.compareTo(a.score),
    );
  return matches;
}

Future<MangaSourceMatch?> _matchOne(
  MangaDiscoveryEntry entry,
  MangaMatchSource source,
  List<String> targets,
  double minScore,
) async {
  for (final String query in mangaMatchQueriesFor(entry, source.language)) {
    final List<MangaMatchHit> hits;
    try {
      hits = await source.search(query);
    } on Object {
      // 单源失败（Cloudflare、超时、扩展崩溃）不拖累其余来源。
      return null;
    }
    if (hits.isEmpty) continue;
    MangaMatchHit? best;
    double bestScore = 0;
    for (final MangaMatchHit hit in hits) {
      final double score = mangaTitleMatchScore(hit.title, targets);
      if (score > bestScore) {
        bestScore = score;
        best = hit;
      }
    }
    if (best != null && bestScore >= minScore) {
      return MangaSourceMatch(source: source, hit: best, score: bestScore);
    }
    // 本查询有结果但都不像：换下一个标题继续，来源可能只认另一种写法。
  }
  return null;
}

/// 按来源语言排出的查询词序列（去重、去空）：日/中/韩来源先原文标题，
/// 其余来源先英文、再罗马字、最后原文。
List<String> mangaMatchQueriesFor(MangaDiscoveryEntry entry, String language) {
  final String lang = language.toLowerCase();
  final bool cjkFirst =
      lang.startsWith('ja') || lang.startsWith('zh') || lang.startsWith('ko');
  final List<String?> ordered = cjkFirst
      ? <String?>[entry.titleNative, entry.titleRomaji, entry.titleEnglish]
      : <String?>[entry.titleEnglish, entry.titleRomaji, entry.titleNative];
  final List<String> queries = <String>[];
  for (final String? title in ordered) {
    final String value = title?.trim() ?? '';
    if (value.isNotEmpty && !queries.contains(value)) queries.add(value);
  }
  return queries;
}
