import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/sources/nyaa_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/nyaa_client.dart';

const String _rss = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:nyaa="https://nyaa.si/xmlns/nyaa">
  <channel>
    <title>Nyaa - "q" - Torrent File RSS</title>
    <description>RSS Feed</description>
    <link>https://nyaa.si/</link>
    <item>
      <title>Some Light Novel Vol.1-3 EPUB</title>
      <link>https://nyaa.si/download/42.torrent</link>
      <guid isPermaLink="true">https://nyaa.si/view/42</guid>
      <pubDate>Fri, 03 Nov 2023 12:30:00 -0000</pubDate>
      <nyaa:seeders>7</nyaa:seeders>
      <nyaa:leechers>1</nyaa:leechers>
      <nyaa:downloads>99</nyaa:downloads>
      <nyaa:infoHash>0123456789abcdef0123456789abcdef01234567</nyaa:infoHash>
      <nyaa:categoryId>3_1</nyaa:categoryId>
      <nyaa:size>12.0 MiB</nyaa:size>
      <nyaa:trusted>Yes</nyaa:trusted>
      <nyaa:remake>No</nyaa:remake>
    </item>
  </channel>
</rss>
''';

void main() {
  test('搜索映射:分类按媒体域取,条目产 torrent payload', () async {
    Uri? captured;
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'nyaa',
      displayName: 'Nyaa',
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.novel: '3_0',
        DiscoveryMediaKind.audiobook: '2_0',
      },
      client: NyaaClient(
        client: MockClient((http.Request request) async {
          captured = request.url;
          return http.Response.bytes(
            utf8.encode(_rss),
            200,
            headers: <String, String>{
              'content-type': 'application/rss+xml; charset=utf-8',
            },
          );
        }),
      ),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'novel'),
    );

    expect(captured!.queryParameters['c'], '3_0');
    expect(captured!.queryParameters['q'], 'novel');
    expect(captured!.queryParameters['page'], 'rss');

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
    expect(item.note, 'trusted');
  });

  test('BUG-1946：Sukebei 源用站点自身命名空间的 RSS 也能产出条目', () async {
    // 真实 sukebei feed 的根元素是 xmlns:nyaa="https://sukebei.nyaa.si/xmlns/nyaa"，
    // 旧实现硬编码 nyaa.si 命名空间 → 每条 item invalidNamespace → 整源失败。
    const String sukebeiRss = '''
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:nyaa="https://sukebei.nyaa.si/xmlns/nyaa" version="2.0">
  <channel>
    <title>Sukebei - Home - Torrent File RSS</title>
    <description>RSS Feed for Home</description>
    <link>https://sukebei.nyaa.si/</link>
    <item>
      <title>[260826][天粋球児] 魔族ギルド 魔王の采配SLG [RJ01704616]</title>
      <link>https://sukebei.nyaa.si/download/4697046.torrent</link>
      <guid isPermaLink="true">https://sukebei.nyaa.si/view/4697046</guid>
      <pubDate>Sat, 29 Aug 2026 12:57:39 -0000</pubDate>
      <nyaa:seeders>49</nyaa:seeders>
      <nyaa:leechers>19</nyaa:leechers>
      <nyaa:downloads>110</nyaa:downloads>
      <nyaa:infoHash>b5e79758ededc8b0084b5dff18c87bcf49397384</nyaa:infoHash>
      <nyaa:categoryId>1_3</nyaa:categoryId>
      <nyaa:category>Art - Games</nyaa:category>
      <nyaa:size>472.7 MiB</nyaa:size>
      <nyaa:comments>0</nyaa:comments>
      <nyaa:trusted>No</nyaa:trusted>
      <nyaa:remake>No</nyaa:remake>
    </item>
  </channel>
</rss>
''';
    Uri? captured;
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'sukebei',
      displayName: 'Sukebei',
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.game: '1_3',
      },
      client: NyaaClient(
        baseUrl: 'https://sukebei.nyaa.si',
        client: MockClient((http.Request request) async {
          captured = request.url;
          return http.Response.bytes(
            utf8.encode(sukebeiRss),
            200,
            headers: <String, String>{'content-type': 'application/xml'},
          );
        }),
      ),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: '魔族'),
    );

    expect(captured!.host, 'sukebei.nyaa.si');
    expect(captured!.queryParameters['c'], '1_3');
    expect(result.failures, isEmpty, reason: '命名空间不能再被判 invalidNamespace');
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
    expect(page.hasMore, isTrue);
  });

  test('capabilities 只声明映射过的媒体域;未映射域搜索返回 unsupported', () async {
    final NyaaDiscoverySource source = NyaaDiscoverySource(
      id: 'nyaa',
      displayName: 'Nyaa',
      categoryByKind: const <DiscoveryMediaKind, String>{
        DiscoveryMediaKind.novel: '3_0',
      },
      client: NyaaClient(
        client: MockClient(
          (http.Request request) async => http.Response('', 500),
        ),
      ),
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
      client: NyaaClient(
        client: MockClient((http.Request request) async {
          captured = request.url;
          return http.Response.bytes(utf8.encode(_rss), 200);
        }),
      ),
    );
    await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'x'),
    );
    expect(captured!.queryParameters['f'], '2');
  });
}
