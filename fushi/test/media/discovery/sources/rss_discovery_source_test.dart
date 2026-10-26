import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/discovery/sources/rss_discovery_source.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';

/// 用户自配 RSS 搜索站的发现源：站点配置 → 能力、搜索结果 → 发现条目、
/// 下载时才物化 payload（磁链 / 校验过的 .torrent）。
RssSearchSiteConfig _site({
  String template = 'https://site.example/rss?q={query}',
  List<RssSearchDomain> domains = const <RssSearchDomain>[
    RssSearchDomain.novel,
    RssSearchDomain.game,
  ],
  bool enabled = true,
}) => RssSearchSiteConfig(
  id: 'site1',
  name: 'My site',
  urlTemplate: template,
  domains: domains,
  enabled: enabled,
);

String _rss(String itemsXml) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<rss version="2.0" xmlns:nyaa="https://nyaa.si/xmlns/nyaa"><channel>'
    '$itemsXml</channel></rss>';

String _magnetItem(String title, String hash, {int seeders = 3}) =>
    '<item><title>$title</title>'
    '<link>magnet:?xt=urn:btih:$hash&amp;dn=x</link>'
    '<guid isPermaLink="false">$hash</guid>'
    '<nyaa:infoHash>$hash</nyaa:infoHash>'
    '<nyaa:seeders>$seeders</nyaa:seeders>'
    '<nyaa:size>1.0 GiB</nyaa:size>'
    '</item>';

/// 单文件 v1 种子（`info` 字典按 bencode 字典序）。
Uint8List _torrentBytes() {
  const String info =
      'd6:lengthi5e4:name5:a.txt12:piece lengthi16384e6:pieces20:'
      'aaaaaaaaaaaaaaaaaaaae';
  return Uint8List.fromList(
    'd8:announce14:http://t.e/ann4:info${info}e'.codeUnits,
  );
}

