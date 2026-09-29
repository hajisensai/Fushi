import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/subdl_client.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

const String _searchBody = '''
{
  "status": true,
  "results": [
    {"sd_id": 1300025, "type": "tv", "name": "Game of Thrones",
     "imdb_id": "tt0944947", "tmdb_id": 1399,
     "first_air_date": "2011-04-17T00:00:00.000Z", "year": 2011}
  ],
  "subtitles": [
    {"release_name": "Game.of.Thrones.S01E01.720p.BluRay",
     "name": "SUBDL.com::_got_english_1.zip", "lang": "english",
     "author": "someone", "url": "/subtitle/1-11.zip",
     "subtitlePage": "/s/info/a", "season": 1, "episode": 1,
     "language": "EN", "hi": true, "comment": "", "releases": [],
     "episode_from": null, "episode_end": 0, "full_season": false},
    {"release_name": "Game.of.Thrones.S01.Complete", "lang": "chinese bg code",
     "url": "/subtitle/1-12.zip", "season": 1, "episode": 0,
     "language": "ZH_BG", "hi": 0, "episode_from": 1, "episode_end": 10,
     "full_season": true, "fps": "23.976"},
    {"release_name": "Game.of.Thrones.S01E02", "url": "/subtitle/1-13.zip",
     "season": 1, "episode": 2, "language": "EN", "hi": false}
  ]
}
''';

