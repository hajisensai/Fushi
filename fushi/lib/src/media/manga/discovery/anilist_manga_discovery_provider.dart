/// AniList 漫画发现数据源：一次匿名 GraphQL combined query 拿全部四条 feed。
///
/// 传输层复用视频元数据域的 [VideoMetadataHttpClient]——它是通用的只读 HTTP
/// 客户端（超时/退避/429/内存缓存），没有任何视频专属逻辑；为一个域再抄一份
/// 才是错的。查询无需登录，与视频域的 AniList provider 同一公开端点。
library;

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_json.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';

class AniListMangaDiscoveryProvider implements MangaDiscoveryProvider {
  AniListMangaDiscoveryProvider({
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.endpoint = 'https://graphql.anilist.co',
  })  : assert(client == null || transport == null),
        _transport = transport ?? VideoMetadataHttpClient(client: client),
        _ownsTransport = transport == null;

  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final String endpoint;

  /// 四条 feed 一条请求打包（对齐 AnymeX 的 combined query 做法）：发现页打开
  /// 只产生一次网络往返，条目字段用 fragment 收敛成一份。
  ///
  /// - `topRated` / `latestFinished` 带人气/评分下限：裸 `SCORE_DESC` 前排全是
  ///   几十人打分的冷门条目，对「发现」毫无价值。
  /// - 全部 `isAdult: false`。
  static const String _combinedQuery = r'''
query ($perPage: Int!) {
  trending: Page(page: 1, perPage: $perPage) {
    media(sort: TRENDING_DESC, type: MANGA, isAdult: false) { ...entry }
  }
  popular: Page(page: 1, perPage: $perPage) {
    media(sort: POPULARITY_DESC, type: MANGA, isAdult: false) { ...entry }
  }
  topRated: Page(page: 1, perPage: $perPage) {
    media(sort: SCORE_DESC, popularity_greater: 10000, type: MANGA,
          isAdult: false) { ...entry }
  }
  latestFinished: Page(page: 1, perPage: $perPage) {
    media(status: FINISHED, sort: [END_DATE_DESC, SCORE_DESC, POPULARITY_DESC],
          averageScore_greater: 70, popularity_greater: 10000, type: MANGA,
          isAdult: false) { ...entry }
  }
}

fragment entry on Media {
  id
  title { native romaji english }
  synonyms
  coverImage { extraLarge large }
  averageScore
  description(asHtml: false)
  genres
  status
  chapters
  countryOfOrigin
}
''';

  static const Map<MangaDiscoveryFeed, String> _feedAliases =
      <MangaDiscoveryFeed, String>{
    MangaDiscoveryFeed.trending: 'trending',
    MangaDiscoveryFeed.popular: 'popular',
    MangaDiscoveryFeed.topRated: 'topRated',
    MangaDiscoveryFeed.latestFinished: 'latestFinished',
  };

  @override
  Future<MangaDiscoverySnapshot> fetchSnapshot({int perPage = 20}) async {
    final VideoMetadataHttpResponse response = await _transport.postJson(
      Uri.parse(endpoint),
      headers: const <String, String>{'Accept': 'application/json'},
      body: <String, Object?>{
        'query': _combinedQuery,
        'variables': <String, Object?>{'perPage': perPage.clamp(1, 50)},
      },
      operation: 'AniList manga discovery',
      cacheKey: 'anilist:manga-discovery:$perPage',
    );
    final Map<String, Object?> payload =
        response.decodeJsonObject(operation: 'AniList manga discovery');
    final List<Object?> errors = metadataList(payload['errors']);
    if (errors.isNotEmpty) {
      final String message =
          metadataString(metadataObject(errors.first)?['message']) ??
              '${errors.first}';
      throw VideoMetadataNetworkException(
        'AniList manga discovery GraphQL error: $message',
      );
    }
    final Map<String, Object?> data =
        metadataObject(payload['data']) ?? const <String, Object?>{};
    final Map<MangaDiscoveryFeed, List<MangaDiscoveryEntry>> feeds =
        <MangaDiscoveryFeed, List<MangaDiscoveryEntry>>{};
    final Set<int> seenPerFeed = <int>{};
    for (final MapEntry<MangaDiscoveryFeed, String> alias
        in _feedAliases.entries) {
      seenPerFeed.clear();
      final List<MangaDiscoveryEntry> entries = <MangaDiscoveryEntry>[];
      final Map<String, Object?>? page = metadataObject(data[alias.value]);
      for (final Object? node in metadataList(page?['media'])) {
        final MangaDiscoveryEntry? entry = _mapEntry(metadataObject(node));
        if (entry != null && seenPerFeed.add(entry.anilistId)) {
          entries.add(entry);
        }
      }
      feeds[alias.key] = entries;
    }
    return MangaDiscoverySnapshot(feeds: feeds);
  }

  MangaDiscoveryEntry? _mapEntry(Map<String, Object?>? item) {
    if (item == null) return null;
    final int? id = metadataInt(item['id']);
    if (id == null) return null;
    final Map<String, Object?> titles =
        metadataObject(item['title']) ?? const <String, Object?>{};
    final Map<String, Object?> cover =
        metadataObject(item['coverImage']) ?? const <String, Object?>{};
    final int? rawScore = metadataInt(item['averageScore']);
    return MangaDiscoveryEntry(
      anilistId: id,
      titleNative: metadataString(titles['native']),
      titleRomaji: metadataString(titles['romaji']),
      titleEnglish: metadataString(titles['english']),
      synonyms: <String>[
        for (final Object? synonym in metadataList(item['synonyms']))
          if (metadataString(synonym) != null) metadataString(synonym)!,
      ],
      coverUrl:
          metadataString(cover['extraLarge']) ?? metadataString(cover['large']),
      averageScore: rawScore == null ? null : rawScore / 10,
      description: metadataStripHtml(metadataString(item['description'])),
      genres: <String>[
        for (final Object? genre in metadataList(item['genres']))
          if (metadataString(genre) != null) metadataString(genre)!,
      ],
      status: metadataString(item['status']),
      chapters: metadataInt(item['chapters']),
      countryOfOrigin: metadataString(item['countryOfOrigin']),
    );
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}
