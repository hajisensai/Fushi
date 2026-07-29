import 'package:hibiki/src/media/video/scraper/title_normalizer.dart';

/// 批量刮削只自动采用“唯一精确标题”。
///
/// 手动弹窗可以让用户亲自判断近似标题；一键处理整库没有这个人工确认点，因此宁可
/// 把近似结果留为待确认，也不能因为“搜索结果第一条”就覆盖整库封面。
T? uniqueExactScrapeTitleMatch<T>({
  required String query,
  required List<T> candidates,
  required Iterable<String> Function(T candidate) titles,
}) {
  final String normalizedQuery = TitleNormalizer.normalize(query);
  if (normalizedQuery.isEmpty) return null;
  T? match;
  for (final T candidate in candidates) {
    final bool exact = titles(candidate).any(
      (String title) => TitleNormalizer.normalize(title) == normalizedQuery,
    );
    if (!exact) continue;
    if (match != null) return null;
    match = candidate;
  }
  return match;
}
