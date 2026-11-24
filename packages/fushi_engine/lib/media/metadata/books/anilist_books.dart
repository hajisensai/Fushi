/// AniList 书目（GraphQL `https://graphql.anilist.co`，`type: MANGA`：轻小说、漫画、
/// 韩漫、国漫、短篇都在这个类型里）。
///
/// 以前搜索写死 `format: NOVEL`，漫画在这个源永远搜不到（BUG-5378）；现在不限形态，
/// 每条带 [BookCatalogRecord.format]，弹窗写明是轻小说还是漫画。
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
id siteUrl isAdult bannerImage format countryOfOrigin
title { romaji english native }
coverImage { extraLarge large }
startDate { year }
description(asHtml: false)
staff(perPage: 12) { edges { role node { name { full native } } } }
''';

/// 按名搜（不限形态，按匹配度排）。[includeAdult] 为 false 时在服务端就排除
/// `isAdult` 条目（`isAdult: false`），一页结果不会被成人向条目占掉名额；为 true 时
/// 不带这个过滤（AniList 默认两者都回）。
String aniListBookSearchQuery({required bool includeAdult}) =>
    r'query ($search: String, $perPage: Int) { Page(perPage: $perPage) { '
    r'media(search: $search, type: MANGA, sort: SEARCH_MATCH'
    '${includeAdult ? '' : ', isAdult: false'}) { '
    '$_mediaFields} } }';

/// 按 id 直取（不限 format：用户贴的 id 是什么就是什么）。
const String kAniListMediaByIdQuery =
    r'query ($id: Int) { Media(id: $id, type: MANGA) { '
    '$_mediaFields} }';

/// AniList 书目客户端。
class AniListBookClient {
  AniListBookClient(this._http);

  final BookCatalogHttp _http;

  /// 按名搜。[includeAdult] 默认 false = 不要成人向条目（见
  /// [aniListBookSearchQuery]）。失败抛 [BookCatalogException]。
  Future<List<BookCatalogRecord>> search(
    String query, {
    int limit = 10,
    bool includeAdult = false,
  }) async {
    final String term = query.trim();
    if (term.isEmpty) return const <BookCatalogRecord>[];
    final BookCatalogResponse res = await _http.postJson(
      kAniListGraphQlEndpoint,
      <String, Object?>{
        'query': aniListBookSearchQuery(includeAdult: includeAdult),
        'variables': <String, Object?>{'search': term, 'perPage': limit},
      },
    );
    _throwIfError(res, 'search');
    return parseAniListSearchResponse(res.body);
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
List<BookCatalogRecord> parseAniListSearchResponse(String body) {
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
    format: aniListFormat(
      catalogString(media['format']),
      catalogString(media['countryOfOrigin']),
    ),
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

/// AniList `format` + `countryOfOrigin` → [BookCatalogFormat]：`MANGA` 再按出版国分
/// 漫画 / 韩漫（KR）/ 国漫（CN、TW、HK）。认不出返回 null。
BookCatalogFormat? aniListFormat(String? format, String? countryOfOrigin) =>
    switch (format) {
      'NOVEL' => BookCatalogFormat.novel,
      'ONE_SHOT' => BookCatalogFormat.oneShot,
      'MANGA' => switch (countryOfOrigin) {
        'KR' => BookCatalogFormat.manhwa,
        'CN' || 'TW' || 'HK' => BookCatalogFormat.manhua,
        _ => BookCatalogFormat.manga,
      },
      _ => null,
    };

Map<String, Object?> _map(Object? v) =>
    v is Map<String, Object?> ? v : const <String, Object?>{};
