import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Jimaku（jimaku.cc）字幕条目：一个番剧/作品。
class JimakuEntry {
  const JimakuEntry({
    required this.id,
    required this.name,
    this.anilistId,
  });

  final int id;
  final String name;
  final int? anilistId;
}

/// Jimaku 条目下的一个字幕文件。
class JimakuFile {
  const JimakuFile({
    required this.name,
    required this.url,
    this.size,
  });

  final String name;
  final String url;
  final int? size;

  /// 文件扩展名（小写，不含点）；用于选解析器（srt/ass/vtt）。
  String get extension {
    final int dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// 是否可解析成 cue 的文本字幕（srt/ass/ssa/vtt）。
  bool get isTextSubtitle =>
      const <String>{'srt', 'ass', 'ssa', 'vtt'}.contains(extension);
}

/// 解析 Jimaku entries 响应（JSON 数组）为 [JimakuEntry] 列表。纯函数，容错。
List<JimakuEntry> parseJimakuEntries(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) return const <JimakuEntry>[];
    final List<JimakuEntry> out = <JimakuEntry>[];
    for (final dynamic e in json) {
      if (e is! Map) continue;
      final dynamic id = e['id'];
      if (id is! int) continue;
      out.add(JimakuEntry(
        id: id,
        name:
            (e['name'] as String?) ?? (e['english_name'] as String?) ?? '#$id',
        anilistId: e['anilist_id'] as int?,
      ));
    }
    return out;
  } catch (_) {
    return const <JimakuEntry>[];
  }
}

/// 从字幕文件名识别语言代码（客户端启发式，Jimaku 无服务端语言过滤）。纯函数。
///
/// 识别两类信号，认不出一律返回 `null`（= 未知语言，绝不猜错、绝不藏候选）：
/// 1. `*.<lang>.<ext>` 倒数第二段的语言后缀（asbplayer 同款），如 `ep01.ja.srt`；
/// 2. 文件名里明确的语言标记，如 `[CHS]` / `简体` / `日本語` / `[JP]`。
///
/// 归一到大类语言代码：`ja` / `zh` / `en` / `ko`。其它/认不出 → `null`。
String? detectSubtitleLanguage(String fileName) {
  final String lower = fileName.toLowerCase();

  // ① 倒数第二段后缀（`name.<lang>.<ext>`）。
  final List<String> parts = fileName.split('.');
  if (parts.length >= 3) {
    final String? byTag = _languageFromToken(parts[parts.length - 2]);
    if (byTag != null) return byTag;
  }

  // ② 文件名里的显式语言标记（保守：只认明确标记）。
  const Map<String, String> markers = <String, String>{
    '日本語': 'ja',
    '日语': 'ja',
    '简体': 'zh',
    '簡体': 'zh',
    '繁體': 'zh',
    '繁体': 'zh',
    '中文': 'zh',
    '英語': 'en',
    '英语': 'en',
    '한국어': 'ko',
  };
  for (final MapEntry<String, String> e in markers.entries) {
    if (fileName.contains(e.key)) return e.value;
  }
  // 方括号 / 圆括号语言标记，如 [JP] / [CHS] / (ENG)。
  for (final RegExpMatch m
      in RegExp(r'[\[\(]([a-z\-]{2,5})[\]\)]').allMatches(lower)) {
    final String? byBracket = _languageFromToken(m.group(1)!);
    if (byBracket != null) return byBracket;
  }
  return null;
}

/// 把单个语言 token（如 `ja`/`chs`/`zh-cn`）归一到大类代码；认不出返回 `null`。
String? _languageFromToken(String rawToken) {
  final String token = rawToken.trim().toLowerCase();
  if (token.isEmpty) return null;
  const Map<String, String> table = <String, String>{
    'ja': 'ja',
    'jpn': 'ja',
    'jp': 'ja',
    'zh': 'zh',
    'zho': 'zh',
    'chi': 'zh',
    'chs': 'zh',
    'cht': 'zh',
    'sc': 'zh',
    'tc': 'zh',
    'en': 'en',
    'eng': 'en',
    'ko': 'ko',
    'kor': 'ko',
  };
  // 先整 token 命中（保留 chs/cht 这种连体码），再退到连字符前的主标签
  // （zh-cn → zh，pt-br → pt）。
  final String? whole = table[token];
  if (whole != null) return whole;
  return table[token.split('-').first];
}

