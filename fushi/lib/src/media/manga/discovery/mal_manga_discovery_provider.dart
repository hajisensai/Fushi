/// MAL 漫画发现：通过 Jikan v4 只读接口获取四条内容行。
library;

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_json.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';

class MalMangaDiscoveryProvider implements MangaDiscoveryProvider {
  MalMangaDiscoveryProvider({
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.endpoint = 'https://api.jikan.moe/v4',
    MalVideoMetadataRequestGate? requestGate,
  })  : assert(client == null || transport == null),
        _transport = transport ??
            VideoMetadataHttpClient(client: client, maxAttempts: 1),
        _ownsTransport = transport == null,
        _gate = requestGate ?? MalVideoMetadataProvider.sharedRequestGate {
    if (_transport.maxAttempts != 1) {
      throw ArgumentError('MAL transport must use maxAttempts: 1');
    }
  }

  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final MalVideoMetadataRequestGate _gate;
  final String endpoint;

  // Jikan 没有趋势榜；以连载中作品的收藏人数排序提供「连载热门」。
  static const Map<MangaDiscoveryFeed, Map<String, String>> _queries =
      <MangaDiscoveryFeed, Map<String, String>>{
    MangaDiscoveryFeed.publishing: <String, String>{
      'status': 'publishing',
      'order_by': 'members',
    },
    MangaDiscoveryFeed.popular: <String, String>{'order_by': 'members'},
    MangaDiscoveryFeed.topRated: <String, String>{'order_by': 'score'},
    MangaDiscoveryFeed.latestFinished: <String, String>{
      'status': 'complete',
      'order_by': 'end_date',
      'min_score': '7',
    },
  };

  @override
  Future<MangaDiscoverySnapshot> fetchSnapshot({int perPage = 20}) async {
    final Map<MangaDiscoveryFeed, List<MangaDiscoveryEntry>> feeds =
        <MangaDiscoveryFeed, List<MangaDiscoveryEntry>>{};
    for (final MapEntry<MangaDiscoveryFeed, Map<String, String>> feed
        in _queries.entries) {
      final Uri uri = Uri.parse(
        '${endpoint.replaceFirst(RegExp(r'/+$'), '')}/manga',
      ).replace(
        queryParameters: <String, String>{
          'page': '1',
          'limit': '${perPage.clamp(1, 25)}',
          'type': 'manga',
          'sfw': 'true',
          'sort': 'desc',
          ...feed.value,
        },
      );
      // 与动画资料共享排队、缓存和 429 冷却，传输层不自行重试。
      final Map<String, Object?> payload = await _gate.get(
        uri.toString(),
        () => _transport.get(
          uri,
          operation: 'MAL manga discovery',
          headers: const <String, String>{'Accept': 'application/json'},
        ),
      );
      if (payload['data'] is! List) {
        throw VideoMetadataNetworkException(
          'MAL manga discovery: ${metadataString(payload['message']) ?? 'missing manga list'}',
        );
      }
      final Set<int> seen = <int>{};
      feeds[feed.key] = <MangaDiscoveryEntry>[
        for (final Object? node in metadataList(payload['data']))
          if (_mapEntry(metadataObject(node))
              case final MangaDiscoveryEntry entry)
            if (seen.add(entry.malId)) entry,
      ];
    }
    return MangaDiscoverySnapshot(feeds: feeds);
  }

  MangaDiscoveryEntry? _mapEntry(Map<String, Object?>? item) {
    if (item == null) return null;
    final int? id = metadataInt(item['mal_id']);
    if (id == null || id <= 0) return null;
    final Map<String, Object?>? images = metadataObject(item['images']);
    final Map<String, Object?>? jpg = metadataObject(images?['jpg']);
    final Map<String, Object?>? webp = metadataObject(images?['webp']);
    final double? score = metadataDouble(item['score']);
    return MangaDiscoveryEntry(
      malId: id,
      titleNative: metadataString(item['title_japanese']),
      titleRomaji: metadataString(item['title']),
      titleEnglish: metadataString(item['title_english']),
      synonyms: metadataUniqueStrings(<String?>[
        for (final Object? title in metadataList(item['titles']))
          metadataString(metadataObject(title)?['title']),
        for (final Object? title in metadataList(item['title_synonyms']))
          metadataString(title),
      ]),
      coverUrl: metadataString(jpg?['large_image_url']) ??
          metadataString(webp?['large_image_url']) ??
          metadataString(jpg?['image_url']) ??
          metadataString(webp?['image_url']),
      averageScore: score != null && score > 0 && score <= 10 ? score : null,
      description: metadataStripHtml(metadataString(item['synopsis'])),
      genres: metadataUniqueStrings(<String?>[
        for (final Object? genre in metadataList(item['genres']))
          metadataString(metadataObject(genre)?['name']),
      ]),
      status: switch (metadataString(item['status'])) {
        'Publishing' => 'RELEASING',
        'Finished' => 'FINISHED',
        'On Hiatus' => 'HIATUS',
        'Discontinued' => 'CANCELLED',
        'Not yet published' => 'NOT_YET_RELEASED',
        _ => null,
      },
      chapters: metadataInt(item['chapters']),
      // Jikan 漫画响应不提供原产国，不能从日文标题推断为日本。
    );
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}
