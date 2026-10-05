import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

import 'nyaa_html_fixture.dart';

void main() {
  test('Nyaa adapter preserves release fields and resolves a magnet', () async {
    final NyaaVideoResourceProvider provider = NyaaVideoResourceProvider(
      client: NyaaClient(
        minRequestInterval: Duration.zero,
        client: MockClient((http.Request request) async {
          expect(request.url.queryParameters['q'], 'Test Show');
          return http.Response(_nyaaPage, 200);
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
        minRequestInterval: Duration.zero,
        client: MockClient((http.Request request) async {
          queries.add(request.url.queryParameters['q']!);
          return http.Response(_nyaaPage, 200);
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
      ),
    );

    expect(queries, <String>['Death Note', 'デスノート']);
    expect(result.items, hasLength(1));
    expect(result.failures, isEmpty);
  });

  // BUG-2794：显式词只是候选之一。资源页会把首选词预填进搜索框，旧契约「有显式
  // 词就只搜显式词」让预填的日文原名覆盖掉作品的罗马字别名（Nyaa 0 条）。
  for (final (String query, List<String> expected) in <(String, List<String>)>[
    // 作品自己的标题（非拉丁）→ 补查罗马字 + 日文原名。
    ('死亡笔记', <String>['死亡笔记', 'Death Note', 'デスノート']),
    ('デスノート', <String>['デスノート', 'Death Note']),
    // 作品的已知拉丁别名 → 也补查日文原名。
    ('DEATH NOTE', <String>['DEATH NOTE', 'デスノート']),
    // 用户手输的非拉丁词 → Nyaa 发布名多为罗马字，补查别名。
    ('死亡笔记 第二季', <String>['死亡笔记 第二季', 'Death Note', 'デスノート']),
    // 用户手输的拉丁词是在收窄，不补查。
    ('Death Note 1080p -batch', <String>['Death Note 1080p -batch']),
  ]) {
    test('Nyaa explicit query plus work spellings: $query', () async {
      final List<String> queries = <String>[];
      final NyaaVideoResourceProvider provider = NyaaVideoResourceProvider(
        client: NyaaClient(
          minRequestInterval: Duration.zero,
          client: MockClient((http.Request request) async {
            queries.add(request.url.queryParameters['q']!);
            return http.Response(_nyaaPage, 200);
          }),
        ),
      );
      addTearDown(provider.close);
      // 没有作品身份（纯关键词搜索）时只有显式词可查。
      await provider.search(VideoResourceSearchRequest(query: '  $query  '));
      expect(queries, <String>[query]);
      queries.clear();

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
          query: '  $query  ',
        ),
      );
      expect(queries, expected);
      expect(result.failures, isEmpty);
      // 每条查询都回同一个种子：按 infohash 去重后只剩一条。
      expect(result.items, hasLength(1));
    });
  }

  test('Jimaku adapter searches, keeps text subtitles and season packs, and '
      'downloads',
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
            // 带集号的列表之外，还会再列一次全表补回整季压缩包（BUG-2956）。
            expect(
              request.url.queryParameters['episode'],
              anyOf('2', isNull),
            );
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
    // 文本字幕之外的非字幕文件仍滤掉；zip 整季包现在作为整季包候选列出。
    expect(result.items, hasLength(2));
    final VideoSubtitleCandidate text = result.items
        .firstWhere((VideoSubtitleCandidate c) => !c.isArchivePack);
    expect(text.episode, 2);
    expect(
      result.items
          .singleWhere((VideoSubtitleCandidate c) => c.isArchivePack)
          .fileName,
      'archive.zip',
    );
    final VideoSubtitleDownload download = await provider.download(text);
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
}

/// 一条 trusted 结果的 HTML 搜索页（id `1` → pageUrl `https://nyaa.si/view/1`）。
final String _nyaaPage = nyaaSearchHtml(const <NyaaHtmlRow>[
  NyaaHtmlRow(
    title: '[Group] Test Show - 02 [1080p]',
    infoHash: '0123456789abcdef0123456789abcdef01234567',
    id: '1',
    seeders: 15,
    leechers: 2,
    downloads: 100,
    size: '1.4 GiB',
    categoryId: '1_2',
    trusted: true,
  ),
]);
