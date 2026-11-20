/// AniList 轻小说（GraphQL `https://graphql.anilist.co`，`type: MANGA, format: NOVEL`）。
///
/// 免 key。限流见 [kBookCatalogMinIntervals]。映射：标题取日文原名（native），罗马字
/// 作「原名」位；作者取 staff 里 role 为 `Story` / `Original Story` / `Story & Art`
/// 的人（优先日文名）；封面 `coverImage.extraLarge`；横幅 `bannerImage`。
library;

import 'dart:convert';

import 'package:fushi_engine/media/metadata/books/book_catalog.dart';

/// AniList GraphQL 端点。
final Uri kAniListGraphQlEndpoint = Uri.parse('https://graphql.anilist.co');

const String _mediaFields = '''
id siteUrl isAdult bannerImage
title { romaji english native }
coverImage { extraLarge large }
startDate { year }
description(asHtml: false)
staff(perPage: 12) { edges { role node { name { full native } } } }
''';

/// 搜轻小说（只要 NOVEL 形态）。
const String kAniListNovelSearchQuery =
    r'query ($search: String, $perPage: Int) { Page(perPage: $perPage) { '
    r'media(search: $search, type: MANGA, format: NOVEL, sort: SEARCH_MATCH) { '
    '$_mediaFields} } }';

/// 按 id 直取（不限 format：用户贴的 id 是什么就是什么）。
const String kAniListMediaByIdQuery =
    r'query ($id: Int) { Media(id: $id, type: MANGA) { '
    '$_mediaFields} }';

/// AniList 轻小说客户端。
class AniListNovelClient {
  AniListNovelClient(this._http);

  final BookCatalogHttp _http;

  /// 按名搜。失败抛 [BookCatalogException]。
  Future<List<BookCatalogRecord>> search(String query, {int limit = 10}) async {
    final String term = query.trim();
    if (term.isEmpty) return const <BookCatalogRecord>[];
    final BookCatalogResponse res = await _http.postJson(
      kAniListGraphQlEndpoint,
      <String, Object?>{
        'query': kAniListNovelSearchQuery,
        'variables': <String, Object?>{'search': term, 'perPage': limit},
      },
    );
    _throwIfError(res, 'search');
    return parseAniListNovelSearchResponse(res.body);
  }

  /// 按 media id 直取；查无此条（AniList 回 404）/ 无封面返回 null。
  Future<BookCatalogRecord?> fetchById(String id) async {
    final int? mediaId = int.tryParse(id.trim());
    if (mediaId == null) return null;
    final BookCatalogResponse res = await _http.postJson(
      kAniListGraphQlEndpoint,
      <String, Object?>{
        'query': kAniListMediaByIdQuery,
        'variables': <String, Object?>{'id': mediaId},
      },
    );
    if (res.statusCode == 404) return null;
    _throwIfError(res, 'media');
    return parseAniListMediaResponse(res.body);
  }

  static void _throwIfError(BookCatalogResponse res, String what) {
    if (res.isOk) return;
    throw BookCatalogException(
      'AniList $what HTTP ${res.statusCode}',
      statusCode: res.statusCode,
    );
  }
}

/// 从 `anilist.co/manga/<id>` / `anilist.co/novel/<id>` 链接里取 media id。
String? parseAniListMediaUrl(String text) {
  final RegExpMatch? m = RegExp(
    r'anilist\.co/(?:manga|novel)/(\d+)',
  ).firstMatch(text);
  return m?.group(1);
}

/// 纯函数：解析 `Page.media` 搜索响应。结构不对当空结果；JSON 解码失败或 GraphQL
/// 报错抛 [BookCatalogException]。
List<BookCatalogRecord> parseAniListNovelSearchResponse(String body) {
  final Map<String, Object?> data = _decodeData(body);
  final Object? page = data['Page'];
  final Object? media = page is Map<String, Object?> ? page['media'] : null;
  if (media is! List<Object?>) return const <BookCatalogRecord>[];
  return <BookCatalogRecord>[
    for (final Object? m in media)
      if (m is Map<String, Object?>) ?mapAniListMedia(m),
  ];
}

/// 纯函数：解析 `Media(id:)` 响应；无此条 / 无封面返回 null。
BookCatalogRecord? parseAniListMediaResponse(String body) {
  final Object? media = _decodeData(body)['Media'];
  return media is Map<String, Object?> ? mapAniListMedia(media) : null;
}

Map<String, Object?> _decodeData(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw BookCatalogException('AniList malformed JSON: ${e.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw const BookCatalogException('AniList response is not an object');
  }
  final Object? errors = decoded['errors'];
  final Object? data = decoded['data'];
  if (errors is List<Object?> && errors.isNotEmpty && data is! Map) {
    final Object? first = errors.first;
    final String message = first is Map<String, Object?>
        ? '${first['message']}'
        : '$first';
    final Object? status = first is Map<String, Object?>
        ? first['status']
        : null;
    throw BookCatalogException(
      'AniList GraphQL error: $message',
      statusCode: status is int ? status : null,
    );
  }
  return data is Map<String, Object?> ? data : const <String, Object?>{};
}

/// AniList staff role 里算「作者」的：`Story` / `Original Story` / `Story & Art` /
/// `Original Creator`（role 后面可能挂 ` (vol 1-3)` 之类括注）。
final RegExp _authorRole = RegExp(
  r'^(original\s+)?(story|creator)(\s*&\s*art)?\b',
  caseSensitive: false,
);

/// 把单条 AniList media 映射成 [BookCatalogRecord]；无标题 / 无封面返回 null。
BookCatalogRecord? mapAniListMedia(Map<String, Object?> media) {
  final Object? rawId = media['id'];
  if (rawId is! int) return null;
  final Map<String, Object?> title = _map(media['title']);
  final String? native = catalogString(title['native']);
  final String? romaji = catalogString(title['romaji']);
  final String? english = catalogString(title['english']);
  final String? main = native ?? romaji ?? english;
  if (main == null) return null;
  final String? alt = <String?>[
    romaji,
    english,
  ].firstWhere((String? s) => s != null && s != main, orElse: () => null);
  final Map<String, Object?> cover = _map(media['coverImage']);
  final String? coverUrl =
      catalogString(cover['extraLarge']) ?? catalogString(cover['large']);
  if (coverUrl == null) return null;

  final List<String> authors = <String>[];
  final Object? edges = _map(media['staff'])['edges'];
  if (edges is List<Object?>) {
    for (final Object? e in edges) {
      if (e is! Map<String, Object?>) continue;
      final String? role = catalogString(e['role']);
      if (role == null || !_authorRole.hasMatch(role)) continue;
      final Map<String, Object?> name = _map(_map(e['node'])['name']);
      final String? who =
          catalogString(name['native']) ?? catalogString(name['full']);
      if (who != null && !authors.contains(who)) authors.add(who);
    }
  }
  final Object? year = _map(media['startDate'])['year'];
  return BookCatalogRecord(
    id: '$rawId',
    title: main,
    originalTitle: alt,
    author: authors.isEmpty ? null : authors.join(', '),
    year: year is int ? year : null,
    summary: catalogStripHtml(catalogString(media['description'])),
    coverUrl: coverUrl,
    bannerUrl: catalogString(media['bannerImage']),
    pageUrl:
        catalogString(media['siteUrl']) ?? 'https://anilist.co/manga/$rawId',
    isAdult: media['isAdult'] == true,
  );
}

Map<String, Object?> _map(Object? v) =>
    v is Map<String, Object?> ? v : const <String, Object?>{};
