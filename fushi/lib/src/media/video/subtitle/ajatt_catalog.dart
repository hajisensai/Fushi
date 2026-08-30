/// AJATT 日语字幕库（`subtitles.ajatt.top`，Ajatt-Tools/kitsunekko-mirror 的静态镜像站）
/// 的**目录模型 + 页面解析 + 磁盘缓存 + HTTP 客户端**。
///
/// 站点形态（2026-08-29 实测）：
/// - 纯静态 HTML，**没有 JSON / API**。`index.html`（动画：anime_tv / anime_movie /
///   unsorted，约 5000 条、3.6 MB）+ `drama.html`（真人剧：drama_tv / drama_movie，约
///   7700 条）。每行 `<tr data-timestamp data-entry-type>` 带作品页链接、英文名、日文名。
/// - 作品页 `<type>/<slug>.html`：文件表每行 `data-download-url`（指向
///   `raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/.../subtitles/<type>/<dir>/<file>`）
///   + `data-filename` + `data-file-size` + `data-timestamp`；页面分 srt / ass / all 三段，
///   **同一文件会出现两次**，解析后按下载 URL 去重。
/// - 每个作品目录下有 `.kitsuinfo.json`：`{entry_id, name, entry_type, english_name,
///   japanese_name, anilist_id}`——这是按 AniList id **确认身份**的唯一出口（目录页不含 id）。
/// - 仓库每 3 小时更新；无 key、无配额。GitHub Git Trees API 被截断、Contents API
///   未登录 60 次/小时，都不能当主索引，所以目录只能抓 HTML。
///
/// 目录约 9 MB，解析结果落盘缓存 24 小时（[AjattCatalogCache]）；抓取与解析都在
/// [AjattClient] 里，provider 只消费模型。解析函数全是纯函数，测试用真实页面裁出的
/// fixture（`test/fixtures/ajatt/`）钉住 HTML 结构。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi/src/media/video/jimaku_client.dart'
    show detectSubtitleLanguage, parseSubtitleEpisode;
import 'package:http/http.dart' as http;

/// 站点根。
const String kAjattSiteBaseUrl = 'https://subtitles.ajatt.top/';

/// 镜像仓库 raw 根（作品目录 = `subtitles/<type>/<name>/`）。
const String kAjattRawBaseUrl =
    'https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/refs/heads/main/';

/// 作品分类（= 站点 `data-entry-type` / 仓库 `subtitles/` 下的一级目录名）。
enum AjattEntryType {
  animeTv('anime_tv'),
  animeMovie('anime_movie'),
  dramaTv('drama_tv'),
  dramaMovie('drama_movie'),
  unsorted('unsorted');

  const AjattEntryType(this.wireName);

  /// 站点/仓库里的目录名。
  final String wireName;

  /// 动画（含未分类：kitsunekko 老库大部分是动画，但没标记，不能排除）。
  bool get isAnime => this == animeTv || this == animeMovie || this == unsorted;

  /// 真人剧（含未分类，理由同上）。
  bool get isLiveAction =>
      this == dramaTv || this == dramaMovie || this == unsorted;

  static AjattEntryType? parse(String raw) {
    for (final AjattEntryType type in values) {
      if (type.wireName == raw) return type;
    }
    return null;
  }
}

/// 目录页里的一个作品条目。
class AjattCatalogEntry {
  const AjattCatalogEntry({
    required this.type,
    required this.pagePath,
    required this.name,
    required this.englishName,
    required this.japaneseName,
    required this.lastModifiedMs,
  });

  factory AjattCatalogEntry.fromJson(Map<String, Object?> json) {
    return AjattCatalogEntry(
      type:
          AjattEntryType.parse(json['type'] as String? ?? '') ??
          AjattEntryType.unsorted,
      pagePath: json['page'] as String? ?? '',
      name: json['name'] as String? ?? '',
      englishName: json['en'] as String? ?? '',
      japaneseName: json['ja'] as String? ?? '',
      lastModifiedMs: (json['mtime'] as num?)?.toInt() ?? 0,
    );
  }

  final AjattEntryType type;

  /// 作品页相对路径（`anime_tv/k-on!.html`），也是本条目的稳定 id。
  final String pagePath;

  /// 目录名 / 站点显示名（罗马音或英文，如 `K-ON!`）。同时是仓库里的目录名。
  final String name;

  /// 英文名（可空串）。
  final String englishName;

