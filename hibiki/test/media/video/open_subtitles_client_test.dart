import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hibiki/src/media/external_provider.dart';
import 'package:hibiki/src/media/video/discovery/video_discovery_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/subtitle/open_subtitles_client.dart';
import 'package:hibiki/src/media/video/subtitle/video_subtitle_provider.dart';

void main() {
  test('config codec persists credentials but toString redacts them', () {
    final OpenSubtitlesConfig config = OpenSubtitlesConfig.fromJson(
      <String, Object?>{
        'apiKey': 'api-secret',
        'username': 'user',
        'password': 'password-secret',
      },
    );
    expect(config.toJson()['apiKey'], 'api-secret');
    expect(config.toJson(includeSecrets: false), isNot(contains('apiKey')));
    expect(config.toJson(includeSecrets: false), isNot(contains('password')));
    expect(config.toString(), isNot(contains('api-secret')));
    expect(config.toString(), isNot(contains('password-secret')));
  });

  test('optional login, search and temporary-link download', () async {
    int loginCalls = 0;
    final MockClient httpClient = MockClient((http.Request request) async {
      if (request.url.path.endsWith('/login')) {
        loginCalls++;
        expect(jsonDecode(request.body)['password'], 'password-secret');
        return http.Response(
          jsonEncode(<String, Object?>{
            'token': 'login-token',
            'base_url': 'http://localhost/api/v1',
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/subtitles')) {
        expect(request.headers['api-key'], 'api-secret');
        expect(request.headers['authorization'], 'Bearer login-token');
        expect(request.url.queryParameters['season_number'], '1');
        expect(request.url.queryParameters['episode_number'], '2');
        expect(request.url.queryParameters['parent_tmdb_id'], '123');
        expect(request.url.queryParameters['tmdb_id'], isNull);
        expect(request.url.queryParameters['query'], isNull,
            reason: 'ID lookup must not be mixed with a title lookup');
        return http.Response(jsonEncode(_searchResponse), 200);
      }
      if (request.url.path.endsWith('/download')) {
        expect(request.headers['authorization'], 'Bearer login-token');
        expect(jsonDecode(request.body)['file_id'], 77);
        return http.Response(
          jsonEncode(<String, Object?>{
            'link': 'http://localhost/temp/subtitle',
            'file_name': 'downloaded.ja.srt',
            'remaining': 4,
          }),
          200,
        );
      }
      if (request.url.path == '/temp/subtitle') {
        expect(request.headers['authorization'], isNull);
        expect(request.headers['api-key'], isNull);
        return http.Response('1\n00:00:00,000 --> 00:00:01,000\nhello\n', 200);
      }
      return http.Response('not found', 404);
    });
    final OpenSubtitlesClient client = OpenSubtitlesClient(
      config: OpenSubtitlesConfig(
        apiKey: 'api-secret',
        username: 'user',
        password: 'password-secret',
        baseUrl: Uri.parse('http://localhost/api/v1'),
      ),
      client: httpClient,
      closesClient: false,
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await client.search(
      VideoSubtitleSearchRequest(
        media: VideoMediaReference(
          providerId: 'tmdb',
          mediaId: '123',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.tv,
          title: 'Test Show',
          season: 1,
          episode: 2,
          tmdbId: 123,
        ),
        languages: <String>['ja'],
      ),
    );

    expect(result.failures, isEmpty);
    expect(result.items, hasLength(1));
    expect(loginCalls, 1);
    final VideoSubtitleDownload download =
        await client.download(result.items.single);
    expect(download.fileName, 'downloaded.ja.srt');
    expect(utf8.decode(download.bytes), contains('hello'));
    expect(client.quotaRemaining, 4);
  });

  test('maps quota response without exposing response secrets', () async {
    final OpenSubtitlesClient client = OpenSubtitlesClient(
      config: OpenSubtitlesConfig(
        apiKey: 'api-secret',
        baseUrl: Uri.parse('http://localhost/api/v1'),
      ),
      client: MockClient((http.Request request) async {
        return http.Response(
          '{"remaining":0,"token":"response-secret"}',
          429,
          headers: <String, String>{'retry-after': '60'},
        );
      }),
      closesClient: false,
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await client.search(VideoSubtitleSearchRequest(query: 'Test'));

    expect(
        result.failures.single.kind, ExternalProviderFailureKind.quotaExceeded);
    expect(result.failures.single.retryAfter, const Duration(seconds: 60));
    expect(
        result.failures.single.toString(), isNot(contains('response-secret')));
  });

  test('temporary file follows a safe redirect without forwarding API auth',
      () async {
    int temporaryRequests = 0;
    final _RoutingStreamClient httpClient = _RoutingStreamClient(
      (http.BaseRequest request) async {
        if (request.url.path.endsWith('/subtitles')) {
          return _jsonStreamedResponse(_searchResponse);
        }
        if (request.url.path.endsWith('/download')) {
          return _jsonStreamedResponse(<String, Object?>{
            'link': 'https://download.example/start?token=temporary-secret',
          });
        }
        temporaryRequests++;
        expect(request.headers['api-key'], isNull);
        expect(request.headers['authorization'], isNull);
        expect(request.headers['cookie'], isNull);
        if (request.url.host == 'download.example') {
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            302,
            headers: const <String, String>{
              'location': 'https://cdn.example/subtitle?sig=cdn-secret',
            },
          );
        }
        expect(request.url.host, 'cdn.example');
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('subtitle')),
          200,
        );
      },
    );
    final OpenSubtitlesClient client = OpenSubtitlesClient(
      config: OpenSubtitlesConfig(
        apiKey: 'api-secret',
        baseUrl: Uri.parse('http://localhost/api/v1'),
      ),
      client: httpClient,
      closesClient: false,
    );
    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await client.search(VideoSubtitleSearchRequest(query: 'Test'));

    final VideoSubtitleDownload download =
        await client.download(result.items.single);

    expect(utf8.decode(download.bytes), 'subtitle');
    expect(temporaryRequests, 2);
  });

  test('temporary file rejects an unsafe redirect without leaking its query',
      () async {
    int evilRequests = 0;
    final _RoutingStreamClient httpClient = _RoutingStreamClient(
      (http.BaseRequest request) async {
        if (request.url.path.endsWith('/subtitles')) {
          return _jsonStreamedResponse(_searchResponse);
        }
        if (request.url.path.endsWith('/download')) {
          return _jsonStreamedResponse(<String, Object?>{
            'link': 'https://download.example/start?token=temporary-secret',
          });
        }
        if (request.url.host == 'evil.example') {
          evilRequests++;
          fail('an unsafe redirect target must not receive a request');
        }
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          302,
          headers: const <String, String>{
            'location': 'http://evil.example/file?sig=redirect-secret',
          },
        );
      },
    );
    final OpenSubtitlesClient client = OpenSubtitlesClient(
      config: OpenSubtitlesConfig(
        apiKey: 'api-secret',
        baseUrl: Uri.parse('http://localhost/api/v1'),
      ),
      client: httpClient,
      closesClient: false,
    );
    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await client.search(VideoSubtitleSearchRequest(query: 'Test'));

    Object? failure;
    try {
      await client.download(result.items.single);
      fail('the unsafe redirect must fail');
    } on Object catch (error) {
      failure = error;
    }

    expect(evilRequests, 0);
    expect(failure, isA<ExternalProviderFailure>());
    expect(failure.toString(), isNot(contains('temporary-secret')));
    expect(failure.toString(), isNot(contains('redirect-secret')));
  });

  test('temporary file stops a redirect loop after revisiting a URL', () async {
    int temporaryRequests = 0;
    final _RoutingStreamClient httpClient = _RoutingStreamClient(
      (http.BaseRequest request) async {
        if (request.url.path.endsWith('/subtitles')) {
          return _jsonStreamedResponse(_searchResponse);
        }
        if (request.url.path.endsWith('/download')) {
          return _jsonStreamedResponse(<String, Object?>{
            'link': 'https://download.example/a',
          });
        }
        temporaryRequests++;
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          302,
          headers: <String, String>{
            'location': request.url.path == '/a'
                ? 'https://download.example/b'
                : 'https://download.example/a',
          },
        );
      },
    );
    final OpenSubtitlesClient client = OpenSubtitlesClient(
      config: OpenSubtitlesConfig(
        apiKey: 'api-secret',
        baseUrl: Uri.parse('http://localhost/api/v1'),
      ),
      client: httpClient,
      closesClient: false,
    );
    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await client.search(VideoSubtitleSearchRequest(query: 'Test'));

    await expectLater(
      client.download(result.items.single),
      throwsA(
        isA<ExternalProviderFailure>().having(
          (ExternalProviderFailure failure) => failure.kind,
          'kind',
          ExternalProviderFailureKind.invalidResponse,
        ),
      ),
    );
    expect(temporaryRequests, 2);
  });

  test('temporary file is capped while streaming and cancels immediately',
      () async {
    int emittedChunks = 0;
    final Uint8List chunk = Uint8List(1024 * 1024);
    final _RoutingStreamClient httpClient = _RoutingStreamClient(
      (http.BaseRequest request) async {
        if (request.url.path.endsWith('/subtitles')) {
          return _jsonStreamedResponse(_searchResponse);
        }
        if (request.url.path.endsWith('/download')) {
          return _jsonStreamedResponse(<String, Object?>{
            'link': 'https://download.example/subtitle',
          });
        }
        final Stream<List<int>> stream = Stream<List<int>>.fromIterable(
          List<List<int>>.filled(66, chunk),
        ).map((List<int> value) {
          emittedChunks++;
          return value;
        });
        return http.StreamedResponse(stream, 200);
      },
    );
    final OpenSubtitlesClient client = OpenSubtitlesClient(
      config: OpenSubtitlesConfig(
        apiKey: 'api-secret',
        baseUrl: Uri.parse('http://localhost/api/v1'),
      ),
      client: httpClient,
      closesClient: false,
    );
    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await client.search(VideoSubtitleSearchRequest(query: 'Test'));

    await expectLater(
      client.download(result.items.single),
      throwsA(
        isA<ExternalProviderFailure>().having(
          (ExternalProviderFailure failure) => failure.kind,
          'kind',
          ExternalProviderFailureKind.invalidResponse,
        ),
      ),
    );
    expect(emittedChunks, 65,
        reason: 'the 65th MiB crosses the cap; chunk 66 stays unread');
  });

  test('does not issue an unbounded search with only language filters',
      () async {
    final OpenSubtitlesClient client = OpenSubtitlesClient(
      config: OpenSubtitlesConfig(
        apiKey: 'api-secret',
        baseUrl: Uri.parse('http://localhost/api/v1'),
      ),
      client: MockClient((http.Request request) async {
        fail('network must not be called for an unbounded search');
      }),
      closesClient: false,
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await client.search(
      VideoSubtitleSearchRequest(languages: <String>['ja']),
    );

    expect(
      result.failures.single.kind,
      ExternalProviderFailureKind.unsupported,
    );
  });

  test('falls back in separate hash, IMDb, TMDB, then title requests',
      () async {
    final List<Map<String, String>> queries = <Map<String, String>>[];
    final OpenSubtitlesClient client = OpenSubtitlesClient(
      config: OpenSubtitlesConfig(
        apiKey: 'api-secret',
        baseUrl: Uri.parse('http://localhost/api/v1'),
      ),
      client: MockClient((http.Request request) async {
        queries.add(Map<String, String>.of(request.url.queryParameters));
        return http.Response(
          jsonEncode(queries.length == 4 ? _searchResponse : _emptySearch),
          200,
        );
      }),
      closesClient: false,
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await client.search(
      VideoSubtitleSearchRequest(
        media: VideoMediaReference(
          providerId: 'tmdb',
          mediaId: '123',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.tv,
          title: 'Test Show',
          year: 2024,
          season: 1,
          episode: 2,
          imdbId: 'tt7654321',
          tmdbId: 123,
        ),
        languages: <String>['ja', 'zh'],
        page: 3,
        fingerprint: const LocalVideoFingerprint(
          fileSize: 987654321,
          openSubtitlesMovieHash: 'abcdef0123456789',
        ),
      ),
    );

    expect(result.failures, isEmpty);
    expect(result.items, hasLength(1));
    expect(queries, hasLength(4));
    expect(
      queries[0],
      containsPair('moviehash', 'abcdef0123456789'),
    );
    expect(queries[0], containsPair('moviebytesize', '987654321'));
    expect(queries[0], isNot(contains('parent_imdb_id')));
    expect(queries[0], isNot(contains('parent_tmdb_id')));
    expect(queries[0], isNot(contains('query')));

    expect(queries[1], containsPair('parent_imdb_id', '7654321'));
    expect(queries[1], containsPair('season_number', '1'));
    expect(queries[1], containsPair('episode_number', '2'));
    expect(queries[1], isNot(contains('parent_tmdb_id')));
    expect(queries[1], isNot(contains('query')));

    expect(queries[2], containsPair('parent_tmdb_id', '123'));
    expect(queries[2], isNot(contains('parent_imdb_id')));
    expect(queries[2], isNot(contains('query')));

    expect(queries[3], containsPair('query', 'Test Show'));
    expect(queries[3], containsPair('year', '2024'));
    expect(queries[3], containsPair('season_number', '1'));
    expect(queries[3], containsPair('episode_number', '2'));
    expect(queries[3], isNot(contains('parent_imdb_id')));
    expect(queries[3], isNot(contains('parent_tmdb_id')));
    for (final Map<String, String> query in queries) {
      expect(query['page'], '3');
      expect(query['languages'], 'ja,zh');
    }
  });

  for (final ({
    String name,
    int status,
    String body,
    ExternalProviderFailureKind kind,
  }) testCase in <({
    String name,
    int status,
    String body,
    ExternalProviderFailureKind kind,
  })>[
    (
      name: 'authentication',
      status: 401,
      body: '{}',
      kind: ExternalProviderFailureKind.unauthorized,
    ),
    (
      name: 'rate limit',
      status: 429,
      body: '{"remaining":5}',
      kind: ExternalProviderFailureKind.rateLimited,
    ),
    (
      name: 'quota',
      status: 429,
      body: '{"remaining":0}',
      kind: ExternalProviderFailureKind.quotaExceeded,
    ),
  ]) {
    test('${testCase.name} failure stops precise-to-broad fallback', () async {
      int searchCalls = 0;
      final OpenSubtitlesClient client = OpenSubtitlesClient(
        config: OpenSubtitlesConfig(
          apiKey: 'api-secret',
          baseUrl: Uri.parse('http://localhost/api/v1'),
        ),
        client: MockClient((http.Request request) async {
          searchCalls++;
          return http.Response(testCase.body, testCase.status);
        }),
        closesClient: false,
      );

      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await client.search(
        VideoSubtitleSearchRequest(
          media: VideoMediaReference(
            providerId: 'tmdb',
            mediaId: '123',
            mediaKind: VideoMetadataMediaKind.movie,
            discoveryCategory: VideoDiscoveryCategory.movie,
            title: 'Test Movie',
            year: 2024,
            imdbId: 'tt7654321',
            tmdbId: 123,
          ),
          fingerprint: const LocalVideoFingerprint(
            fileSize: 1234,
            openSubtitlesMovieHash: 'abcdef0123456789',
          ),
        ),
      );

      expect(searchCalls, 1);
      expect(result.items, isEmpty);
      expect(result.failures.single.kind, testCase.kind);
    });
  }
}

const Map<String, Object?> _emptySearch = <String, Object?>{
  'data': <Object?>[],
};

const Map<String, Object?> _searchResponse = <String, Object?>{
  'data': <Object?>[
    <String, Object?>{
      'attributes': <String, Object?>{
        'language': 'ja',
        'release': 'Test.Show.S01E02',
        'download_count': 12,
        'hearing_impaired': false,
        'fps': 23.976,
        'feature_details': <String, Object?>{
          'season_number': 1,
          'episode_number': 2,
        },
        'files': <Object?>[
          <String, Object?>{
            'file_id': 77,
            'file_name': 'Test.Show.S01E02.ja.srt',
          },
        ],
      },
    },
  ],
};

http.StreamedResponse _jsonStreamedResponse(Object value) {
  final List<int> body = utf8.encode(jsonEncode(value));
  return http.StreamedResponse(
    Stream<List<int>>.value(body),
    200,
    contentLength: body.length,
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
