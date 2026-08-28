import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 提供这条书架条目的在线漫画运行时。
///
/// 只用来在**重启后**把条目分派回正确的适配器，因此值必须稳定——它已经被写进
/// 用户库里的 `sourceMetadata` JSON。
enum OnlineMangaRuntimeKind {
  mihon('mihon'),
  aidoku('aidoku');

  const OnlineMangaRuntimeKind(this.wireValue);

  final String wireValue;

  static OnlineMangaRuntimeKind? fromWire(String? value) {
    for (final OnlineMangaRuntimeKind kind in OnlineMangaRuntimeKind.values) {
      if (kind.wireValue == value) return kind;
    }
    return null;
  }
}

/// 归一化后的章节。
///
/// [raw] 保留**运行时原生 payload**，因为翻页最终还是要把它交回
/// `MihonRuntime.getPages` / `AidokuRuntime.getPages`。归一化只覆盖「展示 +
/// 身份」这几个字段：如果把 raw 丢掉换成完全结构化的模型，每加一个源就要
/// 在中间层补一次字段映射，而中间层根本不需要理解那些字段。
@immutable
class OnlineMangaChapter {
  const OnlineMangaChapter({
    required this.key,
    required this.name,
    required this.raw,
    this.scanlator,
    this.number,
    this.uploadedAt,
  });

  /// 源内章节身份。Mihon = `url`；Aidoku = `chapter['key']`。
  ///
  /// 这是 `manga_chapter_states.chapter_key` 的取值，也是刷新章节列表后重新
  /// 定位「当前读到哪一章」的锚——索引会随源更新漂移，key 不会。
  final String key;
  final String name;
  final String? scanlator;
  final double? number;

  /// 上传时刻（毫秒）。0 或缺失记 null，避免 UI 把「未知」显示成 1970。
  final int? uploadedAt;

  /// 运行时原生 payload，原样回灌 `getPages`。
  final Map<String, Object?> raw;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'name': name,
        if (scanlator != null) 'scanlator': scanlator,
        if (number != null) 'number': number,
        if (uploadedAt != null) 'uploadedAt': uploadedAt,
        'raw': raw,
      };

  static OnlineMangaChapter? fromJson(Map<String, Object?> json) {
    final String key = json['key']?.toString() ?? '';
    if (key.isEmpty) return null;
    final Object? raw = json['raw'];
    final int? uploadedAt = (json['uploadedAt'] as num?)?.toInt();
    return OnlineMangaChapter(
      key: key,
      name: json['name']?.toString() ?? '',
      scanlator: json['scanlator']?.toString(),
      number: (json['number'] as num?)?.toDouble(),
      uploadedAt: uploadedAt == null || uploadedAt <= 0 ? null : uploadedAt,
      raw: raw is Map<Object?, Object?>
          ? raw.cast<String, Object?>()
          : const <String, Object?>{},
    );
  }

  /// 从 v1 (`hibiki-mihon`) 描述符里的 `MihonChapter.toJson()` 升格。
  ///
  /// 老库里的章节没有独立 `key` 字段，身份就是 `url`；raw 直接沿用整个 map，
  /// 因为它本来就是 `MihonChapter.fromJson` 能吃的形状。
  static OnlineMangaChapter? fromLegacyMihonJson(Map<String, Object?> json) {
    final String url = json['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    final int uploadedAt = (json['date_upload'] as num?)?.toInt() ?? 0;
    return OnlineMangaChapter(
      key: url,
      name: json['name']?.toString() ?? '',
      scanlator: json['scanlator']?.toString(),
      number: (json['chapter_number'] as num?)?.toDouble(),
      uploadedAt: uploadedAt <= 0 ? null : uploadedAt,
      raw: json,
    );
  }
}

/// 归一化后的作品。[raw] 同样保留运行时原生 payload。
@immutable
class OnlineMangaSeries {
  const OnlineMangaSeries({
    required this.key,
    required this.title,
    required this.raw,
    this.coverUrl,
    this.author,
    this.artist,
    this.description,
    this.genre,
  });

  /// 源内作品身份。Mihon = `url`；Aidoku = `manga['key']`。
  final String key;
  final String title;
  final String? coverUrl;
  final String? author;
  final String? artist;
  final String? description;