  /// 日文名（可空串）。
  final String japaneseName;

  /// 目录页 `data-timestamp`（epoch 秒 → 毫秒）。
  final int lastModifiedMs;

  /// 可搜标题（去空）。
  List<String> get searchTitles => <String>[
    name,
    englishName,
    japaneseName,
  ].where((String value) => value.trim().isNotEmpty).toList();

  /// 作品页绝对 URL。
  Uri pageUrl([String baseUrl = kAjattSiteBaseUrl]) =>
      Uri.parse(baseUrl).resolve(pagePath);

  /// 该作品目录下 `.kitsuinfo.json` 的 raw URL。目录名 = [name]（实测与
  /// `.kitsuinfo.json` 里的 `name` 一致）。
  Uri infoUrl([String rawBaseUrl = kAjattRawBaseUrl]) =>
      Uri.parse(rawBaseUrl).resolve(
        'subtitles/${type.wireName}/${Uri.encodeComponent(name)}/'
        '.kitsuinfo.json',
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type.wireName,
    'page': pagePath,
    'name': name,
    'en': englishName,
    'ja': japaneseName,
    'mtime': lastModifiedMs,
  };

  @override
  String toString() => 'AjattCatalogEntry(${type.wireName}, $name)';
}

/// 作品页文件表里的一个字幕文件。
class AjattSubtitleFile {
  const AjattSubtitleFile({
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.lastModifiedMs,
  });

  final String name;
  final String downloadUrl;
  final int? size;
  final int? lastModifiedMs;

  /// 扩展名（小写，不含点）。
  String get extension {
    final int dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// 可解析成 cue 的文本字幕（与 Jimaku 同一集合）。
  bool get isTextSubtitle =>
      const <String>{'srt', 'ass', 'ssa', 'vtt'}.contains(extension);

  /// 文件名启发式集号（与 Jimaku 共用解析器）。
  int? get episode => parseSubtitleEpisode(name);

  /// 文件名里显式标出的语言；认不出为 null。**站点是日语字幕库**，认不出时由
  /// provider 兜底成 `ja`（这里保持「事实」，不替它下结论）。
  String? get taggedLanguage => detectSubtitleLanguage(name);
}

/// `.kitsuinfo.json`。
class AjattEntryInfo {
  const AjattEntryInfo({
    required this.entryId,
    required this.name,
    required this.entryType,
    required this.englishName,
    required this.japaneseName,
    required this.anilistId,
  });

  final int? entryId;
  final String name;
  final String entryType;
  final String englishName;
  final String japaneseName;

  /// 缺失 / 非正整数为 null（= 该目录没标 AniList，不能据此确认也不能据此否定）。
  final int? anilistId;
}

/// 解析目录页（`index.html` / `drama.html`）。结构对不上时返回空列表——调用方据
/// 「两页都空」判定 `invalidResponse`，而不是把「0 作品」当成事实缓存 24 小时。
List<AjattCatalogEntry> parseAjattCatalogHtml(String html) {
  final List<AjattCatalogEntry> entries = <AjattCatalogEntry>[];
  for (final RegExpMatch row in _catalogRow.allMatches(html)) {
    final int timestamp = int.tryParse(row.group(1)!) ?? 0;
    final AjattEntryType? type = AjattEntryType.parse(row.group(2)!);
    if (type == null) continue;
    final String body = row.group(3)!;
    final RegExpMatch? link = _catalogLink.firstMatch(body);
    if (link == null) continue;
    entries.add(
      AjattCatalogEntry(
        type: type,
        pagePath: unescapeHtml(link.group(1)!),
        name: unescapeHtml(link.group(2)!).trim(),
        englishName: unescapeHtml(_cell(body, 'english_name')).trim(),
        japaneseName: unescapeHtml(_cell(body, 'japanese_name')).trim(),
        lastModifiedMs: timestamp * 1000,
      ),
    );
  }
  return entries;
}

/// 解析作品页文件表。srt / ass / all 三段会重复列同一文件，按下载 URL 去重、保持
/// 首次出现顺序。
List<AjattSubtitleFile> parseAjattEntryPageHtml(String html) {
  final Map<String, AjattSubtitleFile> byUrl = <String, AjattSubtitleFile>{};
  for (final RegExpMatch row in _fileRow.allMatches(html)) {
    final String url = unescapeHtml(row.group(3)!);
    if (byUrl.containsKey(url)) continue;
    byUrl[url] = AjattSubtitleFile(
      name: unescapeHtml(row.group(4)!),
      downloadUrl: url,
      size: int.tryParse(row.group(2)!),
      lastModifiedMs: (int.tryParse(row.group(1)!) ?? 0) * 1000,
    );
  }
  return byUrl.values.toList();
}

/// 解析 `.kitsuinfo.json`；不是对象 / 解析失败 → null。
AjattEntryInfo? parseAjattEntryInfoJson(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  int? positiveInt(Object? value) {
    final int? parsed = value is int ? value : int.tryParse('${value ?? ''}');
    return parsed == null || parsed <= 0 ? null : parsed;
  }

  return AjattEntryInfo(
    entryId: positiveInt(decoded['entry_id']),
    name: decoded['name'] as String? ?? '',
    entryType: decoded['entry_type'] as String? ?? '',
    englishName: decoded['english_name'] as String? ?? '',
    japaneseName: decoded['japanese_name'] as String? ?? '',
    anilistId: positiveInt(decoded['anilist_id']),
  );
}

/// 常见 HTML 实体反转义（命名 + 十进制 + 十六进制）。站点把标题原样写进 HTML，
/// 只有 `&amp;` / `&#39;` 这几种会出现；未知实体原样保留。
String unescapeHtml(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(_entity, (Match match) {
    final String body = match.group(1)!;
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      case 'nbsp':
        return ' ';
    }
    if (body.startsWith('#x') || body.startsWith('#X')) {
      final int? code = int.tryParse(body.substring(2), radix: 16);
      return code == null ? match.group(0)! : String.fromCharCode(code);
    }
    if (body.startsWith('#')) {
      final int? code = int.tryParse(body.substring(1));
      return code == null ? match.group(0)! : String.fromCharCode(code);
    }
    return match.group(0)!;
  });
}

