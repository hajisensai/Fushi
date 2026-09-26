import 'package:flutter/foundation.dart';

/// LNReader 插件仓库索引里的一条（`plugins.min.json` 顶层数组的元素）。
///
/// 字段与上游 `PluginItem` 一一对应；`storeUrl` 是本地补的来源仓库地址。
@immutable
class LnReaderRepoPlugin {
  const LnReaderRepoPlugin({
    required this.id,
    required this.name,
    required this.site,
    required this.lang,
    required this.version,
    required this.url,
    required this.iconUrl,
    required this.storeUrl,
  });

  /// 解析一条索引项；缺关键字段（id / name / url / version）返回 null——仓库
  /// 里混进的坏条目不该拖垮整份目录。
  static LnReaderRepoPlugin? tryParse(Object? raw, {required String storeUrl}) {
    if (raw is! Map) return null;
    String field(String key) => (raw[key] ?? '').toString().trim();
    final String id = field('id');
    final String name = field('name');
    final String url = field('url');
    final String version = field('version');
    if (id.isEmpty || name.isEmpty || url.isEmpty || version.isEmpty) {
      return null;
    }
    return LnReaderRepoPlugin(
      id: id,
      name: name,
      site: field('site'),
      lang: field('lang'),
      version: version,
      url: url,
      iconUrl: _resolveAgainstStore(field('iconUrl'), storeUrl),
      storeUrl: storeUrl,
    );
  }

  /// 自建仓库的索引常写相对图标路径（相对索引文件）；原样交给图片组件只会是
  /// 一个解析不了的地址，扩展列表整列占位图标。与 Mihon 仓库索引同口径。
  static String _resolveAgainstStore(String value, String storeUrl) {
    if (value.isEmpty) return value;
    final Uri? parsed = Uri.tryParse(value);
    if (parsed == null || parsed.hasScheme) return value;
    final Uri? base = Uri.tryParse(storeUrl);
    if (base == null || !base.hasScheme) return value;
    return base.resolveUri(parsed).toString();
  }

  final String id;
  final String name;
  final String site;

  /// 语言的本地名（`日本語` / `English` / `中文, 汉语, 漢語`），不是语言码。
  final String lang;
  final String version;

  /// 插件 JS 的下载地址。
  final String url;
  final String iconUrl;
  final String storeUrl;
}

/// 已安装的插件：索引元数据 + 本地启停 / 排序 / 置顶状态。JS 源码在磁盘另存。
@immutable
class LnReaderInstalledPlugin {
  const LnReaderInstalledPlugin({
    required this.id,
    required this.name,
    required this.site,
    required this.lang,
    required this.version,
    required this.url,
    required this.iconUrl,
    required this.storeUrl,
    required this.enabled,
    required this.pinned,
    required this.sortOrder,
    required this.installedAt,
  });

  factory LnReaderInstalledPlugin.fromRepo(
    LnReaderRepoPlugin plugin, {
    required int sortOrder,
    required int installedAt,
  }) => LnReaderInstalledPlugin(
    id: plugin.id,
    name: plugin.name,
    site: plugin.site,
    lang: plugin.lang,
    version: plugin.version,
    url: plugin.url,
    iconUrl: plugin.iconUrl,
    storeUrl: plugin.storeUrl,
    enabled: true,
    pinned: false,
    sortOrder: sortOrder,
    installedAt: installedAt,
  );

  static LnReaderInstalledPlugin? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final String id = (raw['id'] ?? '').toString();
    if (id.isEmpty) return null;
    String field(String key) => (raw[key] ?? '').toString();
    int number(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return LnReaderInstalledPlugin(
      id: id,
      name: field('name'),
      site: field('site'),
      lang: field('lang'),
      version: field('version'),
      url: field('url'),
      iconUrl: field('iconUrl'),
      storeUrl: field('storeUrl'),
      enabled: raw['enabled'] != false,
      pinned: raw['pinned'] == true,
      sortOrder: number('sortOrder'),
      installedAt: number('installedAt'),
    );
  }