  /// 源给的原始体裁串（逗号分隔）；拆分交给 UI，因为不同源分隔符不一致。
  final String? genre;
  final Map<String, Object?> raw;

  List<String> get genreLabels {
    final String? value = genre;
    if (value == null || value.trim().isEmpty) return const <String>[];
    return value
        .split(RegExp(r'[,，、;；]'))
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toList(growable: false);
  }

  /// 作者优先、画师兜底——书架和卡片的副标题只有一行。
  String? get byline {
    final String? primary = author?.trim();
    if (primary != null && primary.isNotEmpty) return primary;
    final String? secondary = artist?.trim();
    if (secondary != null && secondary.isNotEmpty) return secondary;
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'title': title,
        if (coverUrl != null) 'coverUrl': coverUrl,
        if (author != null) 'author': author,
        if (artist != null) 'artist': artist,
        if (description != null) 'description': description,
        if (genre != null) 'genre': genre,
        'raw': raw,
      };

  static OnlineMangaSeries? fromJson(Map<String, Object?> json) {
    final String key = json['key']?.toString() ?? '';
    if (key.isEmpty) return null;
    final Object? raw = json['raw'];
    return OnlineMangaSeries(
      key: key,
      title: json['title']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString(),
      author: json['author']?.toString(),
      artist: json['artist']?.toString(),
      description: json['description']?.toString(),
      genre: json['genre']?.toString(),
      raw: raw is Map<Object?, Object?>
          ? raw.cast<String, Object?>()
          : const <String, Object?>{},
    );
  }

  /// 从 v1 描述符里的 `MihonManga.toJson()` 升格。
  static OnlineMangaSeries? fromLegacyMihonJson(Map<String, Object?> json) {
    final String url = json['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    return OnlineMangaSeries(
      key: url,
      title: json['title']?.toString() ?? '',
      coverUrl: (json['thumbnail_url'] ?? json['coverUrl'])?.toString(),
      author: json['author']?.toString(),
      artist: json['artist']?.toString(),
      description: json['description']?.toString(),
      genre: json['genre']?.toString(),
      raw: json,
    );
  }
}

/// 存进 [EpubBookRow.sourceMetadata] 的重启安全描述符（**不含**任何敏感信息）。
///
/// v88 前这里存的是 `MihonLibraryEntry`（`type: 'hibiki-mihon'`，硬绑
/// `MihonManga`/`MihonChapter`）。Aidoku 因此完全无法入库——它的作品/章节是无
/// 类型 map，塞不进那个形状。本类把描述符泛化成「运行时 + 归一化实体 + 原生
/// payload」，两个运行时共用同一条书架、同一个阅读器、同一份每章状态。
///
/// **向后兼容是硬约束**：[tryParse] 同时吃 v1 和 v2。存量书架条目一行都不用改
/// 就能继续打开；它们会在下一次刷新章节列表时被顺带写成 v2。
@immutable
class OnlineMangaLibraryEntry {
  const OnlineMangaLibraryEntry({
    required this.runtime,
    required this.extensionPackage,
    required this.sourceId,
    required this.series,
    required this.chapters,
    this.currentChapterIndex,
  });

  /// v1：只有 Mihon 的旧描述符。仍然解析，永不再写出。
  static const String legacyMihonMarker = 'hibiki-mihon';
  static const int legacyMihonVersion = 1;

  /// v2：运行时无关描述符。
  static const String marker = 'hibiki-online-manga';
  static const int version = 2;

  final OnlineMangaRuntimeKind runtime;

  /// Mihon = 扩展 `packageName`；Aidoku = 安装包 `id`。
  final String extensionPackage;

  /// Mihon = 源 id（十进制字符串，避免 JS 精度损失）；Aidoku = 包 id（单源包）。
  final String sourceId;

  final OnlineMangaSeries series;
  final List<OnlineMangaChapter> chapters;

  /// 最后一次**选中**的章节下标。
  ///
  /// 注意它表达的是「选择」不是「进度」：读到哪一页归 `manga_chapter_states`。
  /// 刷新章节列表后按 [OnlineMangaChapter.key] 重新定位，不靠下标。
  final int? currentChapterIndex;

  OnlineMangaChapter? get currentChapter {
    final int? index = currentChapterIndex;
    if (index == null || index < 0 || index >= chapters.length) return null;
    return chapters[index];
  }