String _cell(String rowBody, String className) {
  final RegExpMatch? match = RegExp(
    'class="$className">(.*?)</td>',
    dotAll: true,
  ).firstMatch(rowBody);
  return match == null ? '' : _stripTags(match.group(1)!);
}

String _stripTags(String html) => html.replaceAll(RegExp('<[^>]*>'), '');

final RegExp _catalogRow = RegExp(
  r'<tr data-timestamp="(\d+)" data-entry-type="([a-z_]+)">(.*?)</tr>',
  dotAll: true,
);
// `unsorted` 行的名字格是 `class="entry_name missing_meta"`（带 colspan，没有英/日文名
// 两格），class 只能按前缀匹配，否则 400 多条未分类作品整体漏掉。
final RegExp _catalogLink = RegExp(
  r'class="entry_name[^"]*"><a href="([^"]+)">(.*?)</a>',
  dotAll: true,
);
final RegExp _fileRow = RegExp(
  r'<tr data-timestamp="(\d+)" data-file-size="(\d+)">.*?'
  r'data-download-url="([^"]+)" data-filename="([^"]+)"',
  dotAll: true,
);
final RegExp _entity = RegExp('&(#?[A-Za-z0-9]+);');

/// 目录快照的磁盘缓存：`{fetchedAt, entries}` 一个 JSON 文件，TTL 默认 24 小时
/// （站点每 3 小时更新，但每次搜索拉 9 MB 不可接受；一天一次是折中）。
class AjattCatalogCache {
  AjattCatalogCache({
    required this.file,
    this.ttl = const Duration(hours: 24),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final File file;
  final Duration ttl;
  final DateTime Function() _now;

  /// 未过期的缓存条目；无缓存 / 过期 / 损坏 → null。
  Future<List<AjattCatalogEntry>?> readFresh() async {
    if (!await file.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      final int fetchedAt = (decoded['fetchedAt'] as num?)?.toInt() ?? 0;
      final int age = _now().millisecondsSinceEpoch - fetchedAt;
      if (age < 0 || age > ttl.inMilliseconds) return null;
      final Object? rows = decoded['entries'];
      if (rows is! List<Object?>) return null;
      return <AjattCatalogEntry>[
        for (final Object? row in rows)
          if (row is Map<String, Object?>) AjattCatalogEntry.fromJson(row),
      ];
    } on Object {
      return null;
    }
  }

  Future<void> write(List<AjattCatalogEntry> entries) async {
    await file.parent.create(recursive: true);
    // 先写临时文件再改名：解析到一半断电不留半个 JSON 让下次 readFresh 空转。
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, Object?>{
        'fetchedAt': _now().millisecondsSinceEpoch,
        'entries': <Object?>[
          for (final AjattCatalogEntry e in entries) e.toJson(),
        ],
      }),
    );
    await tmp.rename(file.path);
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

/// AJATT 请求失败（HTTP 非 2xx / 结构对不上）。[statusCode] null = 结构问题。
class AjattRequestException implements Exception {
  const AjattRequestException(this.operation, {this.statusCode});

  final String operation;
  final int? statusCode;

  @override
  String toString() =>
      'AjattRequestException($operation, status=${statusCode ?? 'invalid'})';
}

/// 抓站点 + raw 仓库的客户端。目录走内存 → 磁盘缓存 → 网络三级；作品页与
/// `.kitsuinfo.json` 每次现拉（一次搜索最多几次，量很小）。
class AjattClient {
  AjattClient({
    required http.Client client,
    this.cache,
    this.siteBaseUrl = kAjattSiteBaseUrl,
    this.rawBaseUrl = kAjattRawBaseUrl,
    bool closesClient = false,
    bool parseInIsolate = true,
  }) : _client = client,
       _closesClient = closesClient,
       _parseInIsolate = parseInIsolate;

  final http.Client _client;
  final bool _closesClient;
  final bool _parseInIsolate;
  final AjattCatalogCache? cache;
  final String siteBaseUrl;
  final String rawBaseUrl;

  List<AjattCatalogEntry>? _memo;
  Future<List<AjattCatalogEntry>>? _inflight;

  /// 目录（动画 + 真人剧两页合并）。并发调用共享同一次抓取。
  Future<List<AjattCatalogEntry>> loadCatalog({bool forceRefresh = false}) {
    if (!forceRefresh && _memo != null) return Future.value(_memo);
    return _inflight ??= _loadCatalog(forceRefresh).whenComplete(() {
      _inflight = null;
    });
  }

  Future<List<AjattCatalogEntry>> _loadCatalog(bool forceRefresh) async {
    if (!forceRefresh) {
      final List<AjattCatalogEntry>? cached = await cache?.readFresh();
      if (cached != null && cached.isNotEmpty) return _memo = cached;
    }
    final List<String> pages = await Future.wait(<Future<String>>[
      _getText(Uri.parse(siteBaseUrl).resolve('index.html'), 'catalog'),
      _getText(Uri.parse(siteBaseUrl).resolve('drama.html'), 'catalog'),
    ]);
    final List<AjattCatalogEntry> entries = _parseInIsolate
        ? await Isolate.run(() => _parseCatalogPages(pages))
        : _parseCatalogPages(pages);
    if (entries.isEmpty) {
      // 两页都解析不出一行：站点改版了。不缓存，让下次还能重试。
      throw const AjattRequestException('catalog');
    }
    await cache?.write(entries);
    return _memo = entries;
  }

  /// 作品页文件表（已按 URL 去重，含非文本字幕，由调用方过滤）。
  Future<List<AjattSubtitleFile>> listEntryFiles(
    AjattCatalogEntry entry,
  ) async {
    final String html = await _getText(entry.pageUrl(siteBaseUrl), 'entry');
    final List<AjattSubtitleFile> files = parseAjattEntryPageHtml(html);
    if (files.isEmpty && !html.contains('file_list_table')) {
      throw const AjattRequestException('entry');
    }
    return files;
  }

  /// `.kitsuinfo.json`；目录没有这个文件（404）→ null，其它错误照抛。
  Future<AjattEntryInfo?> fetchEntryInfo(AjattCatalogEntry entry) async {
    final http.Response response = await _client.get(entry.infoUrl(rawBaseUrl));
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AjattRequestException('info', statusCode: response.statusCode);
    }
    return parseAjattEntryInfoJson(utf8.decode(response.bodyBytes));
  }

  Future<Uint8List> download(String url) async {
    final http.Response response = await _client.get(Uri.parse(url));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AjattRequestException('download', statusCode: response.statusCode);
    }
    return response.bodyBytes;
  }

  Future<String> _getText(Uri url, String operation) async {
    final http.Response response = await _client.get(url);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AjattRequestException(operation, statusCode: response.statusCode);
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  void close() {
    if (_closesClient) _client.close();
  }
}

List<AjattCatalogEntry> _parseCatalogPages(List<String> pages) =>
    <AjattCatalogEntry>[
      for (final String page in pages) ...parseAjattCatalogHtml(page),
    ];
