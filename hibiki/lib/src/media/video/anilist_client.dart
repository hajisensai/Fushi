import 'dart:convert';

import 'package:http/http.dart' as http;

/// AniList 媒体（番剧）搜索结果的最小模型。
class AniListMedia {
  const AniListMedia({
    required this.id,
    this.romaji,
    this.english,
    this.native,
  });

  /// AniList 媒体 id（用于到 Jimaku 按 anilist_id 查字幕）。
  final int id;
  final String? romaji;
  final String? english;
  final String? native;

  /// 菜单显示用标题：优先罗马字 → 英文 → 日文 → id。
  String get displayTitle => (romaji?.isNotEmpty ?? false)
      ? romaji!
      : (english?.isNotEmpty ?? false)
          ? english!
          : (native?.isNotEmpty ?? false)
              ? native!
              : 'AniList #$id';
}

/// 解析 AniList GraphQL 搜索响应为 [AniListMedia] 列表。纯函数，容错（结构不符 →
/// 空列表），便于单测。
List<AniListMedia> parseAniListSearchResponse(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! Map) return const <AniListMedia>[];
    final dynamic data = json['data'];
    if (data is! Map) return const <AniListMedia>[];
    final dynamic page = data['Page'];
    if (page is! Map) return const <AniListMedia>[];
    final dynamic media = page['media'];
    if (media is! List) return const <AniListMedia>[];
    final List<AniListMedia> out = <AniListMedia>[];
    for (final dynamic m in media) {
      if (m is! Map) continue;
      final dynamic id = m['id'];
      if (id is! int) continue;
      final dynamic title = m['title'];
      out.add(AniListMedia(
        id: id,
        romaji: title is Map ? title['romaji'] as String? : null,
        english: title is Map ? title['english'] as String? : null,
        native: title is Map ? title['native'] as String? : null,
      ));
    }
    return out;
  } catch (_) {
    return const <AniListMedia>[];
  }
}

/// AniList GraphQL 客户端：按标题搜番拿 anilist id（Jimaku 按 anilist_id 查字幕的前置）。
class AniListClient {
  AniListClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _endpoint = 'https://graphql.anilist.co';
  static const String _searchQuery = r'''
query ($search: String) {
  Page(perPage: 10) {
    media(search: $search, type: ANIME) {
      id
      title { romaji english native }
    }
  }
}''';

  /// 按 [title] 搜索番剧。网络/解析失败返回空列表（不抛，调用方按空处理）。
  Future<List<AniListMedia>> searchAnime(String title) async {
    if (title.trim().isEmpty) return const <AniListMedia>[];
    try {
      final http.Response res = await _client.post(
        Uri.parse(_endpoint),
        headers: const <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'query': _searchQuery,
          'variables': <String, dynamic>{'search': title},
        }),
      );
      if (res.statusCode != 200) return const <AniListMedia>[];
      return parseAniListSearchResponse(res.body);
    } catch (_) {
      return const <AniListMedia>[];
    }
  }

  void close() => _client.close();
}
