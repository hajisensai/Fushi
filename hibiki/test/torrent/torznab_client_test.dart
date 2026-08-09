import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hibiki/src/media/external_provider.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/media/torrent/torrent_metainfo.dart';
import 'package:hibiki/src/media/torrent/torznab_client.dart';
import 'package:hibiki/src/media/torrent/video_resource_provider.dart';
import 'package:hibiki/src/media/video/discovery/video_discovery_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';

void main() {
  test('config codec extracts a legacy query API key without logging it', () {
    final TorznabEndpointParts parts = splitTorznabEndpointCredentials(
      'https://indexer.example/api?apikey=super-secret',
    );
    expect(parts.endpoint.toString(), 'https://indexer.example/api');
    expect(parts.apiKey, 'super-secret');

    final TorznabIndexerConfig config = TorznabIndexerConfig.fromJson(
      <String, Object?>{
        'id': 'main',
        'name': 'Main',
        'endpoint': 'https://indexer.example/api?apikey=super-secret',
        'categories': <int>[5000, 5070],
      },
    );
    final List<Map<String, Object?>> encoded =
        encodeTorznabIndexerConfigs(<TorznabIndexerConfig>[config]);
    expect(decodeTorznabIndexerConfigs(encoded).single.apiKey, 'super-secret');
    expect(config.toJson(includeSecrets: false), isNot(contains('apiKey')));
    expect(
      decodeTorznabIndexerConfigs(<Object?>[
        <String, Object?>{'id': 'bad', 'endpoint': 'not a URL'},
        ...encoded,
      ]),
      hasLength(1),
    );
    expect(config.toString(), isNot(contains('super-secret')));
  });

  test('plain HTTP is gated to loopback unless explicitly allowed', () {
    expect(
      isSafeExternalProviderEndpoint(Uri.parse('http://localhost/api')),
      isTrue,
    );
    expect(
      isSafeExternalProviderEndpoint(Uri.parse('http://192.168.1.10/api')),
      isFalse,
    );
    expect(
      isSafeExternalProviderEndpoint(
        Uri.parse('http://192.168.1.10/api'),
        allowInsecureHttp: true,
      ),
      isTrue,
    );
    expect(
      isSafeExternalProviderEndpoint(Uri.parse('https://indexer.example/api')),
      isTrue,
    );
  });

  test('uses tv search then general fallback and resolves validated metainfo',
      () async {
    final Uint8List metainfo = _v1Metainfo();
    final String infoHash = inspectTorrentMetainfo(metainfo).torrentId;
    int tvSearches = 0;
    int generalSearches = 0;
    final MockClient httpClient = MockClient((http.Request request) async {
      switch (request.url.queryParameters['t']) {
        case 'caps':
          expect(request.url.queryParameters['apikey'], 'secret-key');
          return http.Response(_capsXml, 200);
        case 'tvsearch':
          tvSearches++;
          return http.Response(_emptyRss, 200);
        case 'search':
          generalSearches++;
          return http.Response(_resultRss(infoHash), 200);
      }
      if (request.url.path == '/download/one.torrent') {
        return http.Response.bytes(metainfo, 200);
      }
      return http.Response('not found', 404);
    });
    final TorznabClient client = TorznabClient(
      indexers: <TorznabIndexerConfig>[
        TorznabIndexerConfig(
          id: 'local',
          name: 'Local',
          endpoint: Uri.parse('http://localhost/api'),
          apiKey: 'secret-key',
        ),
      ],
      client: httpClient,
      closesClient: false,
    );

    final ProviderBatchResult<VideoResourceCandidate> result =
        await client.search(
      VideoResourceSearchRequest(
        media: VideoMediaReference(
          providerId: 'anilist',
          mediaId: '1',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.anime,
          title: 'Test Show',
          season: 1,
          episode: 2,
        ),
      ),
    );

    expect(result.failures, isEmpty);
    expect(result.items, hasLength(1));
    expect(tvSearches, 1);
    expect(generalSearches, 1);
    final TorrentAddPayload payload = await client.resolve(result.items.single);
    expect(payload, isA<TorrentMetainfoPayload>());
    expect(payload.torrentId, infoHash);
  });

  test('caps maximum controls page limit and offset', () async {
    final List<Map<String, String>> searchQueries = <Map<String, String>>[];
    final MockClient httpClient = MockClient((http.Request request) async {
      if (request.url.queryParameters['t'] == 'caps') {
        return http.Response(_capsXml, 200);
      }
      final Map<String, String> query =
          Map<String, String>.of(request.url.queryParameters);
      searchQueries.add(query);
      final int offset = int.parse(query['offset']!);
      return http.Response(
        _resultsRss(
          start: offset,
          count: offset == 100 ? 20 : 25,
          prefix: 'paged',
        ),
        200,
      );
    });
    final TorznabClient client = TorznabClient(
      indexers: <TorznabIndexerConfig>[
        TorznabIndexerConfig(
          id: 'paged',
          name: 'Paged',
          endpoint: Uri.parse('http://localhost/api'),
          apiKey: 'secret-key',
        ),
      ],
      client: httpClient,
      closesClient: false,
    );

    final TorznabCapabilities capabilities =
        await client.fetchCapabilities('paged');
    expect(capabilities.maximumPageSize, 25);
    expect(capabilities.defaultPageSize, 10);
    final ProviderBatchResult<VideoResourceCandidate> result =
        await client.search(
      const VideoResourceSearchRequest(
        query: 'Test',
        page: 3,
        limit: 40,
      ),
    );

    expect(result.failures, isEmpty);
    expect(result.items, hasLength(40));
    expect(
      searchQueries.map((Map<String, String> query) => query['offset']),
      <String?>['0', '25', '50', '75', '100'],
    );
    expect(
      searchQueries.map((Map<String, String> query) => query['limit']).toSet(),
      <String?>{'25'},
    );
  });

  test('multi-indexer page two preserves an unconsumed page-one tail',
      () async {
    final MockClient httpClient = MockClient((http.Request request) async {
      if (request.url.queryParameters['t'] == 'caps') {
        return http.Response(_capsXml, 200);
      }
      final int offset = int.parse(request.url.queryParameters['offset']!);
      if (request.url.path == '/a') {
        return http.Response(
          offset == 0
              ? _resultsRss(start: 0, count: 1, prefix: 'a')
              : _emptyRss,
          200,
        );
      }
      return http.Response(
        _resultsRss(start: offset, count: 2, prefix: 'b'),
        200,
      );
    });
    final TorznabClient client = TorznabClient(
      indexers: <TorznabIndexerConfig>[
        TorznabIndexerConfig(
          id: 'a',
          name: 'A',
          endpoint: Uri.parse('http://localhost/a'),
          apiKey: '',
          priority: 0,
        ),
        TorznabIndexerConfig(
          id: 'b',
          name: 'B',
          endpoint: Uri.parse('http://localhost/b'),
          apiKey: '',
          priority: 1,
        ),
      ],
      client: httpClient,
      closesClient: false,
    );

    final ProviderBatchResult<VideoResourceCandidate> pageOne =
        await client.search(
      const VideoResourceSearchRequest(query: 'Test', limit: 2),
    );
    final ProviderBatchResult<VideoResourceCandidate> pageTwo =
        await client.search(
      const VideoResourceSearchRequest(query: 'Test', page: 2, limit: 2),
    );

    expect(
      pageOne.items.map((VideoResourceCandidate item) => item.title),
      <String>['a-0', 'b-0'],
    );
    expect(
      pageTwo.items.map((VideoResourceCandidate item) => item.title),
      <String>['b-1', 'b-2'],
    );
  });

  test('later indexer-page failure keeps another indexer page usable',
      () async {
    final MockClient httpClient = MockClient((http.Request request) async {
      if (request.url.queryParameters['t'] == 'caps') {
        return http.Response(_capsXml, 200);
      }
      final int offset = int.parse(request.url.queryParameters['offset']!);
      if (request.url.path == '/partial-a' && offset > 0) {
        return http.Response('rate limited', 429);
      }
      final String prefix = request.url.path == '/partial-a' ? 'c' : 'd';
      return http.Response(
        _resultsRss(start: offset, count: 2, prefix: prefix),
        200,
      );
    });
    final TorznabClient client = TorznabClient(
      indexers: <TorznabIndexerConfig>[
        TorznabIndexerConfig(
          id: 'partial-a',
          name: 'Partial A',
          endpoint: Uri.parse('http://localhost/partial-a'),
          apiKey: '',
          priority: 0,
        ),
        TorznabIndexerConfig(
          id: 'healthy-b',
          name: 'Healthy B',
          endpoint: Uri.parse('http://localhost/healthy-b'),
          apiKey: '',
          priority: 1,
        ),
      ],
      client: httpClient,
      closesClient: false,
    );

    final ProviderBatchResult<VideoResourceCandidate> result =
        await client.search(
      const VideoResourceSearchRequest(query: 'Test', page: 2, limit: 2),
    );

    expect(result.isPartial, isTrue);
    expect(result.successfulProviderCount, 2);
    expect(
      result.items.map((VideoResourceCandidate item) => item.title),
      <String>['d-0', 'd-1'],
    );
    expect(
      result.failures.single.kind,
      ExternalProviderFailureKind.rateLimited,
    );
  });

  test('torrent body is capped while streaming, before an extra chunk is read',
      () async {
    int emittedChunks = 0;
    final Uint8List chunk = Uint8List(1024 * 1024);
    final _RoutingStreamClient httpClient = _RoutingStreamClient(
      (http.BaseRequest request) async {
        if (request.url.queryParameters['t'] == 'caps') {
          return _textStreamedResponse(_capsXml);
        }
        if (request.url.queryParameters['t'] == 'search') {
          return _textStreamedResponse(_resultRss('a' * 40));
        }
        if (request.url.path == '/download/one.torrent') {
          final Stream<List<int>> stream = Stream<List<int>>.fromIterable(
            List<List<int>>.filled(18, chunk),
          ).map((List<int> value) {
            emittedChunks++;
            return value;
          });
          return http.StreamedResponse(stream, 200);
        }
        return _textStreamedResponse('not found', statusCode: 404);
      },
    );
    final TorznabClient client = _clientWith(httpClient);
    final ProviderBatchResult<VideoResourceCandidate> result =
        await client.search(const VideoResourceSearchRequest(query: 'Test'));

    await expectLater(
      client.resolve(result.items.single),
      throwsA(
        isA<ExternalProviderFailure>().having(
          (ExternalProviderFailure failure) => failure.kind,
          'kind',
          ExternalProviderFailureKind.invalidResponse,
        ),
      ),
    );
    expect(emittedChunks, 17,
        reason: 'the 17th MiB crosses the 16 MiB cap; chunk 18 stays unread');
  });

  test('unsafe redirect is rejected before sending and failure is redacted',
      () async {
    int downloadCalls = 0;
    final _RoutingStreamClient httpClient = _RoutingStreamClient(
      (http.BaseRequest request) async {
        if (request.url.queryParameters['t'] == 'caps') {
          return _textStreamedResponse(_capsXml);
        }
        if (request.url.queryParameters['t'] == 'search') {
          return _textStreamedResponse(
            _resultRss(
              'a' * 40,
              downloadUrl:
                  'https://indexer.example/download?passkey=source-secret',
            ),
          );
        }
        downloadCalls++;
        if (request.url.host == 'evil.example') {
          fail('unsafe redirect target must not receive a request');
        }
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          302,
          headers: <String, String>{
            'location': 'http://evil.example/file?passkey=redirect-secret',
          },
        );
      },
    );
    final TorznabClient client = _clientWith(
      httpClient,
      endpoint: Uri.parse('https://indexer.example/api'),
    );
    final ProviderBatchResult<VideoResourceCandidate> result =
        await client.search(const VideoResourceSearchRequest(query: 'Test'));

    Object? failure;
    try {
      await client.resolve(result.items.single);
      fail('resolve must reject the unsafe redirect');
    } on Object catch (error) {
      failure = error;
    }
    expect(downloadCalls, 1);
    expect(failure, isA<ExternalProviderFailure>());
    expect(failure.toString(), isNot(contains('source-secret')));
    expect(failure.toString(), isNot(contains('redirect-secret')));
  });

  test('safe redirect is fetched without forwarding indexer credentials',
      () async {
    final Uint8List metainfo = _v1Metainfo();
    final String infoHash = inspectTorrentMetainfo(metainfo).torrentId;
    int downloadCalls = 0;
    final _RoutingStreamClient httpClient = _RoutingStreamClient(
      (http.BaseRequest request) async {
        if (request.url.queryParameters['t'] == 'caps') {
          return _textStreamedResponse(_capsXml);
        }
        if (request.url.queryParameters['t'] == 'search') {
          return _textStreamedResponse(
            _resultRss(
              infoHash,
              downloadUrl:
                  'https://indexer.example/download?passkey=source-secret',
            ),
          );
        }
        downloadCalls++;
        expect(request, isA<http.Request>());
        expect((request as http.Request).followRedirects, isFalse);
        expect(request.headers['authorization'], isNull);
        expect(request.headers['api-key'], isNull);
        if (request.url.host == 'indexer.example') {
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            302,
            headers: <String, String>{
              'location': 'https://cdn.example/file?passkey=temporary-secret',
            },
          );
        }
        expect(request.url.host, 'cdn.example');
        return http.StreamedResponse(
          Stream<List<int>>.value(metainfo),
          200,
          contentLength: metainfo.length,
        );
      },
    );
    final TorznabClient client = _clientWith(
      httpClient,
      endpoint: Uri.parse('https://indexer.example/api'),
    );
    final ProviderBatchResult<VideoResourceCandidate> result =
        await client.search(const VideoResourceSearchRequest(query: 'Test'));

    final TorrentAddPayload payload = await client.resolve(result.items.single);
    expect(payload, isA<TorrentMetainfoPayload>());
    expect(payload.torrentId, infoHash);
    expect(downloadCalls, 2);
  });

  test('network errors never expose the API key', () async {
    final TorznabClient client = TorznabClient(
      indexers: <TorznabIndexerConfig>[
        TorznabIndexerConfig(
          id: 'remote',
          name: 'Remote',
          endpoint: Uri.parse('https://indexer.example/api'),
          apiKey: 'super-secret',
        ),
      ],
      client: MockClient((http.Request request) async {
        throw http.ClientException('failed ${request.url}');
      }),
      closesClient: false,
    );

    final ProviderBatchResult<VideoResourceCandidate> result =
        await client.search(
      const VideoResourceSearchRequest(query: 'query'),
    );

    expect(result.failures, hasLength(1));
    expect(result.failures.single.kind, ExternalProviderFailureKind.network);
    expect(result.failures.single.toString(), isNot(contains('super-secret')));
  });
}