  int indexOfChapterKey(String key) =>
      chapters.indexWhere((OnlineMangaChapter item) => item.key == key);

  OnlineMangaLibraryEntry copyWith({
    OnlineMangaSeries? series,
    List<OnlineMangaChapter>? chapters,
    int? currentChapterIndex,
    bool clearCurrentChapter = false,
  }) =>
      OnlineMangaLibraryEntry(
        runtime: runtime,
        extensionPackage: extensionPackage,
        sourceId: sourceId,
        series: series ?? this.series,
        chapters: chapters ?? this.chapters,
        currentChapterIndex: clearCurrentChapter
            ? null
            : currentChapterIndex ?? this.currentChapterIndex,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'type': marker,
        'version': version,
        'runtime': runtime.wireValue,
        'extensionPackage': extensionPackage,
        'sourceId': sourceId,
        'series': series.toJson(),
        'chapters': <Map<String, Object?>>[
          for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
        ],
        'currentChapterIndex': currentChapterIndex,
      };

  String encode() => jsonEncode(toJson());

  static OnlineMangaLibraryEntry? tryParse(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(value);
      if (decoded is! Map<Object?, Object?>) return null;
      final Map<String, Object?> json = decoded.cast<String, Object?>();
      final String? type = json['type']?.toString();
      final int type2Version = (json['version'] as num?)?.toInt() ?? 0;
      if (type == marker && type2Version == version) {
        return _parseV2(json);
      }
      if (type == legacyMihonMarker && type2Version == legacyMihonVersion) {
        return _parseLegacyMihon(json);
      }
      return null;
    } on Object {
      // 描述符坏了只应该让这本书退化成「不是在线漫画」，不该让书架整页炸。
      return null;
    }
  }

  static OnlineMangaLibraryEntry? _parseV2(Map<String, Object?> json) {
    final OnlineMangaRuntimeKind? runtime =
        OnlineMangaRuntimeKind.fromWire(json['runtime']?.toString());
    final Object? rawSeries = json['series'];
    final Object? rawChapters = json['chapters'];
    if (runtime == null ||
        rawSeries is! Map<Object?, Object?> ||
        rawChapters is! List<Object?>) {
      return null;
    }
    final OnlineMangaSeries? series =
        OnlineMangaSeries.fromJson(rawSeries.cast<String, Object?>());
    if (series == null) return null;
    return OnlineMangaLibraryEntry(
      runtime: runtime,
      extensionPackage: json['extensionPackage']?.toString() ?? '',
      sourceId: json['sourceId']?.toString() ?? '',
      series: series,
      chapters: _chaptersFrom(rawChapters, OnlineMangaChapter.fromJson),
      currentChapterIndex: (json['currentChapterIndex'] as num?)?.toInt(),
    );
  }

  static OnlineMangaLibraryEntry? _parseLegacyMihon(Map<String, Object?> json) {
    final Object? rawManga = json['manga'];
    final Object? rawChapters = json['chapters'];
    if (rawManga is! Map<Object?, Object?> || rawChapters is! List<Object?>) {
      return null;
    }
    final OnlineMangaSeries? series =
        OnlineMangaSeries.fromLegacyMihonJson(rawManga.cast<String, Object?>());
    if (series == null) return null;
    return OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: json['extensionPackage']?.toString() ?? '',
      sourceId: json['sourceId']?.toString() ?? '',
      series: series,
      chapters:
          _chaptersFrom(rawChapters, OnlineMangaChapter.fromLegacyMihonJson),
      currentChapterIndex: (json['currentChapterIndex'] as num?)?.toInt(),
    );
  }

  static List<OnlineMangaChapter> _chaptersFrom(
    List<Object?> raw,
    OnlineMangaChapter? Function(Map<String, Object?>) parse,
  ) {
    final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[];
    for (final Object? item in raw) {
      if (item is! Map<Object?, Object?>) continue;
      final OnlineMangaChapter? chapter = parse(item.cast<String, Object?>());
      // 无 key 的章节丢掉而不是留空 key：空 key 会在 manga_chapter_states 里
      // 把所有坏章节挤进同一主键，互相覆盖已读状态。
      if (chapter != null) chapters.add(chapter);
    }
    return List<OnlineMangaChapter>.unmodifiable(chapters);
  }
}
