/// 互联 host 代理浏览**本机已启用的在线漫画源**（Mihon / Aidoku 扩展源）的
/// host 侧契约（`/api/manga-sources/**`，能力位 `mangaSources`）。
///
/// 与 `MangaLibraryHost`（对端漫画**库**，只列已下载内容）是两回事：这里对端把
/// 自己跑着的扩展当成源借给本机——热门 / 最新 / 搜索 / 详情 / 章节 / 页图全由
/// 对端的运行时执行，本机只拿结果。Mihon 扩展只在桌面 / 安卓有宿主、Aidoku 只在
/// macOS 有宿主，iOS 与无头服务端都提供不了，所以这是一个**可选** host 服务：
/// 未接线 → 端点 404、能力位不出现，老 client / 老 host 双向兼容。
///
/// wire 形状刻意与 app 侧 `OnlineMangaSeries.toJson` / `OnlineMangaChapter.toJson`
/// 逐字同源（`key / title / coverUrl / … / raw`），引擎这边不再定义第二份作品 /
/// 章节模型：series / chapter / page 在引擎里只是不透明的 JSON map，原样往返——
/// 对端的运行时要什么 `raw` 就回灌什么，本机不解释。
library;

import 'dart:typed_data';

/// 对端一个已启用的在线源。
///
/// [id] 是对端侧的稳定源身份（`mihon:<包名>:<源 id>` / `aidoku:<包 id>`），**不含
/// 对端设备**：同一个源经哪台对端代理都是同一个源，对端只是传输层。
class RemoteMangaSourceInfo {
  const RemoteMangaSourceInfo({
    required this.id,
    required this.runtime,
    required this.name,
    required this.language,
    this.baseUrl = '',
    this.supportsLatest = true,
    this.supportsFilters = false,
  });

  final String id;

  /// 对端运行时种类：`mihon` / `aidoku`。
  final String runtime;
  final String name;
  final String language;
  final String baseUrl;
  final bool supportsLatest;
  final bool supportsFilters;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'runtime': runtime,
    'name': name,
    'language': language,
    'baseUrl': baseUrl,
    'supportsLatest': supportsLatest,
    'supportsFilters': supportsFilters,
  };

  static RemoteMangaSourceInfo? fromJson(Map<String, Object?> json) {
    final String id = json['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return RemoteMangaSourceInfo(
      id: id,
      runtime: json['runtime']?.toString() ?? '',
      name: json['name']?.toString() ?? id,
      language: json['language']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      supportsLatest: json['supportsLatest'] != false,
      supportsFilters: json['supportsFilters'] == true,
    );
  }
}

enum RemoteMangaBrowseMode {
  popular,
  latest,
  search;

  static RemoteMangaBrowseMode? fromWire(Object? value) {
    for (final RemoteMangaBrowseMode mode in RemoteMangaBrowseMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

/// 一页浏览结果：作品 JSON 列表 + 是否还有下一页。
class RemoteMangaBrowsePage {
  const RemoteMangaBrowsePage({required this.items, required this.hasNextPage});

  final List<Map<String, Object?>> items;
  final bool hasNextPage;

  Map<String, Object?> toJson() => <String, Object?>{
    'items': items,
    'hasNextPage': hasNextPage,
  };

  static RemoteMangaBrowsePage fromJson(Map<String, Object?> json) =>
      RemoteMangaBrowsePage(
        items: jsonMapList(json['items']),
        hasNextPage: json['hasNextPage'] == true,
      );
}

/// 作品详情 + 章节列表。
class RemoteMangaSeriesDetail {
  const RemoteMangaSeriesDetail({required this.series, required this.chapters});

  final Map<String, Object?> series;
  final List<Map<String, Object?>> chapters;

  Map<String, Object?> toJson() => <String, Object?>{
    'series': series,
    'chapters': chapters,
  };

  static RemoteMangaSeriesDetail fromJson(Map<String, Object?> json) =>
      RemoteMangaSeriesDetail(
        series: jsonMap(json['series']),
        chapters: jsonMapList(json['chapters']),
      );
}

/// 一张图的字节 + 类型（页图 / 封面）。
class RemoteMangaImage {
  const RemoteMangaImage({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

/// host 侧运行时失败的结构化错误。路由层按 [code] 映射状态码：
/// `source_not_found` → 404；其余 → 502 并把 `{error: {code, message}}` 原样下发，
/// client 按 code 分型（`cloudflare` 要引导用户去**对端**解题——挑战页只能在跑着
/// 扩展的那台机器上弹）。
class HostMangaSourceException implements Exception {
  const HostMangaSourceException(this.code, this.message);

  static const String codeSourceNotFound = 'source_not_found';
  static const String codeCloudflare = 'cloudflare';
  static const String codeRuntime = 'runtime';

  final String code;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'error': <String, Object?>{'code': code, 'message': message},
  };

  @override
  String toString() => 'HostMangaSourceException($code): $message';
}

abstract interface class HostMangaSourceHost {
  /// 能力位：`{version: 1, runtimes: ['mihon', ...]}`。
  Future<Map<String, Object?>> capability();

  /// 对端**当前已启用**的源（源与其扩展都启用；Aidoku 已启用包）。
  Future<List<RemoteMangaSourceInfo>> listSources();

  /// 该源的过滤器定义（Mihon bridge JSON；Aidoku 恒空）。
  Future<List<Map<String, Object?>>> filters(String sourceId);

  Future<RemoteMangaBrowsePage> browse(
    String sourceId, {
    required RemoteMangaBrowseMode mode,
    required int page,
    String query = '',
    List<Map<String, Object?>> filters = const <Map<String, Object?>>[],
  });

  Future<RemoteMangaSeriesDetail> details(
    String sourceId,
    Map<String, Object?> series,
  );

  /// 某章的页表；每项是对端运行时的页 JSON，回灌给 [pageImage]。
  Future<List<Map<String, Object?>>> pages(
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
  );

  Future<RemoteMangaImage> pageImage(
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
    Map<String, Object?> page,
  );

  Future<RemoteMangaImage> coverImage(String sourceId, String url);
}

/// JSON 解码后的 `Map<Object?,Object?>` 收窄成 `Map<String,Object?>`（非 map → 空）。
Map<String, Object?> jsonMap(Object? value) => value is Map<Object?, Object?>
    ? value.cast<String, Object?>()
    : const <String, Object?>{};

/// JSON 解码后的列表收窄成 map 列表（跳过非 map 项）。
List<Map<String, Object?>> jsonMapList(Object? value) => value is List<Object?>
    ? <Map<String, Object?>>[
        for (final Object? item in value)
          if (item is Map<Object?, Object?>) item.cast<String, Object?>(),
      ]
    : const <Map<String, Object?>>[];
