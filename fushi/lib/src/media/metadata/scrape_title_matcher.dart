import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// 批量刮削只自动采用“每个源内唯一的精确标题”。
///
/// 手动弹窗可以让用户亲自判断近似标题；一键处理整库没有这个人工确认点，因此宁可
/// 把近似结果留为待确认，也不能因为“搜索结果第一条”就覆盖整库封面。
///
/// 唯一性按源判：[sourceOf] 给出候选所属的源。同一个源里出现两条精确同名，说明
/// 那个源本身收录了不同作品同名（真歧义），返回 null 留给单卡确认；不同源各有一条
/// 精确同名，指的是同一部作品在多个数据库里的条目（例如 Bangumi 与 VNDB 都收录了
/// 《ATRI -My Dear Moments-》），不是歧义——此时取 [candidates] 中最先出现的那个
/// 源的唯一命中（调用方用候选顺序表达源优先级）。
T? uniqueExactScrapeTitleMatch<T>({
  required String query,
  required List<T> candidates,
  required Iterable<String> Function(T candidate) titles,
  required Object Function(T candidate) sourceOf,
}) {
  final String normalizedQuery = TitleNormalizer.normalize(query);
  if (normalizedQuery.isEmpty) return null;
  // 源 → 该源的精确命中；LinkedHashMap 保住源首次出现的顺序（即优先级）。
  final Map<Object, List<T>> exactBySource = <Object, List<T>>{};
  for (final T candidate in candidates) {
    final bool exact = titles(candidate).any(
      (String title) => TitleNormalizer.normalize(title) == normalizedQuery,
    );
    if (!exact) continue;
    exactBySource.putIfAbsent(sourceOf(candidate), () => <T>[]).add(candidate);
  }
  for (final List<T> matches in exactBySource.values) {
    if (matches.length > 1) return null;
  }
  if (exactBySource.isEmpty) return null;
  return exactBySource.values.first.single;
}
