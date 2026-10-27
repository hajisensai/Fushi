// 发现页的 torrent 源只来自用户添加的 BT 站：Nyaa 式、启用、且有发现域分类的站点
// 各展开一个用户自配源；没有站点就一个都没有（不再内置任何站）。
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/discovery/sources/nyaa_discovery_source.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';

void main() {
  final List<Uri> requests = <Uri>[];
  NyaaClient client(BtSiteConfig site) => NyaaClient(
        baseUrl: site.baseUrl.toString(),
        minRequestInterval: Duration.zero,
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response(
            '<html><body><h3>No results found</h3></body></html>',
            200,
          );
        }),
      );

  BtSiteConfig site(
    String id, {
    BtSiteFormat format = BtSiteFormat.nyaa,
    Set<BtSiteDomain> domains = const <BtSiteDomain>{
      BtSiteDomain.novel,
      BtSiteDomain.game,
      BtSiteDomain.anime,
    },
    bool enabled = true,
  }) =>
      BtSiteConfig(
        id: id,
        name: id == 'named' ? 'My books' : '',
        baseUrl: Uri.parse('https://$id.example'),
        format: format,
        domains: domains,
        nyaaCategories: format == BtSiteFormat.nyaa
            ? const <BtSiteDomain, String>{
                BtSiteDomain.anime: '1_0',
                BtSiteDomain.novel: '3_0',
                BtSiteDomain.audiobook: '2_0',
              }
            : const <BtSiteDomain, String>{},
        enabled: enabled,
      );

  test('没有用户站点 → 没有 torrent 发现源', () {
    expect(nyaaDiscoverySourcesForBtSites(const <BtSiteConfig>[]), isEmpty);
  });

  test('只展开启用的 Nyaa 式站点，域 = 勾选 ∩ 站点分类 ∩ 发现域', () async {
    final List<NyaaDiscoverySource> sources = nyaaDiscoverySourcesForBtSites(
      <BtSiteConfig>[
        site('named'),
        site('off', enabled: false),
        site('json', format: BtSiteFormat.apibay),
        // 只勾了视频域：不进发现页。
        site('videoonly', domains: const <BtSiteDomain>{BtSiteDomain.anime}),
      ],
      clientFactory: client,
    );
    expect(sources, hasLength(1));
    final NyaaDiscoverySource source = sources.single;
    expect(source.id, 'bt-named');
    expect(source.displayName, 'My books');
    expect(source.isUserConfigured, isTrue);
    // game 勾了但站点没有游戏分类 → 不生效；anime 是视频域 → 不进发现页。
    expect(source.capabilities.kinds.toSet(),
        <DiscoveryMediaKind>{DiscoveryMediaKind.novel});

    await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel, query: 'abc'),
    );
    expect(requests.single.host, 'named.example');
    expect(requests.single.queryParameters['c'], '3_0');
  });

  test('没有名字时显示主机名', () {
    expect(
      nyaaDiscoverySourcesForBtSites(
        <BtSiteConfig>[site('host')],
        clientFactory: client,
      ).single.displayName,
      'host.example',
    );
  });
}