/// 解析 Jimaku files 响应（JSON 数组）为 [JimakuFile] 列表。纯函数，容错。
List<JimakuFile> parseJimakuFiles(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) return const <JimakuFile>[];
    final List<JimakuFile> out = <JimakuFile>[];
    for (final dynamic f in json) {
      if (f is! Map) continue;
      final dynamic name = f['name'];
      final dynamic url = f['url'];
      if (name is! String || url is! String) continue;
      out.add(JimakuFile(
        name: name,
        url: url,
        size: f['size'] is int ? f['size'] as int : null,
      ));
    }
    return out;
  } catch (_) {
    return const <JimakuFile>[];
  }
}

/// 构造 `/api/entries/<id>/files` 请求 URI。纯函数，便于单测断言 episode 拼参。
///
/// [episode] 非空时附 `episode=<n>`，否则 URI 不带任何 query（= 旧行为）。
Uri buildListFilesUri(String base, int entryId, {int? episode}) {
  final Uri uri = Uri.parse('$base/entries/$entryId/files');
  if (episode == null) return uri;
  return uri.replace(queryParameters: <String, String>{'episode': '$episode'});
}

/// Jimaku API 客户端（参照 asbplayer 的 Jimaku 集成）。需用户在设置/对话框填 API key。
///
/// 端点：`/api/entries/search`（按 anilist_id 或 query 搜条目）、`/api/entries/<id>/files`
/// （列文件）、文件 `url` 直接下载。鉴权头 `Authorization: <apiKey>`。
class JimakuClient {
  JimakuClient({required this.apiKey, http.Client? client})
      : _client = client ?? http.Client();

  final String apiKey;
  final http.Client _client;

  static const String _base = 'https://jimaku.cc/api';

  Map<String, String> get _headers => <String, String>{
        'Authorization': apiKey,
        'Accept': 'application/json',
      };

  /// 按 AniList id 搜 Jimaku 条目。
  Future<List<JimakuEntry>> searchByAnilistId(int anilistId) async {
    return _searchEntries(<String, String>{'anilist_id': '$anilistId'});
  }

  /// 按文本搜 Jimaku 条目（AniList 匹配不到时的回退）。
  Future<List<JimakuEntry>> searchByQuery(String query) async {
    if (query.trim().isEmpty) return const <JimakuEntry>[];
    return _searchEntries(<String, String>{'query': query});
  }

  Future<List<JimakuEntry>> _searchEntries(Map<String, String> params) async {
    try {
      final Uri uri =
          Uri.parse('$_base/entries/search').replace(queryParameters: params);
      final http.Response res = await _client.get(uri, headers: _headers);
      if (res.statusCode != 200) return const <JimakuEntry>[];
      return parseJimakuEntries(res.body);
    } catch (_) {
      return const <JimakuEntry>[];
    }
  }

  /// 列某条目下的字幕文件。
  ///
  /// [episode] 非空时附 `episode=<n>` query，由 Jimaku 服务端**按文件名启发式**只返回
  /// 匹配该集的文件（文档原文：best-effort guess based off filename matching）；为空时
  /// 不带该 query，行为 = 旧路径（列全部文件，向后兼容）。
  Future<List<JimakuFile>> listFiles(int entryId, {int? episode}) async {
    try {
      final Uri uri = buildListFilesUri(_base, entryId, episode: episode);
      final http.Response res = await _client.get(uri, headers: _headers);
      if (res.statusCode != 200) return const <JimakuFile>[];
      return parseJimakuFiles(res.body);
    } catch (_) {
      return const <JimakuFile>[];
    }
  }

  /// 下载 [fileUrl] 的字节；失败返回 null。
  Future<Uint8List?> downloadFile(String fileUrl) async {
    try {
      final http.Response res =
          await _client.get(Uri.parse(fileUrl), headers: _headers);
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}