  final String id;
  final String name;
  final String site;
  final String lang;
  final String version;
  final String url;
  final String iconUrl;
  final String storeUrl;
  final bool enabled;
  final bool pinned;
  final int sortOrder;
  final int installedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'site': site,
    'lang': lang,
    'version': version,
    'url': url,
    'iconUrl': iconUrl,
    'storeUrl': storeUrl,
    'enabled': enabled,
    'pinned': pinned,
    'sortOrder': sortOrder,
    'installedAt': installedAt,
  };

  LnReaderInstalledPlugin copyWith({
    LnReaderRepoPlugin? metadata,
    bool? enabled,
    bool? pinned,
    int? sortOrder,
  }) => LnReaderInstalledPlugin(
    id: id,
    name: metadata?.name ?? name,
    site: metadata?.site ?? site,
    lang: metadata?.lang ?? lang,
    version: metadata?.version ?? version,
    url: metadata?.url ?? url,
    iconUrl: metadata?.iconUrl ?? iconUrl,
    storeUrl: metadata?.storeUrl ?? storeUrl,
    enabled: enabled ?? this.enabled,
    pinned: pinned ?? this.pinned,
    sortOrder: sortOrder ?? this.sortOrder,
    installedAt: installedAt,
  );
}

/// 一个插件仓库（索引地址）。
@immutable
class LnReaderStore {
  const LnReaderStore({
    required this.indexUrl,
    required this.name,
    this.lastError,
  });

  static LnReaderStore? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final String url = (raw['indexUrl'] ?? '').toString();
    if (url.isEmpty) return null;
    return LnReaderStore(indexUrl: url, name: (raw['name'] ?? '').toString());
  }

  final String indexUrl;
  final String name;

  /// 最近一次刷新的错误；只在内存里，不落盘。
  final String? lastError;

  Map<String, Object?> toJson() => <String, Object?>{
    'indexUrl': indexUrl,
    'name': name,
  };

  LnReaderStore withError(String? error) =>
      LnReaderStore(indexUrl: indexUrl, name: name, lastError: error);
}