const String _capsXml = '''
<caps>
  <limits max="25" default="10" />
  <searching>
    <search available="yes" supportedParams="q" />
    <tv-search available="yes" supportedParams="q,season,ep" />
  </searching>
  <categories><category id="5000" name="TV" /></categories>
</caps>
''';

const String _emptyRss = '<rss><channel></channel></rss>';

String _resultRss(
  String hash, {
  String downloadUrl = 'http://localhost/download/one.torrent',
}) =>
    '''
<rss xmlns:torznab="http://torznab.com/schemas/2015/feed">
  <channel><item>
    <title>Test Show S01E02 1080p</title>
    <guid>https://indexer.example/item/1</guid>
    <link>$downloadUrl</link>
    <size>1234</size>
    <torznab:attr name="infohash" value="$hash" />
    <torznab:attr name="seeders" value="42" />
    <torznab:attr name="peers" value="7" />
  </item></channel>
</rss>
''';

String _resultsRss({
  required int start,
  required int count,
  required String prefix,
}) =>
    '''
<rss xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel>
${List<String>.generate(count, (int relative) {
      final int index = start + relative;
      final int hashValue = (prefix.codeUnitAt(0) << 24) + index;
      final String hash = hashValue.toRadixString(16).padLeft(40, '0');
      return '''<item>
  <title>$prefix-$index</title>
  <guid>https://indexer.example/$prefix/$index</guid>
  <link>http://localhost/download/$prefix-$index.torrent</link>
  <torznab:attr name="infohash" value="$hash" />
  <torznab:attr name="seeders" value="${10000 - index}" />
</item>''';
    }).join()}
</channel></rss>
''';

Uint8List _v1Metainfo() => Uint8List.fromList(
      utf8.encode(
        'd4:infod6:lengthi1e4:name4:test6:pieces20:aaaaaaaaaaaaaaaaaaaaee',
      ),
    );

TorznabClient _clientWith(
  http.Client httpClient, {
  Uri? endpoint,
}) =>
    TorznabClient(
      indexers: <TorznabIndexerConfig>[
        TorznabIndexerConfig(
          id: 'streamed',
          name: 'Streamed',
          endpoint: endpoint ?? Uri.parse('http://localhost/api'),
          apiKey: 'indexer-secret',
        ),
      ],
      client: httpClient,
      closesClient: false,
    );

http.StreamedResponse _textStreamedResponse(
  String body, {
  int statusCode = 200,
}) {
  final List<int> bytes = utf8.encode(body);
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    statusCode,
    contentLength: bytes.length,
  );
}

class _RoutingStreamClient extends http.BaseClient {
  _RoutingStreamClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