Uint8List _zip(Map<String, String> entries) {
  final Archive archive = Archive();
  entries.forEach((String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

VideoMediaReference _media({
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
  String? imdbId,
  int? tmdbId,
  int? year,
}) =>
    VideoMediaReference(
      providerId: 'tmdb',
      mediaId: '1399',
      mediaKind: kind,
      discoveryCategory: VideoDiscoveryCategory.tv,
      title: 'Game of Thrones',
      imdbId: imdbId,
      tmdbId: tmdbId,
      year: year,
    );

void main() {
  group('language mapping', () {
    test('expands zh/pt families and upper-cases the rest', () {
      expect(normalizeSubdlLanguages(<String>['zh', 'ja', ' en ', 'ja']),
          <String>['EN', 'JA', 'ZH', 'ZH_BG']);
      expect(normalizeSubdlLanguages(<String>['pt']), <String>['BR_PT', 'PT']);
      expect(normalizeSubdlLanguages(<String>[]), isEmpty);
    });

    test('maps response codes back to Hibiki family codes', () {
      expect(subdlLanguageToHibiki('EN'), 'en');
      expect(subdlLanguageToHibiki('ZH_BG'), 'zh');
      expect(subdlLanguageToHibiki('BR_PT'), 'pt');
      expect(subdlLanguageToHibiki('EN_DE'), 'en');
      expect(subdlLanguageToHibiki(''), 'und');
      expect(subdlLanguageToHibiki(null), 'und');
    });

    test('film name strips characters the API rejects', () {
      expect(sanitizeSubdlFilmName("Bob's  [Burgers] / \"S1\""),
          'Bob s Burgers S1');
    });
  });

  group('parseSubdlSearchResponse', () {
    test('reads work, subtitles, zero-as-null and hi in both shapes', () {
      final SubdlSearchPage page = parseSubdlSearchResponse(_searchBody);
      expect(page.work?.sdId, 1300025);
      expect(page.work?.name, 'Game of Thrones');
      expect(page.subtitles, hasLength(3));
      final SubdlSubtitleRecord single = page.subtitles.first;
      expect(single.url, '/subtitle/1-11.zip');
      expect(single.language, 'en');
      expect(single.episode, 1);
      expect(single.hearingImpaired, isTrue);
      expect(single.episodeEnd, isNull, reason: '0 归 null');
      final SubdlSubtitleRecord pack = page.subtitles[1];
      expect(pack.language, 'zh');
      expect(pack.episode, isNull);
      expect(pack.isMultiEpisodePack, isTrue);
      expect(pack.coversEpisode(7), isTrue);
      expect(pack.coversEpisode(11), isFalse);
      expect(pack.fps, closeTo(23.976, 0.001));
      expect(pack.hearingImpaired, isFalse);
    });

    test('status:false surfaces as SubdlApiException with not-found flag', () {
      expect(
        () => parseSubdlSearchResponse(
            '{"status":false,"error":"Can\'t find any subtitles"}'),
        throwsA(isA<SubdlApiException>()
            .having((SubdlApiException e) => e.isNotFound, 'isNotFound', true)),
      );
      expect(
        () => parseSubdlSearchResponse(
            '{"status":false,"statusCode":403,"error":"not_authorized"}'),
        throwsA(isA<SubdlApiException>()
            .having((SubdlApiException e) => e.isNotFound, 'isNotFound', false)
            .having((SubdlApiException e) => e.statusCode, 'statusCode', 403)),
      );
      expect(() => parseSubdlSearchResponse('[]'), throwsFormatException);
    });
  });

  group('buildSubdlSearchQueries', () {
    test('tiers imdb → tmdb → film name with shared filters', () {
      final List<Map<String, String>> queries = buildSubdlSearchQueries(
        VideoSubtitleSearchRequest(
          media: _media(imdbId: '0944947', tmdbId: 1399, year: 2011),
          languages: const <String>['en', 'zh'],
          season: 1,
          episode: 3,
          page: 2,
        ),
      );
      expect(queries, hasLength(3));
      expect(queries[0]['imdb_id'], 'tt0944947', reason: '补 tt 前缀');
      expect(queries[0]['type'], 'tv');
      expect(queries[0]['season_number'], '1');
      expect(queries[0]['episode_number'], '3');
      expect(queries[0]['languages'], 'EN,ZH,ZH_BG');
      expect(queries[0]['subs_per_page'], '30');
      expect(queries[0]['page'], '2');
      expect(queries[0].containsKey('film_name'), isFalse);
      expect(queries[1]['tmdb_id'], '1399');
      expect(queries[1].containsKey('imdb_id'), isFalse);
      expect(queries[2]['film_name'], 'Game of Thrones');
      expect(queries[2]['year'], '2011');
    });

    test('movie kind sends type=movie; bare query sends no type', () {
      expect(
        buildSubdlSearchQueries(VideoSubtitleSearchRequest(
          media: _media(kind: VideoMetadataMediaKind.movie, imdbId: 'tt1'),
        )).first['type'],
        'movie',
      );
      final List<Map<String, String>> bare =
          buildSubdlSearchQueries(VideoSubtitleSearchRequest(query: 'Dune'));
      expect(bare, hasLength(1));
      expect(bare.first['film_name'], 'Dune');
      expect(bare.first.containsKey('type'), isFalse);
      expect(bare.first.containsKey('page'), isFalse);
      expect(buildSubdlSearchQueries(VideoSubtitleSearchRequest()), isEmpty);
    });
  });

  group('SubdlClient.search', () {
    test('sends api key as query and stops at the first tier with results',
        () async {
      final List<Uri> seen = <Uri>[];
      final SubdlClient client = SubdlClient(
        apiKey: ' secret ',
        client: MockClient((http.Request request) async {
          seen.add(request.url);
          expect(request.headers['user-agent'], isNot(contains('Hibiki')));
          expect(request.headers.containsKey('api-key'), isFalse);
          return http.Response(_searchBody, 200);
        }),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await client.search(VideoSubtitleSearchRequest(
        media: _media(imdbId: 'tt0944947', tmdbId: 1399),
        episode: 1,
      ));
      expect(result.failures, isEmpty);
      expect(seen, hasLength(1), reason: 'imdb 命中后不再打 tmdb / 片名');
      expect(seen.single.host, 'api.subdl.com');
      expect(seen.single.path, '/api/v1/subtitles');
      expect(seen.single.queryParameters['api_key'], 'secret');
      expect(seen.single.queryParameters['imdb_id'], 'tt0944947');
      // 第 1 集：单集 E01 与整季包留下，E02 被剔除。
      final List<VideoSubtitleCandidate> items = result.items.toList();
      expect(items.map((VideoSubtitleCandidate c) => c.remoteId),
          <String>['/subtitle/1-11.zip', '/subtitle/1-12.zip']);
      expect(items.first.providerId, 'subdl');
      expect(items.first.language, 'en');
      expect(items.first.hearingImpaired, isTrue);
      expect(items.first.collectionId, '1300025');
      expect(items.first.collectionLabel, 'Game of Thrones');
      expect(items.first.releaseName, 'Game.of.Thrones.S01E01.720p.BluRay');
      expect(items[1].language, 'zh');
      expect(items[1].season, 1);
    });

    test('falls through tiers on not-found and returns empty at the end',
        () async {
      int calls = 0;
      final SubdlClient client = SubdlClient(
        apiKey: 'k',
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response(
              '{"status":false,"error":"Can\'t find any subtitles"}', 200);
        }),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await client.search(VideoSubtitleSearchRequest(
        media: _media(imdbId: 'tt1', tmdbId: 2),
      ));
      expect(result.failures, isEmpty);
      expect(result.items, isEmpty);
      expect(calls, 3);
    });

    test('missing key never sends a request', () async {
      int calls = 0;
      final SubdlClient client = SubdlClient(
        apiKey: '  ',
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response(_searchBody, 200);
        }),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await client.search(VideoSubtitleSearchRequest(query: 'x'));
      expect(result.failures.single.kind,
          ExternalProviderFailureKind.unauthorized);
      expect(calls, 0);
    });

    test('HTTP 403 / 429 map to redacted failures and never fall through',
        () async {
      int calls = 0;
      Future<ExternalProviderFailure?> run(http.Response response) async {
        calls = 0;
        final SubdlClient client = SubdlClient(
          apiKey: 'k',
          client: MockClient((http.Request request) async {
            calls++;
            return response;
          }),
        );
        final ProviderBatchResult<VideoSubtitleCandidate> result =
            await client.search(VideoSubtitleSearchRequest(
          media: _media(imdbId: 'tt1', tmdbId: 2),
        ));
        return result.failures.singleOrNull;
      }

      final ExternalProviderFailure? unauthorized = await run(http.Response(
          '{"status":false,"statusCode":403,"error":"not_authorized"}', 403));
      expect(unauthorized?.kind, ExternalProviderFailureKind.unauthorized);
      expect(calls, 1, reason: '鉴权失败不得被片名兜底掩盖');
      expect(unauthorized?.message, isNot(contains('k=')));

      final ExternalProviderFailure? quota = await run(http.Response(
          '{"status":false,"error":"daily_limit"}', 429,
          headers: <String, String>{'retry-after': '120'}));
      expect(quota?.kind, ExternalProviderFailureKind.quotaExceeded);
      expect(quota?.retryAfter, const Duration(seconds: 120));

      final ExternalProviderFailure? rate = await run(
          http.Response('{"status":false,"error":"rate_limit"}', 429));
      expect(rate?.kind, ExternalProviderFailureKind.rateLimited);
      expect(rate?.retryable, isTrue);

      final ExternalProviderFailure? invalid =
          await run(http.Response('<html>', 200));
      expect(invalid?.kind, ExternalProviderFailureKind.invalidResponse);
    });
  });

  group('extractSubdlSubtitles / pickSubdlSubtitle', () {
    test('unzips text subtitles and skips AppleDouble / non-text entries', () {
      final List<SubdlExtractedSubtitle> files = extractSubdlSubtitles(
        _zip(<String, String>{
          '__MACOSX/._a.srt': 'junk',
          'sub/._b.srt': 'junk',
          'readme.txt': 'notes',
          'Show.S01E01.srt': '1\n00:00:00,000 --> 00:00:01,000\nhi\n',
          'Show.S01E02.ass': '[Script Info]',
        }),
        fallbackFileName: 'x.srt',
      );
      expect(files.map((SubdlExtractedSubtitle f) => f.fileName),
          <String>['Show.S01E01.srt', 'Show.S01E02.ass']);
      expect(utf8.decode(files.first.bytes), contains('hi'));
    });

    test('raw subtitle body passes through with the fallback name', () {
      final List<SubdlExtractedSubtitle> files = extractSubdlSubtitles(
        Uint8List.fromList(utf8.encode('1\n00:00:00,000 --> 00:00:01,000\n')),
        fallbackFileName: 'release.srt',
      );
      expect(files.single.fileName, 'release.srt');
    });

    test('RAR disguised as zip is reported as unsupported, not saved', () {
      expect(
        () => extractSubdlSubtitles(
          Uint8List.fromList(<int>[0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]),
          fallbackFileName: 'x.srt',
        ),
        throwsA(isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.unsupported)),
      );
    });

    test('picks the wanted episode from a season pack', () {
      final List<SubdlExtractedSubtitle> files = <SubdlExtractedSubtitle>[
        for (int i = 1; i <= 3; i++)
          SubdlExtractedSubtitle(
              fileName: 'Show.S01E0$i.srt', bytes: Uint8List(0)),
      ];
      expect(pickSubdlSubtitle(files, episode: 2)?.fileName, 'Show.S01E02.srt');
      expect(pickSubdlSubtitle(files, episode: 9)?.fileName, 'Show.S01E01.srt',
          reason: '匹配不到退回第一个');
      expect(pickSubdlSubtitle(files)?.fileName, 'Show.S01E01.srt');
      expect(pickSubdlSubtitle(const <SubdlExtractedSubtitle>[]), isNull);
    });
  });

  group('SubdlClient.download', () {
    test('fetches the zip anonymously from dl.subdl.com and unpacks it',
        () async {
      final List<http.BaseRequest> seen = <http.BaseRequest>[];
      final SubdlClient client = SubdlClient(
        apiKey: 'secret',
        client: MockClient((http.Request request) async {
          seen.add(request);
          if (request.url.host == 'api.subdl.com') {
            return http.Response(_searchBody, 200);
          }
          expect(
              request.url.toString(), 'https://dl.subdl.com/subtitle/1-12.zip');
          expect(request.url.queryParameters.containsKey('api_key'), isFalse);
          expect(request.headers.containsKey('cookie'), isFalse);
          return http.Response.bytes(
            _zip(<String, String>{
              'GoT.S01E01.srt': 'ep1',
              'GoT.S01E02.srt': 'ep2',
            }),
            200,
            headers: <String, String>{'content-type': 'application/zip'},
          );
        }),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await client.search(VideoSubtitleSearchRequest(
        media: _media(imdbId: 'tt0944947'),
        episode: 2,
      ));
      // 第 2 集：E02 单集 + 整季包；挑整季包验证包内按集号选文件。
      final VideoSubtitleCandidate pack = result.items.firstWhere(
          (VideoSubtitleCandidate c) => c.remoteId.endsWith('12.zip'));
      final VideoSubtitleDownload download = await client.download(pack);
      expect(download.fileName, 'GoT.S01E02.srt');
      expect(utf8.decode(download.bytes), 'ep2');
      expect(download.language, 'zh');
      expect(seen, hasLength(2));
    });

    test('rejects candidates from other providers', () async {
      final SubdlClient client = SubdlClient(
        apiKey: 'k',
        client: MockClient((_) async => http.Response('', 500)),
      );
      expect(
        () => client.download(_ForeignCandidate()),
        throwsA(isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.unsupported)),
      );
    });

    test('download does not spend probe budget', () {
      expect(
        SubdlClient(
                apiKey: 'k',
                client: MockClient((_) async => http.Response('', 500)))
            .allowsFreeProbeDownload,
        isFalse,
      );
    });
  });
}

class _ForeignCandidate extends VideoSubtitleCandidate {
  _ForeignCandidate()
      : super(
          providerId: 'other',
          remoteId: '1',
          fileName: 'a.srt',
          language: 'en',
          providerPriority: 1,
        );
}
