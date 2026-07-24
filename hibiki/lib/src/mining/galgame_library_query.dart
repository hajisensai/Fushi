/// 游戏库页的**纯函数**查询层：搜索归一化、排序比较器、筛选与视图偏好编解码。
///
/// 契约 §4.1。这里刻意不引任何新依赖（不做 fuzzy / 拼音，M1 只要归一化子串匹配），
/// 也不碰磁盘、时钟与 DB——整个文件输入一样输出必然一样，可直接单测。
library;

import 'dart:convert';

import 'package:hibiki/src/mining/galgame_library.dart';

/// 排序维度（契约 §4.1）。[key] 是持久化字符串，**不可随意改**。
enum GalgameSortField {
  /// 添加时间。
  added('added'),

  /// 发行日。
  releaseDate('release'),

  /// 最后游玩。
  lastPlayed('lastPlayed'),

  /// 站点评分。
  siteScore('siteScore'),

  /// 我的评分。
  userRating('userRating'),

  /// 名称。
  name('name');

  const GalgameSortField(this.key);

  final String key;

  static GalgameSortField fromKey(Object? key) {
    for (final GalgameSortField field in GalgameSortField.values) {
      if (field.key == key) return field;
    }
    return GalgameSortField.added;
  }
}

/// 本地 / 在线筛选（契约 §4.1「本地·在线」）。
enum GalgameLocalFilter {
  /// 不筛。
  all('all'),

  /// 只看有本地 exe 的。
  localOnly('local'),

  /// 只看没有本地 exe（纯元数据条目）的。
  metadataOnly('metadata');

  const GalgameLocalFilter(this.key);

  final String key;

  static GalgameLocalFilter fromKey(Object? key) {
    for (final GalgameLocalFilter f in GalgameLocalFilter.values) {
      if (f.key == key) return f;
    }
    return GalgameLocalFilter.all;
  }
}

/// 游戏库页的视图状态：搜索词 + 排序 + 筛选。
///
/// 除 [search] 之外全部持久化（[encode] / [decode] 落一个偏好 key）。搜索词刻意
/// 不持久化——下次进页面还挂着上次的搜索词只会让人以为库空了。
class GalgameLibraryView {
  const GalgameLibraryView({
    this.search = '',
    this.sortField = GalgameSortField.added,
    this.ascending = true,
    this.status,
    this.localFilter = GalgameLocalFilter.all,
    this.tags = const <String>{},
    this.hideNsfw = false,
  });

  /// 搜索词（原文，匹配时才归一化）。
  final String search;

  final GalgameSortField sortField;

  /// 升序？默认 true：旧版库页就是按添加时间升序排（Never break userspace）。
  final bool ascending;

  /// 游玩状态筛选；null = 全部。
  final GalgamePlayStatus? status;

  final GalgameLocalFilter localFilter;

  /// 标签多选（AND 语义：必须含全部选中标签）。
  final Set<String> tags;

  /// 隐藏成人向条目。
  final bool hideNsfw;

  /// 是否有任何筛选条件生效（UI 据此给筛选入口加高亮/清除按钮）。
  bool get hasActiveFilter =>
      status != null ||
      localFilter != GalgameLocalFilter.all ||
      tags.isNotEmpty ||
      hideNsfw;

  GalgameLibraryView copyWith({
    String? search,
    GalgameSortField? sortField,
    bool? ascending,
    GalgamePlayStatus? status,
    bool clearStatus = false,
    GalgameLocalFilter? localFilter,
    Set<String>? tags,
    bool? hideNsfw,
  }) {
    return GalgameLibraryView(
      search: search ?? this.search,
      sortField: sortField ?? this.sortField,
      ascending: ascending ?? this.ascending,
      status: clearStatus ? null : (status ?? this.status),
      localFilter: localFilter ?? this.localFilter,
      tags: tags ?? this.tags,
      hideNsfw: hideNsfw ?? this.hideNsfw,
    );
  }

