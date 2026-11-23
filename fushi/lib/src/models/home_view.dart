/// 首页视图（Home views，用户 2026-11-22 拍板）：保存的一条筛选，让首页的媒体组件
/// （继续 / 继续阅读 / 继续观看 / 继续游玩 / 最近添加）只显示某种语言或某个标签的作品。
///
/// 持久化（都随 Profile 走——普通偏好由 Profile 快照按配置隔离，见
/// `profile/profile_keys.dart`）：
/// - `home_views_enabled`：总开关，默认关。关着时首页与改造前逐字一致、不跑额外查询；
/// - `home_views`：保存的视图（JSON 数组，[encodeHomeViews] / [decodeHomeViews]）；
/// - `home_view_active`：本配置首页打开时用哪个视图（视图 id；'' / 指不到 = 全部）。
///   它同时就是「本配置的默认视图」：切配置换快照即换视图，换视图不动配置。
///
/// 本文件是纯模型 + 匹配器（无 Flutter / 数据库依赖），首页与设置页共用。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, setEquals;

import 'package:fushi/src/profile/language_binding.dart';

/// 内置的「全部」视图 id（不落盘，恒存在）。
const String kHomeViewEverythingId = '';

/// 一条保存的首页视图。
///
/// 语言部分（[languages] ∪ [includeNoLanguage]）与标签部分（[tags]）都非空时取
/// AND；两部分都空 = 不筛选（等同「全部」，编辑器不允许保存这种视图）。
@immutable
class HomeView {
  const HomeView({
    required this.id,
    this.name = '',
    this.languages = const <String>{},
    this.includeNoLanguage = false,
    this.tags = const <String>{},
    this.matchAllTags = false,
  });

  /// 稳定身份（[newHomeViewId] 生成），`home_view_active` 存的就是它。
  final String id;

  /// 用户起的名字；空 = 按筛选条件自动命名（[homeViewDisplayName]）。
  final String name;

  /// 归一化后的语言键（[normalizeLanguageBinding]：`ja-JP` → `ja`，保留文字子标签）。
  final Set<String> languages;

  /// 是否包含「没设语言」的作品（含远端 / 服务器条目，它们没有本地语言数据）。
  final bool includeNoLanguage;

  /// 标签名（`book_tags.name`）。存名字而不是本机自增 id：视图随 Profile 快照 /
  /// 备份同步到别的设备，标签在那边按名字同步（`tag_sync`），id 却各自不同。
  final Set<String> tags;

  /// 标签匹配方式：true = 全部标签都要有，false = 有任一即可。
  final bool matchAllTags;

  /// 语言部分是否参与筛选。
  bool get filtersLanguage => languages.isNotEmpty || includeNoLanguage;

  /// 标签部分是否参与筛选。
  bool get filtersTags => tags.isNotEmpty;

  /// 不筛选任何东西（等同「全部」）。
  bool get isEverything => !filtersLanguage && !filtersTags;

  HomeView copyWith({
    String? name,
    Set<String>? languages,
    bool? includeNoLanguage,
    Set<String>? tags,
    bool? matchAllTags,
  }) => HomeView(
    id: id,
    name: name ?? this.name,
    languages: languages ?? this.languages,
    includeNoLanguage: includeNoLanguage ?? this.includeNoLanguage,
    tags: tags ?? this.tags,
    matchAllTags: matchAllTags ?? this.matchAllTags,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'langs': (languages.toList()..sort()),
    'noLang': includeNoLanguage,
    'tags': (tags.toList()..sort()),
    'all': matchAllTags,
  };

