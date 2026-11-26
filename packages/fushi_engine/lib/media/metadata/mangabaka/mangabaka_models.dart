/// MangaBaka（`api.mangabaka.org`）系列 / 图片响应的纯解析层（无 IO）。
///
/// 只取书 / 漫画「每卷封面 + 横幅」刮削用得到的字段。形状来自真实响应（夹具在
/// `test/fixtures/mangabaka/`）：
/// - 搜索 `/v1/series/search`、图片 `/v1/series/{id}/images` 都是
///   `{status, pagination:{count,next,previous,page,limit}, data:[…]}`；
/// - 按 id 取 `/v1/series/{id}` 是 `{status, data:{…}}`；
/// - 图片的 `index` 是字符串（`"28.5"`、`"1.1"`），`index_numeric` 是数（可带小数），
///   同一 index 可有多张（各语言版 / 变体，变体在 `note` 里写明）；宽高在
///   `image.raw.width/height` 里，不必下载去量。
///
/// **图片 URL 原样使用**：API 已迁到 `api.mangabaka.org`，图片仍在
/// `images.mangabaka.dev` / `cdn.mangabaka.dev`，这里不改写域名。
library;

import 'dart:convert';

/// MangaBaka 响应解析失败（JSON 解不开 / 顶层形状不对）。
class MangaBakaFormatException implements Exception {
  const MangaBakaFormatException(this.message);

  final String message;

  @override
  String toString() => 'MangaBakaFormatException: $message';
}

/// 一张原图（`image.raw` / `cover.raw`）。
class MangaBakaRawImage {
  const MangaBakaRawImage({
    required this.url,
    this.width,
    this.height,
    this.format,
    this.size,
  });

  final String url;
  final int? width;
  final int? height;

  /// `jpeg` / `png` / `webp` …（源站给的格式名，小写）。
  final String? format;

  /// 字节数。
  final int? size;

  /// 像素面积；宽高缺失为 0。
  int get area => (width ?? 0) * (height ?? 0);

  static MangaBakaRawImage? fromJson(Object? json) {
    if (json is! Map) return null;
    final String? url = _string(json['url']);
    if (url == null) return null;
    return MangaBakaRawImage(
      url: url,
      width: _int(json['width']),
      height: _int(json['height']),
      format: _string(json['format'])?.toLowerCase(),
      size: _int(json['size']),
    );
  }
}

/// 一个 MangaBaka 系列（搜索结果 / 按 id 取）。
class MangaBakaSeries {
  const MangaBakaSeries({
    required this.id,
    required this.state,
    required this.type,
    required this.contentRating,
    this.mergedWith,
    this.canonicalUrl,
    this.title,
    this.nativeTitle,
    this.romanizedTitle,
    this.japaneseTitles = const <String>[],
    this.otherTitles = const <String>[],
    this.authors = const <String>[],
    this.artists = const <String>[],
    this.finalVolume,
    this.cover,
    this.description,
    this.year,
    this.startDate,
    this.rating,
    this.genres = const <String>[],
  });

  /// 简介纯文本（源站是英文 Markdown，已去掉强调 / 链接标记，见
  /// [mangaBakaPlainText]）；没有为 null。
  final String? description;

  /// 连载开始年份。
  final int? year;

  /// 连载开始日期原文（`published.start_date`，`YYYY-MM-DD`）。
  final String? startDate;

  /// 综合评分，已从源站的 0~100 归一到 0~10。
  final double? rating;

  /// 类型（源站 `genres` 蛇形小写，如 `slice_of_life`）。
  final List<String> genres;

  final int id;

  /// `active` / `merged` / …；`merged` 时 [mergedWith] 指向存活的系列。
  final String state;
  final int? mergedWith;

  /// 系列页（署名 / 「查看条目」用）。
  final String? canonicalUrl;

  /// 英文主标题。
  final String? title;

  /// 原文标题（日文作品即日文原名）。
  final String? nativeTitle;
  final String? romanizedTitle;

  /// `titles[]` 里 language 为 `ja` 的全部写法（含假名读法），不含 [nativeTitle]。
  final List<String> japaneseTitles;

  /// 其余可比较的写法（`titles[]` 的 en / ja-ro、`secondary_titles`）。
  final List<String> otherTitles;

  /// 作者 / 作画（MangaBaka 给的是罗马字名，如 `Gege Akutami`）。
  final List<String> authors;
  final List<String> artists;

  /// `manga` / `novel` / `manhwa` / `manhua` / `oel` / `one_shot` / `other` …
  final String type;

  /// `safe` / `suggestive` / `erotica` / `pornographic`。
  final String contentRating;

