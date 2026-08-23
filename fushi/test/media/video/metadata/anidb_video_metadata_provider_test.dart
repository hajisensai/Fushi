import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/anidb_title_catalog.dart';
import 'package:fushi/src/media/video/metadata/anidb_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('AniDbTitleCatalog', () {
    test(
      'decodes the official gzip XML and ranks exact, prefix, similarity',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'fushi-anidb-titles-',
        );
        addTearDown(() => directory.delete(recursive: true));
        int downloads = 0;
        final DateTime now = DateTime.utc(2026, 8, 23, 12);
        final AniDbTitleCatalog catalog = AniDbTitleCatalog(
          cacheDirectory: directory,
          sourceUrl: Uri.parse('https://example.test/anime-titles.xml.gz'),
          now: () => now,
          client: MockClient((http.Request request) async {
            downloads++;
            return http.Response.bytes(
              gzip.encode(utf8.encode(_titleCatalogXml)),
              200,
              headers: const <String, String>{
                'content-type': 'application/gzip',
              },
            );
          }),
        );
        addTearDown(catalog.close);

        final List<AniDbTitleSearchResult> exact = await catalog.search(
          '无职转生',
          limit: 5,
        );
        expect(exact.first.record.animeId, 1);
        expect(exact.first.kind, AniDbTitleMatchKind.exact);
        expect(exact.first.matchedTitle.type, 'official');
        expect(
          exact.first.record.titles.any(
            (AniDbTitle title) =>
                title.type == 'official' && title.language == 'zh-Hans',
          ),
          isTrue,
        );

        final List<AniDbTitleSearchResult> prefix = await catalog.search(
          'Mushoku Tensei',
          limit: 5,
        );
        expect(
          prefix
              .take(2)
              .map((AniDbTitleSearchResult value) => value.record.animeId),
          <int>[1, 2],
        );
        expect(prefix.first.kind, AniDbTitleMatchKind.exact);
        expect(prefix[1].kind, AniDbTitleMatchKind.prefix);

        final List<AniDbTitleSearchResult> similar = await catalog.search(
          'Violett Evergardan',
          limit: 1,
        );
        expect(similar.single.record.animeId, 42);
        expect(similar.single.kind, AniDbTitleMatchKind.similar);
        expect(
          downloads,
          1,
          reason: 'the parsed catalog stays cached in memory',
        );
      },
    );

    test(
      'keeps a stale parseable cache when the daily refresh fails',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'fushi-anidb-stale-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final DateTime now = DateTime.utc(2026, 8, 23, 12);
        final AniDbTitleCatalog initial = AniDbTitleCatalog(
          cacheDirectory: directory,
          now: () => now,
          client: MockClient(
            (http.Request request) async => http.Response.bytes(
              gzip.encode(utf8.encode(_titleCatalogXml)),
              200,
            ),
          ),
        );
        await initial.search('Violet Evergarden');
        initial.close();
        final File cache = File(
          '${directory.path}${Platform.pathSeparator}'
          '${AniDbTitleCatalog.cacheFileName}',
        );
        await cache.setLastModified(now.subtract(const Duration(hours: 25)));
        int refreshAttempts = 0;
        final AniDbTitleCatalog stale = AniDbTitleCatalog(
          cacheDirectory: directory,
          now: () => now,
          client: MockClient((http.Request request) async {
            refreshAttempts++;
            throw const SocketException('offline');
          }),
        );
        addTearDown(stale.close);

        expect(
          (await stale.search('Violet Evergarden')).first.record.animeId,
          42,
        );
        expect(refreshAttempts, 1);

        stale.close();
        final AniDbTitleCatalog reopened = AniDbTitleCatalog(
          cacheDirectory: directory,
          now: () => now,
          client: MockClient((http.Request request) async {
            refreshAttempts++;
            throw const SocketException('offline');
          }),
        );
        addTearDown(reopened.close);

        expect(
          (await reopened.search('Violet Evergarden')).first.record.animeId,
          42,
        );
        expect(
          refreshAttempts,
          1,
          reason: 'the persisted failure marker gates retries across instances',
        );
      },
    );
  });

  group('AniDbVideoMetadataProvider', () {
    test(
      'without a client identity returns title identity and skips HTTP API',
      () async {
        final _CatalogFixture fixture = await _catalogFixture();
        addTearDown(fixture.dispose);
        int apiCalls = 0;
        final AniDbVideoMetadataProvider provider = AniDbVideoMetadataProvider(
          clientName: '',
          clientVersion: null,
          language: 'zh-CN',
          titleCatalog: fixture.catalog,
          client: MockClient((http.Request request) async {
            apiCalls++;
            throw StateError('HTTP API must not be called without an identity');
          }),
        );
        addTearDown(provider.close);

        expect(provider.isAvailable, isTrue);
        expect(provider.isHttpApiAvailable, isFalse);
        final VideoMetadataWork work = (await provider.fetchWork(
          const VideoMetadataLookup(
            provider: VideoMetadataProviderKind.anidb,
            externalId: '42',
            mediaKind: VideoMetadataMediaKind.tv,
          ),
        ))!;

        expect(work.title, '紫罗兰永恒花园');
        expect(work.ids.single.type, 'anidb');
        expect(work.ids.single.value, '42');
        expect(apiCalls, 0);
      },
    );

    test(
      'without a client identity returns null for an id absent from catalog',
      () async {
        final _CatalogFixture fixture = await _catalogFixture();
        addTearDown(fixture.dispose);
        int apiCalls = 0;
        final AniDbVideoMetadataProvider provider = AniDbVideoMetadataProvider(
          clientName: '',
          clientVersion: null,
          titleCatalog: fixture.catalog,
          client: MockClient((http.Request request) async {
            apiCalls++;
            throw StateError('HTTP API must not be called without an identity');
          }),
        );
        addTearDown(provider.close);

        final VideoMetadataWork? work = await provider.fetchWork(
          const VideoMetadataLookup(
            provider: VideoMetadataProviderKind.anidb,
            externalId: '999',
            mediaKind: VideoMetadataMediaKind.tv,
          ),
        );

        expect(work, isNull);
        expect(apiCalls, 0);
      },
    );

    test(
      'falls back to catalog identity when the configured HTTP API fails',
      () async {
        final _CatalogFixture fixture = await _catalogFixture();
        addTearDown(fixture.dispose);
        int apiCalls = 0;
        final AniDbVideoMetadataProvider provider = AniDbVideoMetadataProvider(
          clientName: 'fushitest',
          clientVersion: 7,
          language: 'zh-CN',
          titleCatalog: fixture.catalog,
          client: MockClient((http.Request request) async {
            apiCalls++;
            return http.Response('temporarily unavailable', 503);
          }),
        );
        addTearDown(provider.close);

        final VideoMetadataWork? work = await provider.fetchWork(
          const VideoMetadataLookup(
            provider: VideoMetadataProviderKind.anidb,
            externalId: '42',
            mediaKind: VideoMetadataMediaKind.tv,
          ),
        );

        expect(work?.title, '紫罗兰永恒花园');
        expect(work?.ids.single.type, 'anidb');
        expect(work?.ids.single.value, '42');
        expect(work?.year, isNull,
            reason: 'catalog fallback has no fake detail');
        expect(apiCalls, 1);
      },
    );

    test(
      'uses the injected registered client and maps anime plus episodes',
      () async {
        final _CatalogFixture fixture = await _catalogFixture();
        addTearDown(fixture.dispose);
        Uri? requestedUri;
        int apiCalls = 0;
        final AniDbVideoMetadataProvider provider = AniDbVideoMetadataProvider(
          clientName: 'FushiTest',
          clientVersion: 7,
          language: 'zh-CN',
          titleCatalog: fixture.catalog,
          client: MockClient((http.Request request) async {
            apiCalls++;
            requestedUri = request.url;
            return http.Response.bytes(
              utf8.encode(_animeXml),
              200,
              headers: const <String, String>{
                'content-type': 'application/xml',
              },
            );
          }),
        );
        addTearDown(provider.close);
        const VideoMetadataLookup lookup = VideoMetadataLookup(
          provider: VideoMetadataProviderKind.anidb,
          externalId: '42',
          mediaKind: VideoMetadataMediaKind.tv,
        );

        final VideoMetadataWork work = (await provider.fetchWork(lookup))!;
        final List<VideoMetadataSeason> seasons = await provider.fetchSeasons(
          lookup,
        );
        final List<VideoMetadataEpisode> episodes =
            await provider.fetchEpisodes(lookup, seasonNumber: 1);

        expect(
          requestedUri?.queryParameters,
          containsPair('client', 'fushitest'),
        );
        expect(requestedUri?.queryParameters, containsPair('clientver', '7'));
        expect(requestedUri?.queryParameters, containsPair('protover', '1'));
        expect(requestedUri?.queryParameters, containsPair('request', 'anime'));
        expect(requestedUri?.queryParameters, containsPair('aid', '42'));
        expect(requestedUri?.queryParameters['client'], isNot('animeplugin'));
        expect(requestedUri?.queryParameters['client'], isNot('ommserver'));
        expect(
          apiCalls,
          1,
          reason: 'work, season and episode share one snapshot',
        );

        expect(work.kind, VideoMetadataMediaKind.tv);
        expect(work.title, '紫罗兰永恒花园');
        expect(work.originalTitle, 'ヴァイオレット・エヴァーガーデン');
        expect(work.year, 2018);
        expect(work.premiered, '2018-01-11');
        expect(work.endDate, '2018-04-05');
        expect(work.rating, 8.61);
        expect(work.ratingVotes, 1234);
        expect(work.episodeCount, 2);
        expect(work.keywords, contains('drama'));
        expect(work.studios, contains('Kyoto Animation'));
        expect(
          work.images.single.url,
          'https://cdn.anidb.net/images/main/12345.jpg',
        );
        expect(
          work.credits.map((VideoMetadataCredit value) => value.kind),
          containsAll(<VideoMetadataCreditKind>[
            VideoMetadataCreditKind.director,
            VideoMetadataCreditKind.writer,
            VideoMetadataCreditKind.voiceActor,
          ]),
        );
        final VideoMetadataCredit voice = work.credits.firstWhere(
          (VideoMetadataCredit value) =>
              value.kind == VideoMetadataCreditKind.voiceActor,
        );
        expect(voice.person.name, 'Ishikawa Yui');
        expect(
          voice.person.profileUrl,
          'https://cdn.anidb.net/images/main/seiyuu.jpg',
        );
        expect(voice.character?.name, 'Violet Evergarden');
        expect(
          voice.character?.imageUrl,
          'https://cdn.anidb.net/images/main/character.jpg',
        );

        expect(work.seasons.single.episodes.length, 2);
        expect(seasons.single.episodes.length, 2);
        expect(
          episodes.map((VideoMetadataEpisode value) => value.title),
          <String>['Not a Tool', 'Never Coming Back'],
        );
        expect(episodes.first.episodeNumber, 1);
        expect(episodes.first.absoluteNumber, 1);
        expect(episodes.first.runtimeMinutes, 24);
        expect(episodes.first.rating, 8.2);
        expect(episodes.first.ratingVotes, 99);
        expect(episodes.first.airDate, '2018-01-11');
      },
    );

    test(
      'configured HTTP keeps a single-file OVA in the requested movie shape',
      () async {
        final _CatalogFixture fixture = await _catalogFixture();
        addTearDown(fixture.dispose);
        final AniDbVideoMetadataProvider provider = AniDbVideoMetadataProvider(
          clientName: 'fushitest',
          clientVersion: 7,
          titleCatalog: fixture.catalog,
          client: MockClient(
            (http.Request request) async => http.Response.bytes(
              utf8.encode(
                _animeXml.replaceFirst(
                  '<type>TV Series</type>',
                  '<type>OVA</type>',
                ),
              ),
              200,
            ),
          ),
        );
        addTearDown(provider.close);
        const VideoMetadataLookup lookup = VideoMetadataLookup(
          provider: VideoMetadataProviderKind.anidb,
          externalId: '42',
          mediaKind: VideoMetadataMediaKind.movie,
        );

        final VideoMetadataResolution result = await VideoMetadataResolver(
          registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
            provider,
          ]),
        ).resolve(
          VideoMetadataResolveRequest(
            selectedProvider: VideoMetadataProviderKind.anidb,
            mediaKind: VideoMetadataMediaKind.movie,
            titleCandidates: const <String>['Violet Evergarden OVA'],
            confirmedLookup: lookup,
          ),
        );

        expect(result.status, VideoMetadataResolutionStatus.matched);
        expect(result.work?.kind, VideoMetadataMediaKind.movie);
        expect(result.work?.seasons, isEmpty);
        expect(result.work?.runtimeMinutes, 24);
      },
    );

    test('episode hydration exposes AniDB HTTP failures', () async {
      final _CatalogFixture fixture = await _catalogFixture();
      addTearDown(fixture.dispose);
      int apiCalls = 0;
      final AniDbVideoMetadataProvider provider = AniDbVideoMetadataProvider(
        clientName: 'fushitest',
        clientVersion: 7,
        titleCatalog: fixture.catalog,
        client: MockClient((http.Request request) async {
          apiCalls++;
          return http.Response('temporarily unavailable', 503);
        }),
      );
      addTearDown(provider.close);

      await expectLater(
        provider.fetchEpisodes(
          const VideoMetadataLookup(
            provider: VideoMetadataProviderKind.anidb,
            externalId: '42',
            mediaKind: VideoMetadataMediaKind.tv,
          ),
          seasonNumber: 1,
        ),
        throwsA(isA<VideoMetadataNetworkException>()),
      );
      expect(apiCalls, 1);
    });

    test(
      'serializes provider instances across client identities by endpoint',
      () async {
        final _CatalogFixture fixture = await _catalogFixture();
        addTearDown(fixture.dispose);
        DateTime clock = DateTime.utc(2026, 8, 23, 12);
        final List<DateTime> requestStarts = <DateTime>[];
        final List<Duration> sleeps = <Duration>[];
        int activeRequests = 0;
        int maxActiveRequests = 0;
        Future<http.Response> handle(http.Request request) async {
          requestStarts.add(clock);
          activeRequests++;
          if (activeRequests > maxActiveRequests) {
            maxActiveRequests = activeRequests;
          }
          await Future<void>.delayed(Duration.zero);
          activeRequests--;
          final String aid = request.url.queryParameters['aid']!;
          return http.Response.bytes(
            utf8.encode(
              _animeXml.replaceFirst('<anime id="42"', '<anime id="$aid"'),
            ),
            200,
          );
        }

        AniDbVideoMetadataProvider createProvider(
          String clientName,
          int clientVersion,
        ) =>
            AniDbVideoMetadataProvider(
              clientName: clientName,
              clientVersion: clientVersion,
              apiUrl: 'http://anidb-gate.test/httpapi',
              shareRequestGate: true,
              titleCatalog: fixture.catalog,
              now: () => clock,
              sleep: (Duration duration) async {
                sleeps.add(duration);
                clock = clock.add(duration);
              },
              client: MockClient(handle),
            );

        final AniDbVideoMetadataProvider first =
            createProvider('fushitest-old', 6);
        final AniDbVideoMetadataProvider second =
            createProvider('fushitest-new', 7);
        addTearDown(first.close);
        addTearDown(second.close);

        await Future.wait(<Future<VideoMetadataWork?>>[
          first.fetchWork(
            const VideoMetadataLookup(
              provider: VideoMetadataProviderKind.anidb,
              externalId: '42',
              mediaKind: VideoMetadataMediaKind.tv,
            ),
          ),
          second.fetchWork(
            const VideoMetadataLookup(
              provider: VideoMetadataProviderKind.anidb,
              externalId: '43',
              mediaKind: VideoMetadataMediaKind.tv,
            ),
          ),
        ]);

        expect(maxActiveRequests, 1);
        expect(requestStarts, hasLength(2));
        expect(
          requestStarts[1].difference(requestStarts[0]),
          const Duration(seconds: 3),
        );
        expect(sleeps, <Duration>[const Duration(seconds: 3)]);
      },
    );

    test(
      'rejects wrong provider and invalid AniDB ids before any request',
      () async {
        final _CatalogFixture fixture = await _catalogFixture();
        addTearDown(fixture.dispose);
        int apiCalls = 0;
        final AniDbVideoMetadataProvider provider = AniDbVideoMetadataProvider(
          clientName: 'fushitest',
          clientVersion: 7,
          titleCatalog: fixture.catalog,
          client: MockClient((http.Request request) async {
            apiCalls++;
            return http.Response(_animeXml, 200);
          }),
        );
        addTearDown(provider.close);

        await expectLater(
          provider.fetchWork(
            const VideoMetadataLookup(
              provider: VideoMetadataProviderKind.tmdb,
              externalId: '42',
              mediaKind: VideoMetadataMediaKind.tv,
            ),
          ),
          throwsArgumentError,
        );
        await expectLater(
          provider.fetchWork(
            const VideoMetadataLookup(
              provider: VideoMetadataProviderKind.anidb,
              externalId: 'not-a-number',
              mediaKind: VideoMetadataMediaKind.tv,
            ),
          ),
          throwsArgumentError,
        );
        await expectLater(
          provider.fetchEpisodes(
            const VideoMetadataLookup(
              provider: VideoMetadataProviderKind.anidb,
              externalId: '0',
              mediaKind: VideoMetadataMediaKind.tv,
            ),
            seasonNumber: 1,
          ),
          throwsArgumentError,
        );
        expect(apiCalls, 0);
      },
    );
  });
}

