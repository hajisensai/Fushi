// BUG-2794：发现页搜视频资源「只有一个源有结果、Nyaa 没结果」。
//
// 三条根因各钉一层：
// ① Nyaa 查询词按源生成：预填的日文原名不再覆盖作品的罗马字拼写，多拼写各查
//    一次、按 infohash 合并；
// ② registry 交出逐源回执：每个源发了哪些词、各几条、失败原因，成功 0 条也在；
// ③ Nyaa HTML 一行坏只跳过该行，不再整页失败。
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

import 'nyaa_html_fixture.dart';

/// TMDB 列表卡片的形状：只有中文展示名 + 日文原名，没有罗马字。
VideoMediaReference _tmdbFrieren({
  Iterable<String> aliases = const <String>['葬送のフリーレン'],
}) => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '209867',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: '葬送的芙莉莲',
  originalTitle: '葬送のフリーレン',
  aliases: aliases,
  tmdbId: 209867,
);

/// Nyaa 对罗马字查询有结果，对 CJK 查询回「No results found」（实测形状）。
MockClient _nyaaServer(List<String> queries) =>
    MockClient((http.Request request) async {
      final String query = request.url.queryParameters['q']!;
      queries.add(query);
      if (!query.contains('Frieren')) {
        return http.Response(kNyaaNoResultsHtml, 200);
      }
      return http.Response(
        nyaaSearchHtml(<NyaaHtmlRow>[
          NyaaHtmlRow(
            title: '[SubsPlease] Sousou no Frieren - 01 (1080p)',
            infoHash: 'a' * 40,
            id: '1',
            seeders: 30,
          ),
          NyaaHtmlRow(
            title: '[SubsPlease] Sousou no Frieren - 02 (1080p)',
            infoHash: 'b' * 40,
            id: '2',
            seeders: 20,
          ),
        ]),
        200,
      );
    });

class _TimeoutProvider implements VideoResourceProvider {
  @override
  String get id => 'torznab';
  @override
  int get priority => 300;
  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};
  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async => ProviderBatchResult<VideoResourceCandidate>.failure(
    const ExternalProviderFailure(
      providerId: 'torznab',
      operation: 'search',
      kind: ExternalProviderFailureKind.timeout,
      message: 'timed out',
    ),
  );
  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) =>
      throw UnimplementedError();
  @override
  void close() {}
}

class _RecordingLog implements EngineLogSink {
  final List<String> diagnostics = <String>[];
  @override
  void log(String source, Object error, [StackTrace? stack]) {}
  @override
  void logDiagnostic(String source, Object info) =>
      diagnostics.add('$source: $info');
  @override
  void logFatal(String source, Object error, [StackTrace? stack]) {}
}

