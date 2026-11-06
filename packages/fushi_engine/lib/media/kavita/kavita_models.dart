/// Kavita 协议层 DTO 与 JSON→DTO 纯函数解析（纯 Dart，无 Flutter / 插件）。
///
/// 协议基线是 Kavita 0.8.x（`Kareadita/Kavita` main）。该服务器不暴露 swagger，
/// 所以解析一律**容忍未知字段与缺字段**：缺字段取安全缺省值，类型不符当缺字段。
///
/// 已知坑（实测 0.8.8.0）：
/// - 独立 EPUB 出现在 `series-detail.specials`，不在 `volumes`——[KavitaSeriesDetail.allChapters]
///   负责把 volumes / chapters / specials / storylineChapters 摊平并按 id 去重。
/// - `chapter-info.libraryType` 对书籍库也可能报 0，判书籍一律看 `seriesFormat`
///   （[KavitaFormat.epub]），不要看库类型。
library;

/// 系列 / 章节文件格式（`MangaFormat`）。
abstract final class KavitaFormat {
  static const int image = 0;
  static const int archive = 1;
  static const int unknown = 2;
  static const int epub = 3;
  static const int pdf = 4;
}

/// 库类型（`LibraryType`）。**不可用来判格式**，见文件头。
abstract final class KavitaLibraryType {
  static const int manga = 0;
  static const int comic = 1;
  static const int book = 2;
  static const int image = 3;
  static const int lightNovel = 4;
  static const int comicVine = 5;
}

int _asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