Future<_CatalogFixture> _catalogFixture() async {
  final Directory directory = await Directory.systemTemp.createTemp(
    'fushi-anidb-provider-',
  );
  final AniDbTitleCatalog catalog = AniDbTitleCatalog(
    cacheDirectory: directory,
    client: MockClient(
      (http.Request request) async =>
          http.Response.bytes(gzip.encode(utf8.encode(_titleCatalogXml)), 200),
    ),
  );
  await catalog.search('Violet Evergarden');
  return _CatalogFixture(directory: directory, catalog: catalog);
}

class _CatalogFixture {
  const _CatalogFixture({required this.directory, required this.catalog});

  final Directory directory;
  final AniDbTitleCatalog catalog;

  Future<void> dispose() async {
    catalog.close();
    await directory.delete(recursive: true);
  }
}

const String _titleCatalogXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<animetitles>
  <anime aid="1">
    <title type="main" xml:lang="x-jat">Mushoku Tensei</title>
    <title type="official" xml:lang="ja">無職転生</title>
    <title type="official" xml:lang="zh-Hans">無職転生</title>
  </anime>
  <anime aid="2">
    <title type="main" xml:lang="x-jat">Mushoku Tensei II</title>
  </anime>
  <anime aid="42">
    <title type="main" xml:lang="x-jat">Violet Evergarden</title>
    <title type="official" xml:lang="ja">ヴァイオレット・エヴァーガーデン</title>
    <title type="official" xml:lang="zh-Hans">紫罗兰永恒花园</title>
  </anime>