  /// 宽容解码：字段缺失 / 类型不对按默认值，语言键重新归一化（丢掉认不出的）；
  /// 没有 id 的返回 null（无法被选中，丢弃）。
  static HomeView? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final Object? name = raw['name'];
    final Object? langs = raw['langs'];
    final Object? tags = raw['tags'];
    return HomeView(
      id: id,
      name: name is String ? name : '',
      languages: <String>{
        if (langs is List)
          for (final Object? l in langs)
            if (l is String)
              if (normalizeLanguageBinding(l) case final String key
                  when key.isNotEmpty)
                key,
      },
      includeNoLanguage: raw['noLang'] == true,
      tags: <String>{
        if (tags is List)
          for (final Object? t in tags)
            if (t is String && t.trim().isNotEmpty) t.trim(),
      },
      matchAllTags: raw['all'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeView &&
      other.id == id &&
      other.name == name &&
      setEquals(other.languages, languages) &&
      other.includeNoLanguage == includeNoLanguage &&
      setEquals(other.tags, tags) &&
      other.matchAllTags == matchAllTags;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    Object.hashAllUnordered(languages),
    includeNoLanguage,
    Object.hashAllUnordered(tags),
    matchAllTags,
  );

  /// 记忆键用的值签名（首页的列表记忆据此判断视图变没变）。
  String get signature => jsonEncode(toJson());
}

/// 新视图 id：微秒时间戳的 36 进制（同一设备上不会撞；跨设备只在同一 Profile 快照里用）。
String newHomeViewId([DateTime? now]) =>
    'v${(now ?? DateTime.now()).microsecondsSinceEpoch.toRadixString(36)}';

/// 解出偏好 `home_views`。空串 / 坏 JSON / 非数组 → 空表；逐条宽容解码，重复 id 只留第一条。
List<HomeView> decodeHomeViews(String raw) {
  if (raw.trim().isEmpty) return const <HomeView>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <HomeView>[];
  }
  if (decoded is! List) return const <HomeView>[];
  final Set<String> seen = <String>{};
  return <HomeView>[
    for (final Object? item in decoded)
      if (HomeView.fromJson(item) case final HomeView view
          when seen.add(view.id))
        view,
  ];
}

String encodeHomeViews(List<HomeView> views) =>
    jsonEncode(<Object?>[for (final HomeView v in views) v.toJson()]);

/// 首页此刻生效的视图：开关开着、且 [activeId] 指到一条保存的、真的在筛选的视图；
/// 否则 null（= 全部）。
HomeView? resolveActiveHomeView({
  required bool enabled,
  required List<HomeView> views,
  required String activeId,
}) {
  if (!enabled || activeId == kHomeViewEverythingId) return null;
  for (final HomeView v in views) {
    if (v.id == activeId) return v.isEverything ? null : v;
  }
  return null;
}

/// [entryLanguage]（原始 BCP-47，可空）是否落在 [viewLanguage]（已归一化）里：
/// 归一化后相等；或视图语言不带文字子标签而作品语言是它的某种文字（视图「中文」`zh`
/// 含 `zh-Hans` / `zh-Hant`，视图 `zh-Hant` 不含 `zh-Hans`）。
bool _languageIncludes(String viewLanguage, String entryKey) {
  if (viewLanguage == entryKey) return true;
  if (viewLanguage.contains('-')) return false;
  return entryKey.startsWith('$viewLanguage-');
}

/// 一条作品是否出现在 [view] 里。
///
/// [language] 是作品的原始语言列值（null / 空 / 认不出 = 没设语言）；[tags] 是作品
/// （含其所属合集）的标签名。
bool matchesHomeView(
  HomeView view, {
  String? language,
  Set<String> tags = const <String>{},
}) {
  if (view.filtersLanguage) {
    final String key = normalizeLanguageBinding(language);
    final bool ok = key.isEmpty
        ? view.includeNoLanguage
        : view.languages.any((String l) => _languageIncludes(l, key));
    if (!ok) return false;
  }
  if (view.filtersTags) {
    final bool ok = view.matchAllTags
        ? view.tags.every(tags.contains)
        : view.tags.any(tags.contains);
    if (!ok) return false;
  }
  return true;
}

