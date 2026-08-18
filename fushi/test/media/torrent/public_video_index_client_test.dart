import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/public_video_index_client.dart';
import 'package:fushi/src/media/torrent/public_video_index_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';

const String _hashA = 'aabbccddeeff00112233445566778899aabbccdd';
const String _hashB = '00112233445566778899aabbccddeeff00112233';

VideoResourceSearchRequest _request({
  VideoDiscoveryCategory? category,
  int limit = 50,
}) =>
    VideoResourceSearchRequest(
      query: 'Inception',
      media: category == null
          ? null
          : VideoMediaReference(
              providerId: 'tmdb',
              mediaId: '27205',
              mediaKind: VideoMetadataMediaKind.movie,
              discoveryCategory: category,
              title: 'Inception',
            ),
      limit: limit,
    );

void main() {
  group('normalizePublicVideoIndexInfoHash', () {
    test('accepts v1 (40) and v2 (64) hex, case-insensitively', () {
      expect(normalizePublicVideoIndexInfoHash(_hashA.toUpperCase()), _hashA);
      expect(normalizePublicVideoIndexInfoHash('a' * 64), 'a' * 64);
    });

    test('rejects anything that is not a torrent hash', () {
      // identityKey 就是 infoHash：放进一个歪 hash 不报错，只会让同一个种子在两家
      // 源里各算一条。所以「拒绝」是这层唯一有意义的行为。
      expect(normalizePublicVideoIndexInfoHash(''), '');
      expect(normalizePublicVideoIndexInfoHash('a' * 39), '');
      expect(normalizePublicVideoIndexInfoHash('a' * 41), '');
      expect(normalizePublicVideoIndexInfoHash('z' * 40), '');
    });
  });

  test('buildPublicVideoIndexMagnet carries the shared public trackers', () {
    final String magnet = buildPublicVideoIndexMagnet(
      infoHash: _hashA,
      displayName: 'Some Show S01E01',
    );
    expect(magnet, startsWith('magnet:?xt=urn:btih:$_hashA'));
    expect(magnet, contains('dn=Some+Show+S01E01'));
    for (final String tracker in kPublicVideoIndexTrackers) {
      expect(magnet, contains(Uri.encodeQueryComponent(tracker)));
    }
  });

  group('ApibayClient', () {
    test('drops the sentinel no-results row', () async {
      final ApibayClient client = ApibayClient(
        client: MockClient(
          (http.Request request) async => http.Response(
            jsonEncode(<Map<String, Object?>>[
              <String, Object?>{
                'id': '0',
                'name': 'No results returned',
                'info_hash': '0' * 40,
              },
            ]),
            200,
          ),
        ),
      );
      expect(await client.search('nothing', categories: <int>[207]), isEmpty);
    });

    test('deduplicates across the per-category requests', () async {
      final List<Uri> calls = <Uri>[];
      final ApibayClient client = ApibayClient(
        client: MockClient((http.Request request) async {
          calls.add(request.url);
          return http.Response(
            jsonEncode(<Map<String, Object?>>[
              <String, Object?>{
                'id': '42',
                'name': 'Inception 2010 1080p BluRay',
                'info_hash': _hashA.toUpperCase(),
                'seeders': '120',
                'leechers': '4',
                'size': '8589934592',
                'added': '1700000000',
              },
            ]),
            200,
          );
        }),
      );
      final List<PublicVideoIndexTorrent> results =
          await client.search('inception', categories: kApibayMovieCategories);
      // 两个分类各打一次，同一个种子只留一条。
      expect(calls, hasLength(kApibayMovieCategories.length));
      expect(results, hasLength(1));
      expect(results.single.infoHash, _hashA);
      expect(results.single.resolution, '1080p');
      expect(results.single.magnet, contains('urn:btih:$_hashA'));
      expect(results.single.sizeBytes, 8589934592);
      expect(
        results.single.publishedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true),
      );
    });

    test('throws on a non-200 instead of reporting an empty result', () async {
      final ApibayClient client = ApibayClient(
        client: MockClient(
          (http.Request request) async => http.Response('nope', 503),
        ),
      );
      await expectLater(
        client.search('inception', categories: <int>[207]),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('KnabenClient', () {
    test('parses hits and keeps the server-provided magnet', () async {
      late Map<String, Object?> body;
      final KnabenClient client = KnabenClient(
        client: MockClient((http.Request request) async {
          body = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(
            jsonEncode(<String, Object?>{
              'hits': <Map<String, Object?>>[
                <String, Object?>{
                  'title': 'Inception 2010 2160p WEB-DL',
                  'hash': _hashB,
                  'magnetUrl':
                      'magnet:?xt=urn:btih:$_hashB&tr=udp://x:80/announce',
                  'seeders': 9,
                  'peers': 1,
                  'bytes': 1234,
                  'grabs': 7,
                  'date': '2024-01-02T03:04:05Z',
                  'details': 'https://knaben.org/x',
                },
                <String, Object?>{'title': 'broken', 'hash': 'zz'},
              ],
            }),
            200,
          );
        }),
      );
      final List<PublicVideoIndexTorrent> results = await client.search(
        'inception',
        categories: <int>[kKnabenMovieCategory],
      );
      expect(results, hasLength(1));
      expect(results.single.magnet, startsWith('magnet:?xt=urn:btih:$_hashB'));
      expect(results.single.completed, 7);
      expect(results.single.detailsUrl, 'https://knaben.org/x');
      // search_type 必须是精确匹配档；score 档会把 query 当权重提示。
      expect(body['search_type'], '100%');
      expect(body['hide_xxx'], isTrue);
      expect(body['categories'], <int>[kKnabenMovieCategory]);
    });

    test('synthesizes a magnet when the API omits magnetUrl', () async {
      final KnabenClient client = KnabenClient(
        client: MockClient(
          (http.Request request) async => http.Response(
            jsonEncode(<String, Object?>{
              'hits': <Map<String, Object?>>[
                <String, Object?>{'title': 'X', 'hash': _hashB},
              ],
            }),
            200,
          ),
        ),
      );
      final List<PublicVideoIndexTorrent> results = await client.search(
        'x',
        categories: <int>[kKnabenTvCategory],
      );
      expect(
        results.single.magnet,
        buildPublicVideoIndexMagnet(infoHash: _hashB, displayName: 'X'),
      );
    });
  });

  group('public index providers', () {
    test('apibay only serves movie and tv, never anime', () {
      final ApibayVideoResourceProvider provider =
          ApibayVideoResourceProvider(client: ApibayClient());
      expect(provider.categories, <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      });
      expect(
        provider.categories.contains(VideoDiscoveryCategory.anime),
        isFalse,
      );
      provider.close();
    });

    test('knaben only serves movie and tv, never anime', () {
      final KnabenVideoResourceProvider provider =
          KnabenVideoResourceProvider(client: KnabenClient());
      expect(provider.categories, <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      });
      expect(
        provider.categories.contains(VideoDiscoveryCategory.anime),
        isFalse,
      );
      provider.close();
    });

    test('a tv request uses the tv categories', () async {
      late Uri seen;
      final ApibayVideoResourceProvider provider = ApibayVideoResourceProvider(
        client: ApibayClient(
          client: MockClient((http.Request request) async {
            seen = request.url;
            return http.Response('[]', 200);
          }),
        ),
      );
      await provider.search(_request(category: VideoDiscoveryCategory.tv));
      expect(seen.queryParameters['cat'], kApibayTvCategories.last.toString());
    });

    test('a transport failure becomes a failure, not an empty result',
        () async {
      final ApibayVideoResourceProvider provider = ApibayVideoResourceProvider(
        client: ApibayClient(
          client: MockClient(
            (http.Request request) async => http.Response('boom', 500),
          ),
        ),
      );
      final ProviderBatchResult<VideoResourceCandidate> result = await provider
          .search(_request(category: VideoDiscoveryCategory.movie));
      expect(result.failures, hasLength(1));
      expect(result.successfulProviderCount, 0);
      // 「零来源」与「来源答了但没有匹配」必须可区分（PR#896 的空态判据）。
      expect(result.hasNoActiveProvider, isFalse);
    });

    test('resolve hands out the magnet and refuses foreign candidates', () {
      final PublicVideoIndexCandidate mine = PublicVideoIndexCandidate(
        torrent: PublicVideoIndexTorrent(
          title: 'X',
          infoHash: _hashA,
          magnet: buildPublicVideoIndexMagnet(
            infoHash: _hashA,
            displayName: 'X',
          ),
          seeders: 1,
          leechers: 0,
          sizeBytes: 1,
        ),
        providerId: kApibayResourceProviderId,
        providerInstanceId: 'apibay.org',
        providerPriority: 200,
      );
      final TorrentAddPayload payload = resolvePublicVideoIndexCandidate(
        mine,
        kApibayResourceProviderId,
      );
      expect(payload, isA<TorrentMagnetPayload>());
      expect((payload as TorrentMagnetPayload).torrentId, _hashA);
      expect(
        () => resolvePublicVideoIndexCandidate(mine, kKnabenResourceProviderId),
        throwsA(isA<ExternalProviderFailure>()),
      );
    });
  });
}