void main() {
  test('能力取自站点：勾了的发现页域 + 模板有没有 {page}', () {
    final RssDiscoverySource plain = RssDiscoverySource(
      site: _site(),
      client: RssSearchClient(
        client: MockClient((_) async => http.Response('', 500)),
      ),
    );
    expect(plain.id, rssSiteProviderId('site1'));
    expect(plain.displayName, 'My site');
    expect(plain.isUserConfigured, isTrue);
    expect(plain.isExternalSite, isTrue, reason: '公共种子站仍是第三方站点');
    expect(plain.capabilities.kinds, <DiscoveryMediaKind>{
      DiscoveryMediaKind.novel,
      DiscoveryMediaKind.game,
    });
    expect(plain.capabilities.supportsSearch, isTrue);
    expect(plain.capabilities.supportsBrowse, isFalse);
    expect(plain.capabilities.supportsPaging, isFalse);

    final RssDiscoverySource paged = RssDiscoverySource(
      site: _site(template: 'https://site.example/rss?q={query}&p={page}'),
      client: RssSearchClient(
        client: MockClient((_) async => http.Response('', 500)),
      ),
    );
    expect(paged.capabilities.supportsPaging, isTrue);
  });

  test('appliesTo：只有启用且勾了发现页域的站才展开成发现源', () {
    expect(RssDiscoverySource.appliesTo(_site()), isTrue);
    expect(RssDiscoverySource.appliesTo(_site(enabled: false)), isFalse);
    expect(
      RssDiscoverySource.appliesTo(
        _site(domains: const <RssSearchDomain>[RssSearchDomain.anime]),
      ),
      isFalse,
      reason: '只勾视频域的站属于视频资源搜索，不进发现页',
    );
  });

  test('搜索：结果变成 torrent 条目，小说域打内容形态，payload 留到下载时', () async {
    final List<Uri> requests = <Uri>[];
    final RssDiscoverySource source = RssDiscoverySource(
      site: _site(),
      client: RssSearchClient(
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response(
            _rss(
              _magnetItem('Re:ZERO v01-29 [Yen Press] [Stick]', 'a' * 40) +
                  _magnetItem(
                    'Sousou no Frieren v01-14 (Digital) (1r0n)',
                    'b' * 40,
                  ),
            ),
            200,
          );
        }),
      ),
    );
    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(
        kind: DiscoveryMediaKind.novel,
        query: ' re zero ',
      ),
    );
    expect(requests.single.queryParameters['q'], 're zero');
    final DiscoveryResultPage page = result.items.single;
    expect(page.hasMore, isFalse, reason: '模板没有 {page}：只有一页');
    final List<DiscoveryResourceItem> items = page.entries
        .cast<DiscoveryResourceItem>();
    expect(items, hasLength(2));
    expect(items.first.sourceId, 'rss:site1');
    expect(items.first.payloadKind, DiscoveryPayloadKind.torrent);
    expect(items.first.payload, isNull);
    expect(items.first.seeders, 3);
    expect(items.first.sizeBytes, greaterThan(0));
    expect(items.first.contentHint, DiscoveryContentHint.novel);
    expect(items.last.contentHint, DiscoveryContentHint.manga);

    final ProviderBatchResult<DiscoveryResultPage> game = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'x'),
    );
    expect(
      (game.items.single.entries.first as DiscoveryResourceItem).contentHint,
      DiscoveryContentHint.none,
    );
  });

  test('没勾的域与站点失败都回成失败结果，不吞成空列表', () async {
    final RssDiscoverySource source = RssDiscoverySource(
      site: _site(),
      client: RssSearchClient(
        client: MockClient(
          (_) async => http.Response('<html>blocked</html>', 503),
        ),
      ),
    );
    final ProviderBatchResult<DiscoveryResultPage> manga = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.manga, query: 'x'),
    );
    expect(manga.items, isEmpty);
    expect(manga.failures.single.kind, ExternalProviderFailureKind.unsupported);

    final ProviderBatchResult<DiscoveryResultPage> failed = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'x'),
    );
    expect(failed.items, isEmpty);
    expect(failed.failures.single.providerId, 'rss:site1');
  });

  test('下载：磁链条目物化成磁链 payload', () async {
    final RssDiscoverySource source = RssDiscoverySource(
      site: _site(),
      client: RssSearchClient(
        client: MockClient(
          (_) async => http.Response(_rss(_magnetItem('Book', 'c' * 40)), 200),
        ),
      ),
    );
    final DiscoveryResourceItem item =
        (await source.search(
              const DiscoveryRequest(
                kind: DiscoveryMediaKind.novel,
                query: 'b',
              ),
            )).items.single.entries.single
            as DiscoveryResourceItem;
    final DiscoveryPayload payload = await source.resolvePayload(item);
    expect(payload, isA<DiscoveryTorrentPayload>());
    expect((payload as DiscoveryTorrentPayload).magnetUri, contains('c' * 40));
  });

  test('下载：只有 .torrent 的条目下载校验后全选文件', () async {
    final RssDiscoverySource source = RssDiscoverySource(
      site: _site(),
      client: RssSearchClient(
        client: MockClient((http.Request request) async {
          if (request.url.path.endsWith('.torrent')) {
            return http.Response.bytes(_torrentBytes(), 200);
          }
          return http.Response(
            _rss(
              '<item><title>Game</title>'
              '<enclosure url="https://site.example/dl/1.torrent" '
              'type="application/x-bittorrent" length="1"/>'
              '<guid>g1</guid></item>',
            ),
            200,
          );
        }),
      ),
    );
    final DiscoveryResourceItem item =
        (await source.search(
              const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'g'),
            )).items.single.entries.single
            as DiscoveryResourceItem;
    final DiscoveryPayload payload = await source.resolvePayload(item);
    expect(payload, isA<DiscoverySelectedTorrentPayload>());
    final DiscoverySelectedTorrentPayload selected =
        payload as DiscoverySelectedTorrentPayload;
    expect(selected.selectedFileIndexes, <int>{
      for (final file in selected.metainfo.files) file.index,
    });
    expect(selected.selectedFileIndexes, isNotEmpty);
    expect(selected.importAfterDownload, isTrue);
    expect(selected.resourceTitle, 'Game');
  });

  test('源重建后旧条目找不回：明确要求重搜，而不是拿标题去猜', () async {
    final RssDiscoverySource source = RssDiscoverySource(
      site: _site(),
      client: RssSearchClient(
        client: MockClient((_) async => http.Response('', 500)),
      ),
    );
    const DiscoveryResourceItem stale = DiscoveryResourceItem(
      sourceId: 'rss:site1',
      id: 'unknown',
      title: 'Old',
      kind: DiscoveryMediaKind.novel,
      payloadKind: DiscoveryPayloadKind.torrent,
    );
    await expectLater(
      source.resolvePayload(stale),
      throwsA(
        isA<ExternalProviderFailure>().having(
          (ExternalProviderFailure f) => f.kind,
          'kind',
          ExternalProviderFailureKind.notFound,
        ),
      ),
    );
  });
}
