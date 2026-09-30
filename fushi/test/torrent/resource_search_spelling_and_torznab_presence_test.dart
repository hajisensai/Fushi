// BUG-2818：资源搜索页「FX戦士くるみちゃん」Nyaa 两个词都 0 条、Torznab 显示
// 「未参与（该来源无法搜索这个查询词）」。
//
// ① Nyaa 只查元数据排第一的拉丁拼写。TMDB 的 JP 区别名是官方风格化写法
//    `FX Senshi KURUMICHAN`，发布名却是 `FX Senshi Kurumi-chan`（实测 Nyaa 对前者
//    0 条、对后者有 Bizmillah / ToonsHub 两条）。现在补查全部不同的拉丁拼写。
// ② 零索引器的 TorznabClient 被无条件注册，「成功 0 次、失败 0 次」被读成
//    「无法搜索这个查询词」。现在没有启用的索引器就不注册。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

import 'nyaa_html_fixture.dart';

/// 资源页补齐别名后的 TMDB 卡片：罗马字（TMDB JP 别名）→ 英文名，原名是日文。
VideoMediaReference _kurumi() => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '311842',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: 'FX战士胡桃酱',
  originalTitle: 'FX戦士くるみちゃん',
  aliases: const <String>[
    'FX Senshi KURUMICHAN',
    'FX Fighter Kurumi-chan',
    'FX戦士くるみちゃん',
  ],
  tmdbId: 311842,
);

/// 与实测一致：Nyaa 只对带 `Kurumi-chan` 的词有结果。
MockClient _nyaaServer(List<String> queries) =>
    MockClient((http.Request request) async {
      final String query = request.url.queryParameters['q']!;
      queries.add(query);
      if (!query.contains('Kurumi-chan')) {
        return http.Response(kNyaaNoResultsHtml, 200);
      }
      return http.Response(
        nyaaSearchHtml(<NyaaHtmlRow>[
          NyaaHtmlRow(
            title: '[Bizmillah] FX Senshi Kurumi-chan - 01 (Pre-Air)',
            infoHash: 'a' * 40,
            id: '1',
          ),
        ]),
        200,
      );
    });

TorznabIndexerConfig _indexer({required bool enabled}) => TorznabIndexerConfig(
  id: 'jackett',
  name: 'Jackett',
  endpoint: Uri.parse('https://j/api'),
  apiKey: 'k',
  enabled: enabled,
);

void main() {
  group('Nyaa 补查全部拉丁拼写', () {
    test('预填的风格化罗马字是已知标题：英文名与日文原名都补查', () {
      expect(
        nyaaSearchQueries(
          VideoResourceSearchRequest(
            media: _kurumi(),
            query: 'FX Senshi KURUMICHAN',
          ),
        ),
        <String>[
          'FX Senshi KURUMICHAN',
          'FX Fighter Kurumi-chan',
          'FX戦士くるみちゃん',
        ],
      );
    });

    test('无显式词（资源页 chip）也列出全部拉丁拼写', () {
      expect(
        nyaaSearchQueries(VideoResourceSearchRequest(media: _kurumi())),
        <String>[
          'FX Senshi KURUMICHAN',
          'FX Fighter Kurumi-chan',
          'FX戦士くるみちゃん',
        ],
      );
    });

    test('首选词契约不变：罗马字与日文各一个（预填 / 订阅默认词）', () {
      expect(
        preferredNyaaSearchQueries(
          VideoResourceSearchRequest(media: _kurumi()),
        ),
        <String>['FX Senshi KURUMICHAN', 'FX戦士くるみちゃん'],
      );
    });

    test('拉丁拼写至多查 kNyaaMaxRomanizedQueries 个', () {
      final VideoMediaReference media = VideoMediaReference(
        providerId: 'tmdb',
        mediaId: '1',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'A',
        aliases: const <String>['B', 'C', 'D', 'E'],
      );
      final List<String> queries = nyaaSearchQueries(
        VideoResourceSearchRequest(media: media),
      );
      expect(queries, hasLength(kNyaaMaxRomanizedQueries));
      expect(queries, <String>['B', 'C', 'D']);
    });

    test('端到端：风格化罗马字 0 条时英文名那一查交出结果', () async {
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
              media: _kurumi(),
              query: 'FX Senshi KURUMICHAN',
            ),
          );
      expect(queries, <String>[
        'FX Senshi KURUMICHAN',
        'FX Fighter Kurumi-chan',
        'FX戦士くるみちゃん',
      ]);
      expect(result.items, hasLength(1));
      final VideoResourceSourceReport report =
          (result as VideoResourceSearchResult).sources.single;
      expect(
        report.queries.map(
          (VideoResourceQueryReport q) => '${q.query}=${q.itemCount}',
        ),
        <String>[
          'FX Senshi KURUMICHAN=0',
          'FX Fighter Kurumi-chan=1',
          'FX戦士くるみちゃん=0',
        ],
      );
    });
  });

  group('Torznab 没有启用的索引器就不是一个源', () {
    test('torznabHasEnabledIndexer：空 / 全停用为假，有一个启用为真', () {
      expect(torznabHasEnabledIndexer(const <TorznabIndexerConfig>[]), isFalse);
      expect(
        torznabHasEnabledIndexer(<TorznabIndexerConfig>[
          _indexer(enabled: false),
        ]),
        isFalse,
      );
      expect(
        torznabHasEnabledIndexer(<TorznabIndexerConfig>[
          _indexer(enabled: false),
          _indexer(enabled: true),
        ]),
        isTrue,
      );
    });

    test('零索引器的 TorznabClient 正是「未参与」形状（所以不能注册它）', () async {
      final TorznabClient empty = TorznabClient(
        indexers: const <TorznabIndexerConfig>[],
        client: MockClient((_) async => http.Response('', 500)),
      );
      final VideoResourceRegistry registry = VideoResourceRegistry(
        <VideoResourceProvider>[empty],
      );
      addTearDown(registry.close);
      final VideoResourceSearchResult result = await registry.search(
        VideoResourceSearchRequest(media: _kurumi(), query: 'Kurumi-chan'),
      );
      expect(result.sources.single.skipped, isTrue);
    });

    test('app 与服务端装配 registry 都先过 torznabHasEnabledIndexer', () {
      final Directory repoRoot = Directory.current.parent;
      for (final String path in <String>[
        'fushi/lib/src/models/app_model.dart',
        'packages/fushi_server/lib/src/download_host.dart',
      ]) {
        final String source = File('${repoRoot.path}/$path').readAsStringSync();
        final int construct = source.indexOf('TorznabClient(');
        expect(construct, isNonNegative, reason: path);
        final int gate = source.lastIndexOf(
          'if (torznabHasEnabledIndexer(',
          construct,
        );
        expect(gate, isNonNegative, reason: '$path 无条件注册了 TorznabClient');
        expect(
          source.substring(gate, construct).contains(';'),
          isFalse,
          reason: '$path 的门与构造之间隔了别的语句',
        );
      }
    });
  });
}
