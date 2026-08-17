/// 漫画发现页的数据模型：AniList 元数据条目 + 按 feed 分组的快照。
///
/// 发现页条目是**元数据**（AniList），不是任何在线来源的条目——「能读」要经
/// `manga_source_matcher.dart` 在已启用来源里按标题匹配后才成立。这一层不持有
/// 任何来源引用，保持纯数据。
library;

/// 发现页的四条内容行。顺序即页面展示顺序。
enum MangaDiscoveryFeed {
  /// 趋势（TRENDING_DESC）。
  trending,

  /// 热门（POPULARITY_DESC）。
  popular,

  /// 高分（SCORE_DESC，带人气下限过滤冷门条目）。
  topRated,

  /// 最新完结（FINISHED + END_DATE_DESC，带评分/人气下限）。
  latestFinished,
}

/// 一条 AniList 漫画条目。字段与发现页/详情页展示需要一一对应，不多带。
class MangaDiscoveryEntry {
  const MangaDiscoveryEntry({
    required this.anilistId,
    this.titleNative,
    this.titleRomaji,
    this.titleEnglish,
    this.synonyms = const <String>[],
    this.coverUrl,
    this.averageScore,
    this.description,
    this.genres = const <String>[],
    this.status,
    this.chapters,
    this.countryOfOrigin,
  });

  final int anilistId;
  final String? titleNative;
  final String? titleRomaji;
  final String? titleEnglish;
  final List<String> synonyms;
  final String? coverUrl;

  /// 0–10 分（AniList 原始是 0–100，provider 已除以 10）。
  final double? averageScore;
  final String? description;
  final List<String> genres;

  /// AniList 原始状态串（`RELEASING` / `FINISHED` / …），展示层自行映射文案。
  final String? status;
  final int? chapters;
  final String? countryOfOrigin;

  /// 展示用首选标题：原文优先（本应用面向原文阅读者），罗马字、英文兜底。
  String get preferredTitle =>
      _firstNonEmpty(<String?>[titleNative, titleRomaji, titleEnglish]) ??
      '#$anilistId';

  /// 参与来源匹配的全部标题（去重、去空）。
  List<String> get allTitles {
    final List<String> titles = <String>[];
    for (final String? title in <String?>[
      titleNative,
      titleRomaji,
      titleEnglish,
      ...synonyms,
    ]) {
      final String? value = _normalizeOrNull(title);
      if (value != null && !titles.contains(value)) titles.add(value);
    }
    return titles;
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final String? value in values) {
      final String? result = _normalizeOrNull(value);
      if (result != null) return result;
    }
    return null;
  }

  static String? _normalizeOrNull(String? value) {
    final String trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// 发现数据源接口：页面依赖它而不是具体实现，测试注入假快照。
abstract interface class MangaDiscoveryProvider {
  Future<MangaDiscoverySnapshot> fetchSnapshot({int perPage});

  void close();
}

/// 一次发现页抓取的完整结果：四条 feed 各自的条目列表。
class MangaDiscoverySnapshot {
  const MangaDiscoverySnapshot({required this.feeds});

  final Map<MangaDiscoveryFeed, List<MangaDiscoveryEntry>> feeds;

  List<MangaDiscoveryEntry> operator [](MangaDiscoveryFeed feed) =>
      feeds[feed] ?? const <MangaDiscoveryEntry>[];

  bool get isEmpty =>
      feeds.values.every((List<MangaDiscoveryEntry> list) => list.isEmpty);
}