  /// 清掉全部筛选（保留排序，搜索由 UI 自己清）。
  GalgameLibraryView clearFilters() => GalgameLibraryView(
        search: search,
        sortField: sortField,
        ascending: ascending,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'sort': sortField.key,
        'asc': ascending,
        if (status != null) 'status': status!.value,
        'local': localFilter.key,
        if (tags.isNotEmpty) 'tags': tags.toList(growable: false),
        if (hideNsfw) 'hideNsfw': true,
      };

  String encode() => jsonEncode(toJson());

  /// 容错解析持久化字符串；空串 / 非法 JSON / 非对象 → 默认视图（不抛）。
  static GalgameLibraryView decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const GalgameLibraryView();
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const GalgameLibraryView();
      }
      final Object? status = decoded['status'];
      final Object? tags = decoded['tags'];
      return GalgameLibraryView(
        sortField: GalgameSortField.fromKey(decoded['sort']),
        ascending: decoded['asc'] is bool ? decoded['asc'] as bool : true,
        status: status is int ? GalgamePlayStatus.fromValue(status) : null,
        localFilter: GalgameLocalFilter.fromKey(decoded['local']),
        tags: <String>{
          if (tags is List)
            for (final Object? tag in tags)
              if (tag is String && tag.isNotEmpty) tag,
        },
        hideNsfw: decoded['hideNsfw'] == true,
      );
    } catch (_) {
      return const GalgameLibraryView();
    }
  }
}

/// 搜索归一化：全角 ASCII → 半角、大写 → 小写、片假名 → 平假名、丢掉空白与常见
/// 标点。目的是让「Fate／stay night」「fate stay night」「ＦＡＴＥ・ｓｔａｙ」
/// 互相能命中，而不引入任何模糊匹配依赖。
///
/// 片假名折叠只做基本区（U+30A1..U+30F6 平移 -0x60），长音符 `ー`、中点 `・`
/// 这类连接符直接丢弃——它们在标题里出现与否全凭排版习惯。
String normalizeGalgameSearchText(String raw) {
  if (raw.isEmpty) return '';
  final StringBuffer out = StringBuffer();
  for (final int code in raw.runes) {
    int c = code;
    // 全角 ASCII（U+FF01..U+FF5E）→ 半角。
    if (c >= 0xFF01 && c <= 0xFF5E) {
      c -= 0xFEE0;
    }
    // 全角空格 → 视作空白（下面被丢弃）。
    if (c == 0x3000) {
      continue;
    }
    // 片假名 → 平假名（基本区）。
    if (c >= 0x30A1 && c <= 0x30F6) {
      c -= 0x60;
    }
    final String ch = String.fromCharCode(c);
    if (_isDroppedSearchChar(ch, c)) {
      continue;
    }
    out.write(ch.toLowerCase());
  }
  return out.toString();
}

/// 归一化时丢弃的字符：空白 + 常见分隔/装饰标点（含日文全角标点）。
bool _isDroppedSearchChar(String ch, int code) {
  if (code <= 0x20) return true; // 控制字符与空格
  return _kDroppedSearchChars.contains(ch);
}

/// 见 [_isDroppedSearchChar]。

const Set<String> _kDroppedSearchChars = <String>{
  '!',
  '"',
  '#',
  '\$',
  '%',
  '&',
  "'",
  '(',
  ')',
  '*',
  '+',
  ',',
  '-',
  '.',
  '/',
  ':',
  ';',
  '<',
  '=',
  '>',
  '?',
  '@',
  '[',
  '\\',
  ']',
  '^',
  '_',
  '`',
  '{',
  '|',
  '}',
  '~',
  '・',
  'ー',
  '、',
  '。',
  '「',
  '」',
  '『',
  '』',
  '〜',
  '＝',
  '−',
  '–',
  '—',
  '“',
  '”',
  '‘',
  '’',
  '…',
};

/// 某条游戏是否命中搜索词：对 [GalgameEntry.searchTitles] 全部标题做归一化子串匹配。
/// 空查询恒命中。纯函数。
bool matchesGalgameSearch(GalgameEntry entry, String query) {
  final String needle = normalizeGalgameSearchText(query);
  if (needle.isEmpty) return true;
  for (final String title in entry.searchTitles) {
    if (normalizeGalgameSearchText(title).contains(needle)) {
      return true;
    }
  }
  return false;
}

