import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/sources/nyaa_discovery_source.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';

import '../../../torrent/nyaa_html_fixture.dart';

/// 一条 Literature 英译轻小说（trusted）。
const NyaaHtmlRow _novelRow = NyaaHtmlRow(
  title: 'Some Light Novel Vol.1-3 EPUB',
  infoHash: '0123456789abcdef0123456789abcdef01234567',
  id: '42',
  seeders: 7,
  leechers: 1,
  downloads: 99,
  size: '12.0 MiB',
  categoryId: '3_1',
  trusted: true,
);

/// 同分类里混放的扫图漫画（remake）。
const NyaaHtmlRow _mangaRow = NyaaHtmlRow(
  title: 'Sousou no Frieren v01-14 (Digital) (1r0n)',
  infoHash: 'fedcba9876543210fedcba9876543210fedcba98',
  id: '43',
  seeders: 80,
  size: '2.1 GiB',
  categoryId: '3_1',
  remake: true,
);

NyaaClient _client(
  Future<http.Response> Function(http.Request request) handler, {
  String baseUrl = 'https://nyaa.si',
}) =>
    NyaaClient(
      baseUrl: baseUrl,
      minRequestInterval: Duration.zero,
      client: MockClient(handler),
    );

void main() {
  test('搜索映射:分类按媒体域取,条目产 torrent payload 并透传新字段', () async {
    Uri? captured;
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'nyaa',
      displayName: 'Nyaa',
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.novel: '3_0',
        DiscoveryMediaKind.audiobook: '2_0',
      },
      client: _client((http.Request request) async {
        captured = request.url;
        return http.Response.bytes(
          utf8.encode(nyaaSearchHtml(const <NyaaHtmlRow>[_novelRow])),
          200,
          headers: <String, String>{
            'content-type': 'text/html; charset=utf-8',
          },
        );
      }),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'novel'),
    );

    // 分类本身不改：小说域仍是 Literature 全部。
    expect(captured!.queryParameters['c'], '3_0');
    expect(captured!.queryParameters['q'], 'novel');
    expect(captured!.queryParameters['f'], '0');
    // 首屏走 HTML 搜索页且服务端按做种降序，不再是 RSS。
    expect(captured!.queryParameters.containsKey('page'), isFalse);
    expect(captured!.queryParameters['s'], 'seeders');
    expect(captured!.queryParameters['o'], 'desc');

    final DiscoveryResultPage page = result.items.single;
    expect(page.hasMore, isTrue, reason: '非空页允许翻页');
    final DiscoveryResourceItem item =
        page.entries.single as DiscoveryResourceItem;
    expect(item.sourceId, 'nyaa');
    expect(item.id, 'https://nyaa.si/view/42');
    expect(item.detailUrl, 'https://nyaa.si/view/42');
    expect(item.payloadKind, DiscoveryPayloadKind.torrent);
    final DiscoveryTorrentPayload payload =
        item.payload! as DiscoveryTorrentPayload;
    expect(
      payload.magnetUri,
      contains('xt=urn:btih:0123456789abcdef0123456789abcdef01234567'),
    );
    expect(item.seeders, 7);
    expect(item.leechers, 1);
    expect(item.sizeBytes, 12 * 1024 * 1024);
    // 新字段：源内分类 / trusted / remake / 内容形态。
    expect(item.category, '3_1');
    expect(item.trusted, isTrue);
    expect(item.remake, isFalse);
    expect(item.contentHint, DiscoveryContentHint.novel);
    expect(item.note, isNull, reason: 'trusted 已是带类型字段，不再塞 note');
  });

  test('小说域结果逐条打 contentHint；remake 行 class 透传', () async {
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'nyaa',
      displayName: 'Nyaa',
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.novel: '3_0',
      },
      client: _client(
        (http.Request request) async => http.Response(
          nyaaSearchHtml(const <NyaaHtmlRow>[_novelRow, _mangaRow]),
          200,
        ),
      ),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'x'),
    );
    final List<DiscoveryResourceItem> items =
        result.items.single.entries.cast<DiscoveryResourceItem>();
    expect(items, hasLength(2));
    expect(items[0].contentHint, DiscoveryContentHint.novel);
    expect(items[0].remake, isFalse);
    expect(items[1].contentHint, DiscoveryContentHint.manga);
    expect(items[1].remake, isTrue);
    expect(items[1].trusted, isFalse, reason: 'HTML 行只有一种颜色，remake 盖掉 trusted');
  });

  test('非小说域不跑分类器：contentHint 恒 none', () async {
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'nyaa',
      displayName: 'Nyaa',
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.novel: '3_0',
        DiscoveryMediaKind.audiobook: '2_0',
      },
      client: _client(
        (http.Request request) async => http.Response(
          nyaaSearchHtml(const <NyaaHtmlRow>[_mangaRow]),
          200,
        ),
      ),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.audiobook, query: 'x'),
    );
    final DiscoveryResourceItem item =
        result.items.single.entries.single as DiscoveryResourceItem;
    expect(item.contentHint, DiscoveryContentHint.none);
    expect(item.category, '3_1', reason: '分类 id 照样透传');
  });

  test('BUG-1946：Sukebei 源按站点 baseUrl 解析详情页链接', () async {
    Uri? captured;
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'sukebei',
      displayName: 'Sukebei',
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.game: '1_3',
      },
      client: _client(
        baseUrl: 'https://sukebei.nyaa.si',
        (http.Request request) async {
          captured = request.url;
          return http.Response.bytes(
            utf8.encode(
              nyaaSearchHtml(const <NyaaHtmlRow>[
                NyaaHtmlRow(
                  title: '[260826][天粋球児] 魔族ギルド 魔王の采配SLG [RJ01704616]',
                  infoHash: 'b5e79758ededc8b0084b5dff18c87bcf49397384',
                  id: '4697046',
                  seeders: 49,
                  leechers: 19,
                  downloads: 110,
                  size: '472.7 MiB',
                  categoryId: '1_3',
                ),
              ]),
            ),
            200,
            headers: <String, String>{'content-type': 'text/html'},
          );
        },
      ),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: '魔族'),
    );

    expect(captured!.host, 'sukebei.nyaa.si');
    expect(captured!.queryParameters['c'], '1_3');
    expect(result.failures, isEmpty);
    final DiscoveryResultPage page = result.items.single;
    final DiscoveryResourceItem item =
        page.entries.single as DiscoveryResourceItem;
    expect(item.sourceId, 'sukebei');
    expect(item.title, '[260826][天粋球児] 魔族ギルド 魔王の采配SLG [RJ01704616]');
    expect(item.detailUrl, 'https://sukebei.nyaa.si/view/4697046');
    expect(
      (item.payload! as DiscoveryTorrentPayload).magnetUri,
      contains('xt=urn:btih:b5e79758ededc8b0084b5dff18c87bcf49397384'),
    );
    expect(item.seeders, 49);
    expect(item.sizeBytes, (472.7 * 1024 * 1024).round());
    expect(item.contentHint, DiscoveryContentHint.none);
    expect(page.hasMore, isTrue);
  });

  test('capabilities 只声明映射过的媒体域;未映射域搜索返回 unsupported', () async {
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'nyaa',
      displayName: 'Nyaa',
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.novel: '3_0',
      },
      client: _client((http.Request request) async => http.Response('', 500)),
    );

    expect(
      source.capabilities.kinds,
      const <DiscoveryMediaKind>{DiscoveryMediaKind.novel},
    );
    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'x'),
    );
    expect(result.isTotalFailure, isTrue);
    expect(
      result.failures.single.kind,
      ExternalProviderFailureKind.unsupported,
    );
  });

  test('trustedOnly 透传 f=2', () async {
    Uri? captured;
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'nyaa',
      displayName: 'Nyaa',
      trustedOnly: true,
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.novel: '3_0',
      },
      client: _client((http.Request request) async {
        captured = request.url;
        return http.Response(kNyaaNoResultsHtml, 200);
      }),
    );
    await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'x'),
    );
    expect(captured!.queryParameters['f'], '2');
  });

  test('qualityFilter 回调每次请求现读：三态切换无需重建源', () async {
    final List<String?> filters = <String?>[];
    NyaaQualityFilter current = NyaaQualityFilter.all;
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'nyaa',
      displayName: 'Nyaa',
      // 给了 qualityFilter 时 trustedOnly 的固定档不再生效。
      trustedOnly: true,
      qualityFilter: () => current,
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.novel: '3_0',
      },
      client: _client((http.Request request) async {
        filters.add(request.url.queryParameters['f']);
        return http.Response(kNyaaNoResultsHtml, 200);
      }),
    );
    const DiscoveryRequest request =
        DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'x');

    await source.search(request);
    current = NyaaQualityFilter.noRemakes;
    await source.search(request);
    current = NyaaQualityFilter.trustedOnly;
    await source.search(request);

    expect(filters, <String>['0', '1', '2']);
  });

  test('「No results found」页 → 空页且 hasMore=false，不算失败', () async {
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'nyaa',
      displayName: 'Nyaa',
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.novel: '3_0',
      },
      client: _client(
        (http.Request request) async => http.Response(kNyaaNoResultsHtml, 200),
      ),
    );
    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'x'),
    );
    expect(result.failures, isEmpty);
    expect(result.items.single.entries, isEmpty);
    expect(result.items.single.hasMore, isFalse);
  });
}