void main() {
  group('nyaaSearchQueries', () {
    test('预填的日文原名是已知标题：补查罗马字拼写', () {
      final VideoMediaReference media = _tmdbFrieren(
        aliases: const <String>['Sousou no Frieren', '葬送のフリーレン'],
      );
      expect(
        nyaaSearchQueries(
          VideoResourceSearchRequest(media: media, query: '葬送のフリーレン'),
        ),
        <String>['葬送のフリーレン', 'Sousou no Frieren'],
      );
    });

    test('用户手输中文译名（非拉丁）也补查作品拼写', () {
      final VideoMediaReference media = _tmdbFrieren(
        aliases: const <String>['Sousou no Frieren', '葬送のフリーレン'],
      );
      expect(
        nyaaSearchQueries(
          VideoResourceSearchRequest(media: media, query: '芙莉莲 第二季'),
        ),
        <String>['芙莉莲 第二季', 'Sousou no Frieren', '葬送のフリーレン'],
      );
    });

    test('用户手输的拉丁词是在收窄：只搜它', () {
      expect(
        nyaaSearchQueries(
          VideoResourceSearchRequest(
            media: _tmdbFrieren(),
            query: 'Frieren S2 1080p',
          ),
        ),
        <String>['Frieren S2 1080p'],
      );
    });

    test('全角 / 大小写 / 空白差异仍认作同一个已知标题', () {
      expect(
        nyaaSearchQueries(
          VideoResourceSearchRequest(
            media: _tmdbFrieren(aliases: const <String>['Sousou no Frieren']),
            query: 'ＳＯＵＳＯＵ  no frieren',
          ),
        ),
        <String>['ＳＯＵＳＯＵ  no frieren', '葬送のフリーレン'],
      );
    });
  });

  group('NyaaVideoResourceProvider 逐查询回执', () {
    test('日文原名 0 条 + 罗马字 2 条：合并去重、逐词计数', () async {
      final List<String> queries = <String>[];
      final NyaaVideoResourceProvider provider = NyaaVideoResourceProvider(
        client: NyaaClient(
          minRequestInterval: Duration.zero,
          client: _nyaaServer(queries),
        ),
      );
      addTearDown(provider.close);
      final ProviderBatchResult<VideoResourceCandidate> result = await provider
          .search(
            VideoResourceSearchRequest(
              media: _tmdbFrieren(
                aliases: const <String>['Sousou no Frieren', '葬送のフリーレン'],
              ),
              query: '葬送のフリーレン',
            ),
          );
      expect(queries, <String>['葬送のフリーレン', 'Sousou no Frieren']);
      expect(result.items, hasLength(2));
      expect(result.successfulProviderCount, 1);
      final VideoResourceSourceReport report =
          (result as VideoResourceSearchResult).sources.single;
      expect(report.providerId, kNyaaResourceProviderId);
      expect(report.succeeded, isTrue);
      expect(report.itemCount, 2);
      expect(
        report.queries.map(
          (VideoResourceQueryReport q) => '${q.query}=${q.itemCount}',
        ),
        <String>['葬送のフリーレン=0', 'Sousou no Frieren=2'],
      );
    });

    test('一条查询失败、另一条成功：成功照交，失败记在该查询上', () async {
      final NyaaVideoResourceProvider provider = NyaaVideoResourceProvider(
        client: NyaaClient(
          minRequestInterval: Duration.zero,
          client: MockClient((http.Request request) async {
            if (request.url.queryParameters['q'] == '葬送のフリーレン') {
              return http.Response('', 503);
            }
            return http.Response(
              nyaaSearchHtml(<NyaaHtmlRow>[
                NyaaHtmlRow(title: 'Frieren - 01', infoHash: 'a' * 40, id: '1'),
                NyaaHtmlRow(title: 'Frieren - 02', infoHash: 'b' * 40, id: '2'),
              ]),
              200,
            );
          }),
        ),
      );
      addTearDown(provider.close);
      final VideoResourceSearchResult result =
          await provider.search(
                VideoResourceSearchRequest(
                  media: _tmdbFrieren(
                    aliases: const <String>['Sousou no Frieren', '葬送のフリーレン'],
                  ),
                  query: '葬送のフリーレン',
                ),
              )
              as VideoResourceSearchResult;
      expect(result.items, hasLength(2));
      expect(result.isPartial, isTrue);
      final VideoResourceSourceReport report = result.sources.single;
      expect(report.succeeded, isTrue);
      expect(report.queries.first.failure, isNotNull);
      expect(report.queries.last.failure, isNull);
    });
  });

  group('VideoResourceRegistry 逐源回执', () {
    test('每个参与的源一份：Nyaa 0 条可见、失败源带原因', () async {
      final VideoResourceRegistry registry =
          VideoResourceRegistry(<VideoResourceProvider>[
            NyaaVideoResourceProvider(
              client: NyaaClient(
                minRequestInterval: Duration.zero,
                client: _nyaaServer(<String>[]),
              ),
            ),
            _TimeoutProvider(),
          ]);
      addTearDown(registry.close);
      // 没有罗马字别名的 TMDB 卡片 + 预填日文原名：Nyaa 如实报 0 条。
      final VideoResourceSearchResult result = await registry.search(
        VideoResourceSearchRequest(media: _tmdbFrieren(), query: '葬送のフリーレン'),
      );
      expect(
        result.sources.map((VideoResourceSourceReport r) => r.providerId),
        <String>[kNyaaResourceProviderId, 'torznab'],
      );
      final VideoResourceSourceReport nyaa = result.sources.first;
      expect(nyaa.succeeded, isTrue);
      expect(nyaa.itemCount, 0);
      expect(nyaa.queries.single.query, '葬送のフリーレン');
      final VideoResourceSourceReport torznab = result.sources.last;
      expect(torznab.failed, isTrue);
      expect(torznab.failures.single.kind, ExternalProviderFailureKind.timeout);
      expect(torznab.queries.single.query, '葬送のフリーレン');
    });
  });

  group('Nyaa HTML 坏行', () {
    late EngineLogSink previous;
    late _RecordingLog log;
    setUp(() {
      previous = engineLog;
      log = _RecordingLog();
      engineLog = log;
    });
    tearDown(() => engineLog = previous);

    test('一行缺 infohash：跳过该行并记诊断，其余照常返回', () async {
      final NyaaClient client = NyaaClient(
        minRequestInterval: Duration.zero,
        client: MockClient(
          (http.Request request) async => http.Response(
            nyaaSearchHtml(<NyaaHtmlRow>[
              NyaaHtmlRow(title: 'good', infoHash: 'c' * 40, id: '1'),
              const NyaaHtmlRow(title: 'broken', infoHash: 'zz', id: '2'),
            ]),
            200,
          ),
        ),
      );
      addTearDown(client.close);
      final List<NyaaTorrent> torrents = await client.search('x');
      expect(torrents.map((NyaaTorrent t) => t.title), <String>['good']);
      expect(log.diagnostics, hasLength(1));
      expect(log.diagnostics.single, contains('skipped 1 of 2'));
    });

    test('每一行都坏：页面结构变了，仍然抛而不是伪装成 0 条', () async {
      final NyaaClient client = NyaaClient(
        minRequestInterval: Duration.zero,
        client: MockClient(
          (http.Request request) async => http.Response(
            nyaaSearchHtml(const <NyaaHtmlRow>[
              NyaaHtmlRow(title: 'broken', infoHash: 'zz', id: '2'),
            ]),
            200,
          ),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.search('x'),
        throwsA(
          isA<NyaaFeedFormatException>().having(
            (NyaaFeedFormatException e) => e.code,
            'code',
            NyaaFeedErrorCode.missingField,
          ),
        ),
      );
    });
  });
}