int? _asIntOrNull(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

String _asString(Object? v, [String fallback = '']) =>
    v is String ? v : (v == null ? fallback : v.toString());

String? _asStringOrNull(Object? v) {
  if (v == null) return null;
  final String s = v is String ? v : v.toString();
  return s.isEmpty ? null : s;
}

double? _asDoubleOrNull(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Kavita 的时间戳是不带时区后缀的 UTC ISO 串（`2026-10-26T08:00:00.123`）；
/// 不带 `Z` 时 `DateTime.parse` 会当本地时间，所以这里强制按 UTC 解释。
DateTime? parseKavitaUtc(Object? v) {
  if (v is! String || v.isEmpty) return null;
  final String s = v.trim();
  final bool hasZone =
      s.endsWith('Z') || RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s);
  final DateTime? parsed = DateTime.tryParse(hasZone ? s : '${s}Z');
  return parsed?.toUtc();
}

List<Map<String, Object?>> _asMapList(Object? v) {
  if (v is! List) return const <Map<String, Object?>>[];
  return <Map<String, Object?>>[
    for (final Object? e in v)
      if (e is Map) e.cast<String, Object?>(),
  ];
}

/// 鉴权结果（`POST /api/Plugin/authenticate`）。
class KavitaAuthResult {
  const KavitaAuthResult({
    required this.token,
    this.refreshToken,
    this.apiKey,
    this.username,
  });

  factory KavitaAuthResult.fromJson(Map<String, Object?> json) {
    return KavitaAuthResult(
      token: _asString(json['token']),
      refreshToken: _asStringOrNull(json['refreshToken']),
      apiKey: _asStringOrNull(json['apiKey']),
      username: _asStringOrNull(json['username']),
    );
  }

  final String token;
  final String? refreshToken;
  final String? apiKey;
  final String? username;

  /// 刻意不输出 token / key。
  @override
  String toString() => 'KavitaAuthResult(username: $username)';
}

class KavitaLibrary {
  const KavitaLibrary({
    required this.id,
    required this.name,
    required this.type,
  });

  factory KavitaLibrary.fromJson(Map<String, Object?> json) => KavitaLibrary(
    id: _asInt(json['id']),
    name: _asString(json['name']),
    type: _asInt(json['type']),
  );

  final int id;
  final String name;
  final int type;

  bool get isBookLibrary =>
      type == KavitaLibraryType.book || type == KavitaLibraryType.lightNovel;
}

class KavitaSeries {
  const KavitaSeries({
    required this.id,
    required this.name,
    required this.libraryId,
    required this.format,
    required this.pages,
    required this.pagesRead,
    this.localizedName,
    this.originalName,
    this.sortName,
    this.libraryName,
    this.latestReadDate,
  });

  factory KavitaSeries.fromJson(Map<String, Object?> json) => KavitaSeries(
    id: _asInt(json['id']),
    name: _asString(json['name']),
    localizedName: _asStringOrNull(json['localizedName']),
    originalName: _asStringOrNull(json['originalName']),
    sortName: _asStringOrNull(json['sortName']),
    libraryId: _asInt(json['libraryId']),
    libraryName: _asStringOrNull(json['libraryName']),
    format: _asInt(json['format'], KavitaFormat.unknown),
    pages: _asInt(json['pages']),
    pagesRead: _asInt(json['pagesRead']),
    latestReadDate: parseKavitaUtc(json['latestReadDate']),
  );

  final int id;
  final String name;
  final String? localizedName;
  final String? originalName;
  final String? sortName;
  final int libraryId;
  final String? libraryName;
  final int format;
  final int pages;
  final int pagesRead;
  final DateTime? latestReadDate;

  bool get isEpub => format == KavitaFormat.epub;
  bool get isPdf => format == KavitaFormat.pdf;
  bool get isArchive =>
      format == KavitaFormat.archive || format == KavitaFormat.image;

  /// 展示名：优先本地化名，回退 [name]。
  String get displayName {
    final String? l = localizedName;
    return (l == null || l.isEmpty) ? name : l;
  }
}

/// 一页分页的系列结果 + 服务器分页头。
class KavitaSeriesPage {
  const KavitaSeriesPage({
    required this.items,
    required this.pageNumber,
    required this.totalPages,
    required this.totalItems,
  });

  final List<KavitaSeries> items;
  final int pageNumber;
  final int totalPages;
  final int totalItems;

  bool get hasMore => pageNumber < totalPages;
}

class KavitaFile {
  const KavitaFile({
    required this.id,
    required this.filePath,
    required this.pages,
    required this.bytes,
    required this.format,
  });

  factory KavitaFile.fromJson(Map<String, Object?> json) => KavitaFile(
    id: _asInt(json['id']),
    filePath: _asString(json['filePath']),
    pages: _asInt(json['pages']),
    bytes: _asInt(json['bytes']),
    format: _asInt(json['format'], KavitaFormat.unknown),
  );

  final int id;
  final String filePath;
  final int pages;
  final int bytes;
  final int format;
}

class KavitaChapter {
  const KavitaChapter({
    required this.id,
    required this.volumeId,
    required this.pages,
    required this.pagesRead,
    required this.isSpecial,
    required this.range,
    required this.title,
    required this.titleName,
    required this.sortOrder,
    required this.files,
    this.minNumber,
    this.maxNumber,
    this.lastReadingProgressUtc,
  });

  factory KavitaChapter.fromJson(
    Map<String, Object?> json, {
    int? fallbackVolumeId,
  }) => KavitaChapter(
    id: _asInt(json['id']),
    volumeId: _asInt(json['volumeId'], fallbackVolumeId ?? 0),
    pages: _asInt(json['pages']),
    pagesRead: _asInt(json['pagesRead']),
    isSpecial: json['isSpecial'] == true,
    range: _asString(json['range']),
    title: _asString(json['title']),
    titleName: _asString(json['titleName']),
    sortOrder: _asDoubleOrNull(json['sortOrder']) ?? 0,
    minNumber: _asDoubleOrNull(json['minNumber']),
    maxNumber: _asDoubleOrNull(json['maxNumber']),
    lastReadingProgressUtc: parseKavitaUtc(json['lastReadingProgressUtc']),
    files: <KavitaFile>[
      for (final Map<String, Object?> f in _asMapList(json['files']))
        KavitaFile.fromJson(f),
    ],
  );

  final int id;
  final int volumeId;
  final int pages;
  final int pagesRead;
  final bool isSpecial;
  final String range;
  final String title;
  final String titleName;
  final double sortOrder;
  final double? minNumber;
  final double? maxNumber;
  final DateTime? lastReadingProgressUtc;
  final List<KavitaFile> files;

  bool get isRead => pages > 0 && pagesRead >= pages;

  /// 章节展示名：titleName → title → range → `#id`。
  String get displayName {
    for (final String s in <String>[titleName, title, range]) {
      if (s.trim().isNotEmpty) return s.trim();
    }
    return '#$id';
  }

  /// 第一个文件的字节数（`Download/chapter` 的体积预估）。
  int get totalBytes =>
      files.fold<int>(0, (int a, KavitaFile f) => a + f.bytes);
}

class KavitaVolume {
  const KavitaVolume({
    required this.id,
    required this.name,
    required this.pages,
    required this.pagesRead,
    required this.chapters,
    this.minNumber,
  });

  factory KavitaVolume.fromJson(Map<String, Object?> json) {
    final int id = _asInt(json['id']);
    return KavitaVolume(
      id: id,
      name: _asString(json['name']),
      pages: _asInt(json['pages']),
      pagesRead: _asInt(json['pagesRead']),
      minNumber: _asDoubleOrNull(json['minNumber']),
      chapters: <KavitaChapter>[
        for (final Map<String, Object?> c in _asMapList(json['chapters']))
          KavitaChapter.fromJson(c, fallbackVolumeId: id),
      ],
    );
  }

  final int id;
  final String name;
  final int pages;
  final int pagesRead;
  final double? minNumber;
  final List<KavitaChapter> chapters;
}

/// `GET /api/Series/series-detail`。
class KavitaSeriesDetail {
  const KavitaSeriesDetail({
    required this.volumes,
    required this.chapters,
    required this.specials,
    required this.storylineChapters,
  });

  factory KavitaSeriesDetail.fromJson(Map<String, Object?> json) {
    List<KavitaChapter> chaptersOf(Object? v) => <KavitaChapter>[
      for (final Map<String, Object?> c in _asMapList(v))
        KavitaChapter.fromJson(c),
    ];
    return KavitaSeriesDetail(
      volumes: <KavitaVolume>[
        for (final Map<String, Object?> v in _asMapList(json['volumes']))
          KavitaVolume.fromJson(v),
      ],
      chapters: chaptersOf(json['chapters']),
      specials: chaptersOf(json['specials']),
      storylineChapters: chaptersOf(json['storylineChapters']),
    );
  }

  final List<KavitaVolume> volumes;
  final List<KavitaChapter> chapters;
  final List<KavitaChapter> specials;
  final List<KavitaChapter> storylineChapters;

  /// 摊平后的全部章节：volumes[].chapters → storylineChapters → chapters →
  /// specials，按章节 id 去重（先出现者保留），再按 [KavitaChapter.sortOrder] 稳定排序。
  List<KavitaChapter> get allChapters {
    final Set<int> seen = <int>{};
    final List<KavitaChapter> out = <KavitaChapter>[];
    void add(KavitaChapter c) {
      if (c.id != 0 && seen.add(c.id)) out.add(c);
    }

    for (final KavitaVolume v in volumes) {
      v.chapters.forEach(add);
    }
    storylineChapters.forEach(add);
    chapters.forEach(add);
    specials.forEach(add);

    // List.sort 不稳定：带原序下标比较。
    final List<MapEntry<int, KavitaChapter>> indexed =
        <MapEntry<int, KavitaChapter>>[
          for (int i = 0; i < out.length; i++)
            MapEntry<int, KavitaChapter>(i, out[i]),
        ];
    indexed.sort((
      MapEntry<int, KavitaChapter> a,
      MapEntry<int, KavitaChapter> b,
    ) {
      final int c = a.value.sortOrder.compareTo(b.value.sortOrder);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    return <KavitaChapter>[
      for (final MapEntry<int, KavitaChapter> e in indexed) e.value,
    ];
  }
}

/// `GET /api/Reader/chapter-info`。
class KavitaChapterInfo {
  const KavitaChapterInfo({
    required this.pages,
    required this.seriesId,
    required this.volumeId,
    required this.libraryId,
    required this.seriesFormat,
    required this.seriesName,
    required this.title,
    required this.isSpecial,
    this.fileName,
  });

  factory KavitaChapterInfo.fromJson(Map<String, Object?> json) =>
      KavitaChapterInfo(
        pages: _asInt(json['pages']),
        seriesId: _asInt(json['seriesId']),
        volumeId: _asInt(json['volumeId']),
        libraryId: _asInt(json['libraryId']),
        seriesFormat: _asInt(json['seriesFormat'], KavitaFormat.unknown),
        seriesName: _asString(json['seriesName']),
        title: _asString(json['chapterTitle'], _asString(json['title'])),
        isSpecial: json['isSpecial'] == true,
        fileName: _asStringOrNull(json['fileName']),
      );

  final int pages;
  final int seriesId;
  final int volumeId;
  final int libraryId;
  final int seriesFormat;
  final String seriesName;
  final String title;
  final bool isSpecial;
  final String? fileName;

  bool get isEpub => seriesFormat == KavitaFormat.epub;
}

/// 阅读进度（`ProgressDto`）。`lastModifiedUtc` 只由服务器写入，客户端发送无效。
class KavitaProgress {
  const KavitaProgress({
    required this.volumeId,
    required this.chapterId,
    required this.pageNum,
    required this.seriesId,
    required this.libraryId,
    this.bookScrollId,
    this.lastModifiedUtc,
  });

  factory KavitaProgress.fromJson(Map<String, Object?> json) => KavitaProgress(
    volumeId: _asInt(json['volumeId']),
    chapterId: _asInt(json['chapterId']),
    pageNum: _asInt(json['pageNum']),
    seriesId: _asInt(json['seriesId']),
    libraryId: _asInt(json['libraryId']),
    bookScrollId: _asStringOrNull(json['bookScrollId']),
    lastModifiedUtc: parseKavitaUtc(json['lastModifiedUtc']),
  );

  final int volumeId;
  final int chapterId;
  final int pageNum;
  final int seriesId;
  final int libraryId;
  final String? bookScrollId;
  final DateTime? lastModifiedUtc;

  /// 上报体：不带 `lastModifiedUtc`（服务器自己盖章）。
  Map<String, Object?> toRequestJson() => <String, Object?>{
    'volumeId': volumeId,
    'chapterId': chapterId,
    'pageNum': pageNum,
    'seriesId': seriesId,
    'libraryId': libraryId,
    if (bookScrollId != null) 'bookScrollId': bookScrollId,
  };
}

/// `GET /api/Book/{chapterId}/chapters` 的一条目录项（`BookChapterItem`），子项递归。
class KavitaBookTocItem {
  const KavitaBookTocItem({
    required this.title,
    required this.page,
    required this.children,
    this.part,
  });

  factory KavitaBookTocItem.fromJson(Map<String, Object?> json) =>
      KavitaBookTocItem(
        title: _asString(json['title']),
        page: _asInt(json['page']),
        part: _asStringOrNull(json['part']),
        children: <KavitaBookTocItem>[
          for (final Map<String, Object?> c in _asMapList(json['children']))
            KavitaBookTocItem.fromJson(c),
        ],
      );

  final String title;

  /// 脊柱页下标（0 起）。
  final int page;
  final String? part;
  final List<KavitaBookTocItem> children;
}

/// 通用整数解析导出（API 层读分页头用）。
int? kavitaTryInt(Object? v) => _asIntOrNull(v);
