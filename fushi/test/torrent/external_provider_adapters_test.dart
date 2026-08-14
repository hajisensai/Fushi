import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/nyaa_client.dart';
import 'package:fushi/src/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

void main() {
  test('Nyaa adapter preserves release fields and resolves a magnet', () async {
    final NyaaVideoResourceProvider provider = NyaaVideoResourceProvider(
      client: NyaaClient(
        client: MockClient((http.Request request) async {
          expect(request.url.queryParameters['q'], 'Test Show');
          return http.Response(_nyaaFeed, 200);
        }),
      ),
    );

    final ProviderBatchResult<VideoResourceCandidate> result =
        await provider.search(
      const VideoResourceSearchRequest(query: 'Test Show'),
    );

    expect(result.failures, isEmpty);
    expect(result.items.single.seeders, 15);
    expect(result.items.single.resolution, '1080p');
    final TorrentAddPayload payload =
        await provider.resolve(result.items.single);
    expect(payload, isA<TorrentMagnetPayload>());
    expect(payload.torrentId, '0123456789abcdef0123456789abcdef01234567');
  });

  test(
      'Nyaa adapter searches AniList romaji and Japanese titles, not localized title',
      () async {
    final List<String> queries = <String>[];
    final NyaaVideoResourceProvider provider = NyaaVideoResourceProvider(
      client: NyaaClient(
        client: MockClient((http.Request request) async {
          queries.add(request.url.queryParameters['q']!);
          return http.Response(_nyaaFeed, 200);
        }),
      ),
    );

    final ProviderBatchResult<VideoResourceCandidate> result =
        await provider.search(
      VideoResourceSearchRequest(
        media: VideoMediaReference(
          providerId: 'anilist',
          mediaId: '1535',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.anime,
          title: '死亡笔记',
          originalTitle: 'デスノート',
          aliases: const <String>['Death Note', 'DEATH NOTE'],
          anilistId: 1535,
        ),
        query: '死亡笔记',
      ),
    );

    expect(queries, <String>['Death Note', 'デスノート']);
    expect(result.items, hasLength(1));
    expect(result.failures, isEmpty);
  });

  test('Jimaku adapter searches, filters text subtitles, and downloads',
      () async {
    final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
      client: JimakuClient(
        apiKey: 'jimaku-secret',
        client: MockClient((http.Request request) async {
          expect(request.headers['authorization'], 'jimaku-secret');
          if (request.url.path.endsWith('/entries/search')) {
            return http.Response('[{"id":7,"name":"Test Show"}]', 200);
          }
          if (request.url.path.endsWith('/entries/7/files')) {
            expect(request.url.queryParameters['episode'], '2');
            return http.Response(
              '[{"name":"Test Show - 02.ja.srt",'
              '"url":"https://jimaku.cc/file/7","size":12},'
              '{"name":"archive.zip",'
              '"url":"https://jimaku.cc/file/archive"}]',
              200,
            );
          }
          if (request.url.path == '/file/7') {
            return http.Response.bytes(
              utf8.encode('1\n00:00:00,000 --> 00:00:01,000\nhello\n'),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      ),
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await provider.search(
      VideoSubtitleSearchRequest(
        query: 'Test Show',
        episode: 2,
        languages: <String>['ja'],
      ),
    );

    expect(result.failures, isEmpty);
    expect(result.items, hasLength(1));
    expect(result.items.single.episode, 2);
    final VideoSubtitleDownload download =
        await provider.download(result.items.single);
    expect(download.fileName, 'Test Show - 02.ja.srt');
    expect(utf8.decode(download.bytes), contains('hello'));
  });

  test('Jimaku adapter keeps provider failure distinct from zero results',
      () async {
    final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
      client: JimakuClient(
        apiKey: 'jimaku-secret',
        client: MockClient((http.Request request) async {
          return http.Response('unauthorized', 401);
        }),
      ),
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await provider.search(VideoSubtitleSearchRequest(query: 'Test Show'));

    expect(result.items, isEmpty);
    expect(result.failures, hasLength(1));
    expect(
      result.failures.single.kind,
      ExternalProviderFailureKind.unauthorized,
    );
    expect(result.failures.single.statusCode, 401);
  });

  group('Jimaku Live Action 接入', () {
    VideoMediaReference reference({
      required VideoDiscoveryCategory category,
      VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
      int? tmdbId,
    }) =>
        VideoMediaReference(
          providerId: 'tmdb',
          mediaId: '${tmdbId ?? 0}',
          mediaKind: kind,
          discoveryCategory: category,
          title: '最愛',
          tmdbId: tmdbId,
        );

    test('分类 → 检索范围：动漫查动画、其余查真人、未知查两类', () {
      expect(
        JimakuVideoSubtitleProvider.scopeFor(
            reference(category: VideoDiscoveryCategory.anime)),
        JimakuSearchScope.anime,
      );
      expect(
        JimakuVideoSubtitleProvider.scopeFor(
            reference(category: VideoDiscoveryCategory.tv)),
        JimakuSearchScope.liveAction,
      );
      expect(
        JimakuVideoSubtitleProvider.scopeFor(
            reference(category: VideoDiscoveryCategory.movie)),
        JimakuSearchScope.liveAction,
      );
      // 分类未知（播放页对本地文件搜字幕）不得默认成动画，否则日剧字幕整片消失。
      expect(
        JimakuVideoSubtitleProvider.scopeFor(null),
        JimakuSearchScope.all,
      );
    });

    test('TMDB id 按媒体种类编码（电影/剧集是两个号段）', () {
      expect(
        JimakuVideoSubtitleProvider.tmdbIdFor(reference(
          category: VideoDiscoveryCategory.tv,
          tmdbId: 126991,
        )),
        'tv:126991',
      );
      expect(
        JimakuVideoSubtitleProvider.tmdbIdFor(reference(
          category: VideoDiscoveryCategory.movie,
          kind: VideoMetadataMediaKind.movie,
          tmdbId: 669204,
        )),
        'movie:669204',
      );
      expect(
        JimakuVideoSubtitleProvider.tmdbIdFor(
            reference(category: VideoDiscoveryCategory.tv)),
        isNull,
      );
    });

    test('真人剧检索发 anime=false 且带 tmdb_id，不发 anilist_id', () async {
      final List<String> searches = <String>[];
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(
          apiKey: 'k',
          client: MockClient((http.Request request) async {
            if (request.url.path.endsWith('/entries/search')) {
              final Map<String, String> p = request.url.queryParameters;
              searches.add('anime=${p['anime']}'
                  ' tmdb=${p['tmdb_id']}'
                  ' anilist=${p['anilist_id']}'
                  ' query=${p['query']}');
              return http.Response.bytes(
                utf8.encode('[{"id":4,"name":"最愛","tmdb_id":"tv:126991",'
                    '"flags":{"anime":false}}]'),
                200,
              );
            }
            return http.Response.bytes(
              utf8.encode('[{"name":"最愛 - 01.ja.srt","url":"https://x/1"}]'),
              200,
            );
          }),
        ),
      );

      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await provider.search(
        VideoSubtitleSearchRequest(
          media: reference(
            category: VideoDiscoveryCategory.tv,
            tmdbId: 126991,
          ),
          query: '最愛',
        ),
      );

      expect(result.failures, isEmpty);
      expect(result.items, hasLength(1));
      // TMDB 精确键命中即停，且分类恒为真人；AniList 是动画专属键，此处不得出现。
      expect(searches, <String>[
        'anime=false tmdb=tv:126991 anilist=null query=null',
      ]);
    });
  });
}

const String _nyaaFeed = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:nyaa="https://nyaa.si/xmlns/nyaa">
  <channel><item>
    <title>[Group] Test Show - 02 [1080p]</title>
    <link>https://nyaa.si/download/1.torrent</link>
    <guid>https://nyaa.si/view/1</guid>
    <pubDate>Fri, 03 Nov 2023 12:30:00 -0000</pubDate>
    <nyaa:infoHash>0123456789abcdef0123456789abcdef01234567</nyaa:infoHash>
    <nyaa:seeders>15</nyaa:seeders>
    <nyaa:leechers>2</nyaa:leechers>
    <nyaa:downloads>100</nyaa:downloads>
    <nyaa:size>1.4 GiB</nyaa:size>
    <nyaa:categoryId>1_2</nyaa:categoryId>
    <nyaa:trusted>Yes</nyaa:trusted>
    <nyaa:remake>No</nyaa:remake>
  </item></channel>
</rss>
''';