  /// 最终卷数（源站写成字符串，解析不出为 null）。
  final num? finalVolume;

  /// 系列主封面。
  final MangaBakaRawImage? cover;

  bool get isMerged => state == 'merged' && mergedWith != null;

  /// 成人向（不自动采用，见 book_art_matcher）。
  bool get isAdult =>
      contentRating == 'erotica' || contentRating == 'pornographic';

  /// 用于标题比较的全部写法，日文在前。
  List<String> get comparableTitles => <String>[
    ?nativeTitle,
    ...japaneseTitles,
    ?romanizedTitle,
    ?title,
    ...otherTitles,
  ];

  /// 展示名：日文原名优先。
  String get displayTitle => nativeTitle ?? title ?? romanizedTitle ?? '#$id';

  static MangaBakaSeries? fromJson(Object? json) {
    if (json is! Map) return null;
    final int? id = _int(json['id']);
    if (id == null) return null;
    final String? nativeTitle = _string(json['native_title']);
    final List<String> ja = <String>[];
    final List<String> other = <String>[];
    final Object? titles = json['titles'];
    if (titles is List) {
      for (final Object? t in titles) {
        if (t is! Map) continue;
        final String? text = _string(t['title']);
        if (text == null || text == nativeTitle) continue;
        final String language = _string(t['language']) ?? '';
        if (language == 'ja') {
          if (!ja.contains(text)) ja.add(text);
        } else if (language == 'en' || language == 'ja-ro') {
          if (!other.contains(text)) other.add(text);
        }
      }
    }
    final Object? secondary = json['secondary_titles'];
    if (secondary is Map) {
      for (final Object? group in secondary.values) {
        if (group is! List) continue;
        for (final Object? t in group) {
          final String? text = t is Map ? _string(t['title']) : null;
          if (text == null || text == nativeTitle) continue;
          if (!ja.contains(text) && !other.contains(text)) other.add(text);
        }
      }
    }
    final Object? cover = json['cover'];
    final Object? published = json['published'];
    final num? rating = _num(json['rating']);
    final String? description = _string(json['description']);
    return MangaBakaSeries(
      id: id,
      state: _string(json['state']) ?? 'active',
      mergedWith: _int(json['merged_with']),
      canonicalUrl: _string(json['canonical_url']),
      title: _string(json['title']),
      nativeTitle: nativeTitle,
      romanizedTitle: _string(json['romanized_title']),
      japaneseTitles: ja,
      otherTitles: other,
      authors: _strings(json['authors']),
      artists: _strings(json['artists']),
      type: _string(json['type'])?.toLowerCase() ?? 'unknown',
      contentRating: _string(json['content_rating'])?.toLowerCase() ?? 'safe',
      finalVolume: _num(json['final_volume']),
      cover: cover is Map ? MangaBakaRawImage.fromJson(cover['raw']) : null,
      description: description == null ? null : mangaBakaPlainText(description),
      year: _int(json['year']),
      startDate: published is Map ? _string(published['start_date']) : null,
      rating: rating == null || rating <= 0 ? null : rating / 10,
      genres: _strings(json['genres']),
    );
  }
}

/// MangaBaka 简介是 Markdown（如结尾的 `*Source: Yen Press, Vol. 1*`）；详情页按纯文本
/// 显示，这里去掉链接 / 强调 / 标题 / 行内代码标记，保留段落换行。去完为空返回 null。
String? mangaBakaPlainText(String markdown) {
  String text = markdown.replaceAll('\r\n', '\n');
  // [文字](url) → 文字；![alt](url) 图片整个去掉。
  text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]*\)'),
    (Match m) => m.group(1)!,
  );
  // 行首标题 / 引用标记。
  text = text.replaceAll(
    RegExp(r'^[ \t]*(#{1,6}|>)[ \t]*', multiLine: true),
    '',
  );
  // **粗体** / __粗体__ / *斜体* / _斜体_ / `代码`：只去成对的标记（不动 snake_case
  // 之类词内下划线）。
  for (final RegExp pattern in <RegExp>[
    RegExp(r'\*\*(\S(?:.*?\S)?)\*\*'),
    RegExp(r'(?<![\w])__(\S(?:.*?\S)?)__(?![\w])'),
    RegExp(r'\*(\S(?:.*?\S)?)\*'),
    RegExp(r'(?<![\w])_(\S(?:.*?\S)?)_(?![\w])'),
    RegExp(r'`([^`]+)`'),
  ]) {
    text = text.replaceAllMapped(pattern, (Match m) => m.group(1)!);
  }
  text = text
      .replaceAll(RegExp(r'[ \t]+$', multiLine: true), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return text.isEmpty ? null : text;
}

