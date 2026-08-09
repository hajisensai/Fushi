library;

import 'package:hibiki/src/media/video/metadata/video_metadata_json.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;

class FanartVideoImageProvider implements VideoMetadataImageProvider {
  FanartVideoImageProvider({
    required String apiKey,
    String clientKey = '',
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.baseUrl = 'https://webservice.fanart.tv/v3',
  })  : assert(client == null || transport == null),
        _apiKey = apiKey.trim(),
        _clientKey = clientKey.trim(),
        _transport = transport ?? VideoMetadataHttpClient(client: client),
        _ownsTransport = transport == null;

  final String _apiKey;
  final String _clientKey;
  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final String baseUrl;

  @override
  bool get isAvailable => _apiKey.isNotEmpty;

  @override
  Future<List<VideoMetadataImage>> fetchImages(VideoMetadataWork work) async {
    if (!isAvailable) return const <VideoMetadataImage>[];
    final bool movie = work.kind == VideoMetadataMediaKind.movie;
    final String requiredIdType = movie ? 'tmdb' : 'tvdb';
    final String? externalId = _id(work, requiredIdType);
    if (externalId == null) return const <VideoMetadataImage>[];
    final Uri uri = Uri.parse(
      '$baseUrl/${movie ? 'movies' : 'tv'}/$externalId',
    ).replace(queryParameters: <String, String>{
      'api-key': _apiKey,
      if (_clientKey.isNotEmpty) 'client-key': _clientKey,
    });
    final VideoMetadataHttpResponse response = await _transport.get(
      uri,
      headers: const <String, String>{'Accept': 'application/json'},
      operation: 'Fanart images',
      cacheKey: 'fanart:${movie ? 'movie' : 'tv'}:$externalId',
    );
    final Map<String, Object?> payload =
        response.decodeJsonObject(operation: 'Fanart images');
    final Map<String, VideoMetadataImage> byUrl =
        <String, VideoMetadataImage>{};
    for (final MapEntry<String, Object?> entry in payload.entries) {
      final VideoMetadataImageKind? kind = _kind(entry.key);
      if (kind == null) continue;
      for (final Object? node in metadataList(entry.value)) {
        final Map<String, Object?>? item = metadataObject(node);
        final String? url = metadataString(item?['url']);
        if (item == null || url == null) continue;
        byUrl.putIfAbsent(
          url,
          () => VideoMetadataImage(
            kind: kind,
            url: url,
            provider: VideoMetadataProviderKind.fanart,
            language: metadataString(item['lang']),
            likes: metadataInt(item['likes']),
            seasonNumber: metadataInt(item['season']),
          ),
        );
      }
    }
    final List<VideoMetadataImage> images = byUrl.values.toList()
      ..sort(compareFanartImages);
    return images;
  }

  String? _id(VideoMetadataWork work, String type) {
    for (final VideoMetadataId id in work.ids) {
      if (id.type.toLowerCase() == type && id.value.trim().isNotEmpty) {
        return id.value.trim();
      }
    }
    return null;
  }

  VideoMetadataImageKind? _kind(String key) {
    final String value = key.toLowerCase();
    if (value.contains('poster')) return VideoMetadataImageKind.cover;
    if (value.contains('background')) return VideoMetadataImageKind.backdrop;
    if (value.contains('logo')) return VideoMetadataImageKind.logo;
    if (value.contains('disc')) return VideoMetadataImageKind.disc;
    if (value.contains('banner')) return VideoMetadataImageKind.banner;
    if (value.contains('thumb')) return VideoMetadataImageKind.thumb;
    if (value.contains('clearart') || value.endsWith('movieart')) {
      return VideoMetadataImageKind.clearart;
    }
    return null;
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}

/// MoviePilot/Fanart 语言与热度顺序：中文 → 英文 → 无语言 → 其它，组内 likes 高者优先。
int compareFanartImages(VideoMetadataImage a, VideoMetadataImage b) {
  int languageRank(String? language) => switch (language?.toLowerCase()) {
        'zh' || 'zh-cn' || 'zh-hans' || 'zh-hant' => 0,
        'en' => 1,
        null || '' => 2,
        _ => 3,
      };

  final int language =
      languageRank(a.language).compareTo(languageRank(b.language));
  if (language != 0) return language;
  final int likes = (b.likes ?? -1).compareTo(a.likes ?? -1);
  if (likes != 0) return likes;
  return a.url.compareTo(b.url);
}