/// 仓库地址的可读名：`raw.githubusercontent.com/<user>/<repo>/…` 取 `user/repo`，
/// 其它取主机名。
String lnReaderStoreDisplayName(String indexUrl) {
  final Uri? uri = Uri.tryParse(indexUrl);
  if (uri == null || uri.host.isEmpty) return indexUrl;
  final List<String> segments = uri.pathSegments
      .where((String segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (uri.host == 'raw.githubusercontent.com' && segments.length >= 2) {
    return '${segments[0]}/${segments[1]}';
  }
  return uri.host;
}

/// 浏览网格里的一条作品。
@immutable
class LnReaderNovelItem {
  const LnReaderNovelItem({required this.name, required this.path, this.cover});

  factory LnReaderNovelItem.fromJson(Map<Object?, Object?> json) =>
      LnReaderNovelItem(
        name: (json['name'] ?? '').toString(),
        path: (json['path'] ?? '').toString(),
        cover: _optionalString(json['cover']),
      );

  final String name;

  /// 插件内的相对路径（身份键）；网页地址要经插件 `resolveUrl`。
  final String path;
  final String? cover;
}

/// 章节条目。
@immutable
class LnReaderChapter {
  const LnReaderChapter({
    required this.name,
    required this.path,
    this.chapterNumber,
    this.releaseTime,
    this.page,
  });

  factory LnReaderChapter.fromJson(Map<Object?, Object?> json) =>
      LnReaderChapter(
        name: (json['name'] ?? '').toString(),
        path: (json['path'] ?? '').toString(),
        chapterNumber: (json['chapterNumber'] as num?)?.toDouble(),
        releaseTime: _optionalString(json['releaseTime']),
        page: _optionalString(json['page']),
      );

  final String name;
  final String path;
  final double? chapterNumber;
  final String? releaseTime;
  final String? page;
}

/// 作品详情（`parseNovel` 的结果，章节已按分页补齐）。
@immutable
class LnReaderNovel {
  const LnReaderNovel({
    required this.name,
    required this.path,
    required this.chapters,
    required this.totalPages,
    this.cover,
    this.genres,
    this.summary,
    this.author,
    this.artist,
    this.status,
  });

  factory LnReaderNovel.fromJson(Map<Object?, Object?> json) => LnReaderNovel(
    name: (json['name'] ?? '').toString(),
    path: (json['path'] ?? '').toString(),
    cover: _optionalString(json['cover']),
    genres: _optionalString(json['genres']),
    summary: _optionalString(json['summary']),
    author: _optionalString(json['author']),
    artist: _optionalString(json['artist']),
    status: _optionalString(json['status']),
    chapters: _chapterList(json['chapters']),
    totalPages: (json['totalPages'] as num?)?.toInt() ?? 1,
  );

  final String name;
  final String path;
  final String? cover;

  /// 逗号分隔的类型标签。
  final String? genres;

  /// 简介；部分插件给的是 HTML 片段。
  final String? summary;
  final String? author;
  final String? artist;
  final String? status;
  final List<LnReaderChapter> chapters;
  final int totalPages;

  LnReaderNovel withChapters(List<LnReaderChapter> chapters) => LnReaderNovel(
    name: name,
    path: path,
    cover: cover,
    genres: genres,
    summary: summary,
    author: author,
    artist: artist,
    status: status,
    chapters: chapters,
    totalPages: totalPages,
  );
}

List<LnReaderChapter> _chapterList(Object? raw) => raw is List
    ? <LnReaderChapter>[
        for (final Object? entry in raw)
          if (entry is Map) LnReaderChapter.fromJson(entry),
      ]
    : const <LnReaderChapter>[];

/// 分页目录合并：保序、按 path 去重（parseNovel 的首页与 parsePage(1) 常重叠）。
List<LnReaderChapter> mergeLnReaderChapterPages(
  Iterable<List<LnReaderChapter>> pages,
) {
  final Set<String> seen = <String>{};
  return <LnReaderChapter>[
    for (final List<LnReaderChapter> page in pages)
      for (final LnReaderChapter chapter in page)
        if (seen.add(chapter.path)) chapter,
  ];
}

/// 插件筛选器的种类（`@libs/filterInputs` 的 `FilterTypes` 取值）。
enum LnReaderFilterType {
  text('Text'),
  picker('Picker'),
  checkbox('Checkbox'),
  toggle('Switch'),
  excludableCheckbox('XCheckbox');

  const LnReaderFilterType(this.wireValue);

  final String wireValue;

  static LnReaderFilterType? fromWire(Object? value) {
    for (final LnReaderFilterType type in values) {
      if (type.wireValue == value) return type;
    }
    return null;
  }
}

@immutable
class LnReaderFilterOption {
  const LnReaderFilterOption({required this.label, required this.value});

  final String label;
  final String value;
}

/// 一个筛选器的定义 + 当前值。
///
/// 当前值的形状随种类：text / picker → `String`，toggle → `bool`，checkbox →
/// `List<String>`，excludableCheckbox → `{include: [...], exclude: [...]}`。
@immutable
class LnReaderFilter {
  const LnReaderFilter({
    required this.key,
    required this.label,
    required this.type,
    required this.value,
    this.options = const <LnReaderFilterOption>[],
  });

  /// 解析插件的 `filters` 对象；认不出的种类整条跳过（传给插件时它会用自己的
  /// 默认值，宿主侧 `popular` 已补齐）。
  static List<LnReaderFilter> parseAll(Object? raw) {
    if (raw is! Map) return const <LnReaderFilter>[];
    final List<LnReaderFilter> out = <LnReaderFilter>[];
    for (final MapEntry<Object?, Object?> entry in raw.entries) {
      final Object? definition = entry.value;
      if (definition is! Map) continue;
      final LnReaderFilterType? type = LnReaderFilterType.fromWire(
        definition['type'],
      );
      if (type == null) continue;
      final List<LnReaderFilterOption> options = <LnReaderFilterOption>[
        if (definition['options'] is List)
          for (final Object? option in definition['options'] as List)
            if (option is Map)
              LnReaderFilterOption(
                label: (option['label'] ?? '').toString(),
                value: (option['value'] ?? '').toString(),
              ),
      ];
      out.add(
        LnReaderFilter(
          key: entry.key.toString(),
          label: (definition['label'] ?? entry.key).toString(),
          type: type,
          value: _normaliseFilterValue(type, definition['value']),
          options: options,
        ),
      );
    }
    return out;
  }

  final String key;
  final String label;
  final LnReaderFilterType type;
  final Object value;
  final List<LnReaderFilterOption> options;

  LnReaderFilter withValue(Object value) => LnReaderFilter(
    key: key,
    label: label,
    type: type,
    value: _normaliseFilterValue(type, value),
    options: options,
  );
}

Object _normaliseFilterValue(LnReaderFilterType type, Object? value) {
  List<String> strings(Object? raw) => raw is List
      ? <String>[for (final Object? item in raw) item.toString()]
      : const <String>[];
  return switch (type) {
    LnReaderFilterType.text ||
    LnReaderFilterType.picker => (value ?? '').toString(),
    LnReaderFilterType.toggle => value == true,
    LnReaderFilterType.checkbox => strings(value),
    LnReaderFilterType.excludableCheckbox => <String, List<String>>{
      'include': strings(value is Map ? value['include'] : null),
      'exclude': strings(value is Map ? value['exclude'] : null),
    },
  };
}

/// 传给插件 `popularNovels` 的形态：`{key: {type, value}}`，不带 label / options。
Map<String, Object?> lnReaderFilterValues(List<LnReaderFilter> filters) =>
    <String, Object?>{
      for (final LnReaderFilter filter in filters)
        filter.key: <String, Object?>{
          'type': filter.type.wireValue,
          'value': filter.value,
        },
    };

/// 插件装载后自报的元数据（宿主 `describe`）。
@immutable
class LnReaderPluginInfo {
  const LnReaderPluginInfo({
    required this.id,
    required this.name,
    required this.site,
    required this.version,
    required this.filters,
    required this.imageHeaders,
    required this.hasParsePage,
  });

  factory LnReaderPluginInfo.fromJson(Map<Object?, Object?> json) =>
      LnReaderPluginInfo(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        site: (json['site'] ?? '').toString(),
        version: (json['version'] ?? '').toString(),
        filters: LnReaderFilter.parseAll(json['filters']),
        imageHeaders: <String, String>{
          if (json['imageHeaders'] is Map)
            for (final MapEntry<Object?, Object?> entry
                in (json['imageHeaders'] as Map).entries)
              entry.key.toString(): entry.value.toString(),
        },
        hasParsePage: json['hasParsePage'] == true,
      );

  final String id;
  final String name;
  final String site;
  final String version;
  final List<LnReaderFilter> filters;

  /// 封面请求需要的头（Referer 等），来自插件的 `imageRequestInit`。
  final Map<String, String> imageHeaders;
  final bool hasParsePage;
}

/// 章节 HTML 规整后的 XHTML 片段与其引用的图片。
@immutable
class LnReaderXhtml {
  const LnReaderXhtml({required this.xhtml, required this.images});

  factory LnReaderXhtml.fromJson(Map<Object?, Object?> json) => LnReaderXhtml(
    xhtml: (json['xhtml'] ?? '').toString(),
    images: <({String url, String fileName})>[
      if (json['images'] is List)
        for (final Object? image in json['images'] as List)
          if (image is Map)
            (
              url: (image['url'] ?? '').toString(),
              fileName: (image['fileName'] ?? '').toString(),
            ),
    ],
  );

  final String xhtml;
  final List<({String url, String fileName})> images;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  final String text = value.toString().trim();
  return text.isEmpty ? null : text;
}

/// 插件语言本地名 → BCP 47 主标签（EPUB `dc:language` / `xml:lang` 用）。
/// 认不出的给 `und`，不瞎猜。
String lnReaderLanguageTag(String lang) {
  final String value = lang.toLowerCase();
  const List<(String, String)> table = <(String, String)>[
    ('日本語', 'ja'),
    ('japanese', 'ja'),
    ('english', 'en'),
    ('中文', 'zh'),
    ('汉语', 'zh'),
    ('漢語', 'zh'),
    ('chinese', 'zh'),
    ('한국어', 'ko'),
    ('korean', 'ko'),
    ('español', 'es'),
    ('português', 'pt'),
    ('français', 'fr'),
    ('deutsch', 'de'),
    ('русский', 'ru'),
    ('bahasa indonesia', 'id'),
    ('tiếng việt', 'vi'),
    ('ไทย', 'th'),
    ('العربية', 'ar'),
    ('türkçe', 'tr'),
    ('italiano', 'it'),
    ('polski', 'pl'),
    ('українська', 'uk'),
  ];
  for (final (String needle, String tag) in table) {
    if (value.contains(needle)) return tag;
  }
  return 'und';
}