/// 源站类型键（`slice_of_life`）→ 展示名（`Slice of life`）。
String mangaBakaGenreLabel(String genre) {
  final String spaced = genre.replaceAll('_', ' ').trim();
  if (spaced.isEmpty) return spaced;
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// `/v1/series/{id}/images` 的一项。
class MangaBakaImage {
  const MangaBakaImage({
    required this.id,
    required this.index,
    required this.type,
    required this.raw,
    this.indexNumeric,
    this.language,
    this.note,
    this.contentRating = 'safe',
    this.thumbnailUrl,
  });

  final int id;

  /// 源站缩略图（`image.x250.x1`，没有则 `image.x150.x2`）：网格预览用，不下原图。
  final String? thumbnailUrl;

  /// 源站原样的卷序字符串（`"1"`、`"28.5"`、`"1.1"`）。
  final String index;

  /// 数值卷号；源站没给时按 [index] 解析。
  final num? indexNumeric;

  /// `volume` / `volume_back` / `banner`。
  final String type;
  final String? language;

  /// 变体说明（限定版 / 特装版 / 来源）；常规版为 null。
  final String? note;
  final String contentRating;
  final MangaBakaRawImage raw;

  static MangaBakaImage? fromJson(Object? json) {
    if (json is! Map) return null;
    final int? id = _int(json['id']);
    final Object? image = json['image'];
    final MangaBakaRawImage? raw = image is Map
        ? MangaBakaRawImage.fromJson(image['raw'])
        : null;
    if (id == null || raw == null) return null;
    final String index = _string(json['index']) ?? '';
    return MangaBakaImage(
      id: id,
      index: index,
      indexNumeric: _num(json['index_numeric']) ?? num.tryParse(index),
      type: _string(json['type'])?.toLowerCase() ?? '',
      language: _string(json['language'])?.toLowerCase(),
      note: _string(json['note']),
      contentRating: _string(json['content_rating'])?.toLowerCase() ?? 'safe',
      raw: raw,
      thumbnailUrl: _thumbnail(image as Map),
    );
  }

  static String? _thumbnail(Map<Object?, Object?> image) {
    final Object? x250 = image['x250'];
    final Object? x150 = image['x150'];
    return (x250 is Map ? _string(x250['x1']) : null) ??
        (x150 is Map ? _string(x150['x2']) : null);
  }
}

/// 一页结果 + 下一页 URL（源站给的 `pagination.next`，已带上全部筛选参数）。
class MangaBakaPage<T> {
  const MangaBakaPage({required this.items, this.next, this.count});

  final List<T> items;
  final String? next;
  final int? count;
}

/// 解析搜索响应（`/v1/series/search`）。
MangaBakaPage<MangaBakaSeries> parseMangaBakaSearch(String body) =>
    _parsePage(body, MangaBakaSeries.fromJson);

/// 解析图片响应的一页（`/v1/series/{id}/images`）。
MangaBakaPage<MangaBakaImage> parseMangaBakaImagesPage(String body) =>
    _parsePage(body, MangaBakaImage.fromJson);

/// 解析按 id 取系列（`/v1/series/{id}`）；`data` 不是对象时为 null。
MangaBakaSeries? parseMangaBakaSeries(String body) {
  final Map<Object?, Object?> root = _decodeObject(body);
  return MangaBakaSeries.fromJson(root['data']);
}

MangaBakaPage<T> _parsePage<T>(String body, T? Function(Object?) map) {
  final Map<Object?, Object?> root = _decodeObject(body);
  final Object? data = root['data'];
  final List<T> items = <T>[
    if (data is List)
      for (final Object? item in data) ?map(item),
  ];
  final Object? pagination = root['pagination'];
  return MangaBakaPage<T>(
    items: items,
    next: pagination is Map ? _string(pagination['next']) : null,
    count: pagination is Map ? _int(pagination['count']) : null,
  );
}

Map<Object?, Object?> _decodeObject(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw MangaBakaFormatException('JSON decode failed: ${e.message}');
  }
  if (decoded is! Map) {
    throw const MangaBakaFormatException('top level is not an object');
  }
  return decoded;
}

String? _string(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _int(Object? value) => switch (value) {
  final int v => v,
  final num v => v.toInt(),
  final String v => int.tryParse(v.trim()),
  _ => null,
};

num? _num(Object? value) => switch (value) {
  final num v => v,
  final String v => num.tryParse(v.trim()),
  _ => null,
};

List<String> _strings(Object? value) => <String>[
  if (value is List)
    for (final Object? v in value) ?_string(v),
];