/// 某条游戏是否通过筛选（不含搜索）。纯函数。
bool matchesGalgameFilters(GalgameEntry entry, GalgameLibraryView view) {
  if (view.status != null && entry.playStatus != view.status) {
    return false;
  }
  switch (view.localFilter) {
    case GalgameLocalFilter.all:
      break;
    case GalgameLocalFilter.localOnly:
      if (!entry.hasLocalExe) return false;
    case GalgameLocalFilter.metadataOnly:
      if (entry.hasLocalExe) return false;
  }
  if (view.hideNsfw && entry.isNsfw) {
    return false;
  }
  if (view.tags.isNotEmpty) {
    final Set<String> owned = entry.tags.toSet();
    for (final String tag in view.tags) {
      if (!owned.contains(tag)) return false;
    }
  }
  return true;
}

/// 排序比较器（纯函数）。
///
/// **缺值恒排在最后**（无论升降序）：发行日未知 / 从未游玩 / 未评分的条目沉底才符合
/// 直觉，若跟着方向翻转，降序时满屏都是空值。缺值之间与完全相等时按显示名 → id
/// 兜底，保证结果确定（Dart 的 [List.sort] 不保证稳定）。
int compareGalgameEntries(
  GalgameEntry a,
  GalgameEntry b, {
  required GalgameSortField field,
  required bool ascending,
}) {
  final int dir = ascending ? 1 : -1;
  int tie() => _compareTitleThenId(a, b);
  switch (field) {
    case GalgameSortField.added:
      final int c = a.addedAt.compareTo(b.addedAt);
      return c == 0 ? tie() : dir * c;
    case GalgameSortField.name:
      return dir * tie();
    case GalgameSortField.releaseDate:
      // 'YYYY-MM-DD' 的字典序即时间序。
      return _compareNullable<String>(
          a.effectiveReleaseDate, b.effectiveReleaseDate, dir, tie);
    case GalgameSortField.lastPlayed:
      return _compareNullable<int>(
        a.lastPlayedMs == 0 ? null : a.lastPlayedMs,
        b.lastPlayedMs == 0 ? null : b.lastPlayedMs,
        dir,
        tie,
      );
    case GalgameSortField.siteScore:
      return _compareNullable<double>(a.siteScore, b.siteScore, dir, tie);
    case GalgameSortField.userRating:
      return _compareNullable<double>(a.userRating, b.userRating, dir, tie);
  }
}

int _compareNullable<T extends Comparable<Object>>(
  T? x,
  T? y,
  int dir,
  int Function() tie,
) {
  if (x == null && y == null) return tie();
  if (x == null) return 1; // 缺值沉底，不随方向翻转
  if (y == null) return -1;
  final int c = x.compareTo(y);
  return c == 0 ? tie() : dir * c;
}

int _compareTitleThenId(GalgameEntry a, GalgameEntry b) {
  final int c = normalizeGalgameSearchText(a.displayName)
      .compareTo(normalizeGalgameSearchText(b.displayName));
  return c == 0 ? a.id.compareTo(b.id) : c;
}

/// 筛选 + 搜索 + 排序，一步得到库页要渲染的列表。纯函数，不改入参。
List<GalgameEntry> applyGalgameLibraryView(
  List<GalgameEntry> games,
  GalgameLibraryView view,
) {
  final List<GalgameEntry> out = <GalgameEntry>[
    for (final GalgameEntry game in games)
      if (matchesGalgameFilters(game, view) &&
          matchesGalgameSearch(game, view.search))
        game,
  ];
  out.sort((GalgameEntry a, GalgameEntry b) => compareGalgameEntries(
        a,
        b,
        field: view.sortField,
        ascending: view.ascending,
      ));
  return out;
}

/// 全库标签池（去重 + 按归一化名排序），供筛选面板的标签多选。纯函数。
List<String> collectGalgameTags(List<GalgameEntry> games) {
  final Set<String> tags = <String>{
    for (final GalgameEntry game in games) ...game.tags,
  };
  final List<String> out = tags.toList()
    ..sort((String a, String b) =>
        normalizeGalgameSearchText(a).compareTo(normalizeGalgameSearchText(b)));
  return out;
}
