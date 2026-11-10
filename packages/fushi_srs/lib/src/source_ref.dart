/// 笔记出处 SourceRef（B-1，有类型的一等字段）。
///
/// 第六轮审查第 17、18 条：漫画的定位是「章节 + 页码」，不是 sectionIndex + 字符偏移；
/// 漫画 OCR 制卡、LNReader 在线小说、Aniyomi 在线视频的定位形状单独定义。
/// 未知 kind 原样保留、不解析。
library;

/// 出处种类（持久化名冻结）。
abstract final class SrsSourceKind {
  static const String book = 'book';
  static const String manga = 'manga';
  static const String video = 'video';
  static const String audiobook = 'audiobook';
  static const String onlineNovel = 'onlineNovel';
  static const String onlineVideo = 'onlineVideo';
  static const String game = 'game';

  /// 音乐模块歌词（曲目身份 + 时间区间，形状同 [video]）。
  static const String music = 'music';
  static const String web = 'web';
  static const String manual = 'manual';
  static const String anki = 'anki';
}

/// 出处。[data] 是该 kind 的定位字段（规范 JSON），未知 kind 原样保留。
class SrsSourceRef {
  const SrsSourceRef(this.kind, this.data);

  /// 本地书：书籍身份 + 章节下标 + 字符偏移区间。
  factory SrsSourceRef.book({
    required String bookKey,
    required int sectionIndex,
    required int charStart,
    int? charLength,
    String? title,
    String? seriesTitle,
  }) => SrsSourceRef(SrsSourceKind.book, <String, Object?>{
    'bookKey': bookKey,
    'section': sectionIndex,
    'start': charStart,
    if (charLength != null) 'len': charLength,
    if (title != null) 'title': title,
    ...seriesEntry(seriesTitle),
  });

  /// 漫画（本地或在线下载）：作品身份 + 章节身份 + 页码（从 0 起）+ 可选 OCR 框。
  factory SrsSourceRef.manga({
    required String mangaKey,
    required String chapterKey,
    required int page,
    List<double>? box,
    String? title,
  }) => SrsSourceRef(SrsSourceKind.manga, <String, Object?>{
    'mangaKey': mangaKey,
    'chapterKey': chapterKey,
    'page': page,
    if (box != null) 'box': box,
    if (title != null) 'title': title,
  });

  /// 本地视频 / 有声书：媒体身份 + 时间区间。
  factory SrsSourceRef.media({
    required String kind,
    required String mediaKey,
    required int startMs,
    int? endMs,
    String? title,
    String? seriesTitle,
  }) => SrsSourceRef(kind, <String, Object?>{
    'mediaKey': mediaKey,
    'startMs': startMs,
    if (endMs != null) 'endMs': endMs,
    if (title != null) 'title': title,
    ...seriesEntry(seriesTitle),
  });

  /// LNReader 在线小说：源 + 小说 URL + 章节 URL + 字符偏移。
  factory SrsSourceRef.onlineNovel({
    required String sourceId,
    required String novelUrl,
    required String chapterUrl,
    int? charStart,
    String? title,
  }) => SrsSourceRef(SrsSourceKind.onlineNovel, <String, Object?>{
    'sourceId': sourceId,
    'novelUrl': novelUrl,
    'chapterUrl': chapterUrl,
    if (charStart != null) 'start': charStart,
    if (title != null) 'title': title,
  });

  /// Aniyomi 在线视频：源 + 作品 URL + 剧集 URL + 时间区间。
  factory SrsSourceRef.onlineVideo({
    required String sourceId,
    required String animeUrl,
    required String episodeUrl,
    required int startMs,
    int? endMs,
    String? title,
    String? seriesTitle,
  }) => SrsSourceRef(SrsSourceKind.onlineVideo, <String, Object?>{
    'sourceId': sourceId,
    'animeUrl': animeUrl,
    'episodeUrl': episodeUrl,
    'startMs': startMs,
    if (endMs != null) 'endMs': endMs,
    if (title != null) 'title': title,
    ...seriesEntry(seriesTitle),
  });

  factory SrsSourceRef.web(String url, {String? title}) => SrsSourceRef(
    SrsSourceKind.web,
    <String, Object?>{'url': url, if (title != null) 'title': title},
  );

  final String kind;
  final Map<String, Object?> data;

  String? get title => data['title'] as String?;

  /// 出处的上一级（系列 / 合集名，反馈 MCJLSBR5Wg）：有它时出处按「系列 → 集」两级分组——浏览页出处视图、
  /// `src:` 查询与按作品出卡的分组键是系列（内核 store/browse.rs `source_key`），集（[title]，按
  /// mediaKey / bookKey 等作品身份区分）是系列下的第二级（`source_item_key`）；统计页「制卡来源」按系列计。
  /// 定位字段（mediaKey / startMs / 章节…）不变，「回到出处」仍到具体的集与时间。没有 = 只有集这一级。
  String? get seriesTitle {
    final Object? v = data[seriesKey];
    return v is String && v.trim().isNotEmpty ? v : null;
  }

  /// [seriesTitle] 的 JSON 键（持久化名，新加后冻结；内核 store/browse.rs / caches.rs 按同名读）。
  static const String seriesKey = 'seriesTitle';

  /// 工厂共用：系列名去两侧空白后非空才写键（空白名 = 不属系列，不写空串进出处）。
  static Map<String, Object?> seriesEntry(String? seriesTitle) {
    final String? t = seriesTitle?.trim();
    return t == null || t.isEmpty
        ? const <String, Object?>{}
        : <String, Object?>{seriesKey: t};
  }

  Map<String, Object?> toJson() => <String, Object?>{'kind': kind, ...data};

  static SrsSourceRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? kind = json['kind'];
    if (kind is! String) return null;
    return SrsSourceRef(kind, <String, Object?>{
      for (final MapEntry<Object?, Object?> e in json.entries)
        if (e.key != 'kind') '${e.key}': e.value,
    });
  }
}