/// 作品在视图匹配里的两项事实（语言 + 标签）。
typedef HomeViewSubject = ({String? language, Set<String> tags});

/// 首页列表按视图过滤。[view] 为 null（开关关着 / 选的是「全部」）时**原样返回
/// [entries] 本身**，不调用 [subjectOf]——关着时不需要任何查表。
List<T> filterForHomeView<T>(
  List<T> entries, {
  required HomeView? view,
  required HomeViewSubject Function(T entry) subjectOf,
}) {
  if (view == null || view.isEverything) return entries;
  return <T>[
    for (final T e in entries)
      if (subjectOf(e) case final HomeViewSubject s
          when matchesHomeView(view, language: s.language, tags: s.tags))
        e,
  ];
}

/// 视图的自动名：语言显示名（日本語 / 中文 / English）、「没设语言」、`#标签名`。
/// 语言之间、标签之间用 ` + ` 连接，语言部分与标签部分之间用 ` · `；都没有时是
/// [everythingLabel]。
String homeViewDefaultName(
  HomeView view, {
  required String Function(String language) languageLabel,
  required String noLanguageLabel,
  required String everythingLabel,
}) {
  final List<String> langs = <String>[
    for (final String l in view.languages.toList()..sort()) languageLabel(l),
    if (view.includeNoLanguage) noLanguageLabel,
  ];
  final List<String> tags = <String>[
    for (final String name in view.tags.toList()..sort()) '#$name',
  ];
  final List<String> parts = <String>[
    if (langs.isNotEmpty) langs.join(' + '),
    if (tags.isNotEmpty) tags.join(' + '),
  ];
  return parts.isEmpty ? everythingLabel : parts.join(' · ');
}

/// 视图的显示名：用户起的名字优先，否则自动名（参数同 [homeViewDefaultName]）。
String homeViewDisplayName(
  HomeView view, {
  required String Function(String language) languageLabel,
  required String noLanguageLabel,
  required String everythingLabel,
}) {
  final String custom = view.name.trim();
  if (custom.isNotEmpty) return custom;
  return homeViewDefaultName(
    view,
    languageLabel: languageLabel,
    noLanguageLabel: noLanguageLabel,
    everythingLabel: everythingLabel,
  );
}

/// 首页视图匹配要的批量事实，一轮首页载入查一次（[loadHomeViewLookup]），只在
/// 开关开着时才查。
///
/// - [languages]：书 / 字幕书的语言（键 `epub|<bookKey>` / `srt|<uid>`；视频与游戏
///   的语言在首页已载入的行上，不在这里）；
/// - [tags]：标签映射（键 `<TagAssignments.mediaKind>|<entryKey>` → 标签 id），
///   五种宿主一张表一条查询；
/// - [tagNames]：标签池 id → 名字（把作品的标签 id 换成名字再匹配视图）。
@immutable
class HomeViewLookup {
  const HomeViewLookup({
    this.languages = const <String, String>{},
    this.tags = const <String, Set<int>>{},
    this.tagNames = const <int, String>{},
  });

  static const HomeViewLookup empty = HomeViewLookup();

  final Map<String, String> languages;
  final Map<String, Set<int>> tags;

  /// 标签池 id → 名字。
  final Map<int, String> tagNames;

  /// `<kind>|<entryKey>` 的语言（没有 = null）。
  String? languageOf(String kind, String entryKey) =>
      languages['$kind|$entryKey'];

  /// `<kind>|<entryKey>` 的标签 id（没有 = 空集）。
  Set<int> tagsOf(String kind, String entryKey) =>
      tags['$kind|$entryKey'] ?? const <int>{};

  /// `<kind>|<entryKey>` 的标签名（视图按名字匹配，见 [HomeView.tags]）。
  Set<String> tagNamesOf(String kind, String entryKey) => <String>{
    for (final int id in tagsOf(kind, entryKey))
      if (tagNames[id] case final String name) name,
  };
}