</animetitles>
''';

const String _animeXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<anime id="42" restricted="false">
  <type>TV Series</type>
  <episodecount>2</episodecount>
  <startdate>2018-01-11</startdate>
  <enddate>2018-04-05</enddate>
  <url>https://anidb.net/anime/42</url>
  <picture>12345.jpg</picture>
  <description>An Auto Memory Doll learns what love means.</description>
  <titles>
    <title type="main" xml:lang="x-jat">Violet Evergarden</title>
    <title type="official" xml:lang="ja">ヴァイオレット・エヴァーガーデン</title>
    <title type="official" xml:lang="zh-Hans">紫罗兰永恒花园</title>
  </titles>
  <ratings>
    <permanent count="1234">8.61</permanent>
  </ratings>
  <tags>
    <tag id="1" weight="500"><name>drama</name></tag>
  </tags>
  <creators>
    <name id="10" type="Direction">Ishidate Taichi</name>
    <name id="11" type="Script">Yoshida Reiko</name>
    <name id="12" type="Animation Work">Kyoto Animation</name>
  </creators>
  <characters>
    <character id="100" type="main character">
      <name>Violet Evergarden</name>
      <description>The protagonist.</description>
      <picture>character.jpg</picture>
      <seiyuu id="200" picture="seiyuu.jpg">Ishikawa Yui</seiyuu>
    </character>
  </characters>
  <episodes>
    <episode id="4201">
      <epno type="1">1</epno>
      <length>24</length>
      <airdate>2018-01-11</airdate>
      <rating votes="99">8.20</rating>
      <summary>Violet starts her new life.</summary>
      <title xml:lang="en">Not a Tool</title>
      <title xml:lang="ja">「愛してる」と自動手記人形</title>
    </episode>
    <episode id="4202">
      <epno type="1">2</epno>
      <length>24</length>
      <airdate>2018-01-18</airdate>
      <title xml:lang="en">Never Coming Back</title>
    </episode>
    <episode id="4299">
      <epno type="2">S1</epno>
      <title xml:lang="en">Special</title>
    </episode>
  </episodes>
</anime>
''';
