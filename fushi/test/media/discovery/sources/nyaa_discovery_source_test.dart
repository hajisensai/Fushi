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
