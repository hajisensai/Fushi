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
  Future<List<JimakuFile>> listFiles(int entryId) async {
    try {
      final Uri uri = Uri.parse('$_base/entries/$entryId/files');
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
