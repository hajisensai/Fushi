/// 用户 BT 站 → 视频资源 provider（app 与无头服务端共用的唯一装配点）。
///
/// 一个启用、且对至少一个视频域生效的站点注册一个 provider 实例，id 形如
/// `<format>:<siteId>`。没有站点就一个都不注册——Fushi 不内置任何 BT 站。
library;

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/public_video_index_client.dart';
import 'package:fushi_engine/media/torrent/public_video_index_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

/// 各格式的基础优先级（小者先查、去重时胜出）；同格式按用户列表顺序 +1。
int _basePriority(BtSiteFormat format) => switch (format) {
  BtSiteFormat.nyaa => 100,
  BtSiteFormat.apibay => 200,
  BtSiteFormat.knaben => 300,
};

/// 为一个站点造 provider；站点停用或没有生效的视频域时返回 null。[client] 的
/// 所有权交给 provider（`closesClient: true`）；返回 null 时由调用方关。
VideoResourceProvider? createBtSiteResourceProvider(
  BtSiteConfig site,
  http.Client client, {
  int index = 0,
}) {
  final Set<VideoDiscoveryCategory> categories = site.effectiveVideoCategories;
  if (!site.enabled || categories.isEmpty) return null;
  final int priority = _basePriority(site.format) + index;
  final String baseUrl = site.baseUrl.toString();
  return switch (site.format) {
    BtSiteFormat.nyaa => NyaaVideoResourceProvider(
      client: NyaaClient(baseUrl: baseUrl, client: client),
      siteId: site.id,
      displayName: site.displayName,
      categoryByDomain: <VideoDiscoveryCategory, String>{
        for (final VideoDiscoveryCategory category in categories)
          category:
              site.nyaaCategories[BtSiteDomain.fromVideoCategory(category)]!,
      },
      priority: priority,
      closesClient: true,
    ),
    BtSiteFormat.apibay => ApibayVideoResourceProvider(
      client: ApibayClient(baseUrl: baseUrl, client: client),
      siteId: site.id,
      displayName: site.displayName,
      categories: categories,
      priority: priority,
      closesClient: true,
    ),
    BtSiteFormat.knaben => KnabenVideoResourceProvider(
      client: KnabenClient(baseUrl: baseUrl, client: client),
      siteId: site.id,
      displayName: site.displayName,
      categories: categories,
      priority: priority,
      closesClient: true,
    ),
  };
}

/// 全部用户站点的 provider（列表顺序 = 用户设置里的顺序）。[clientFactory] 每个
/// 站点调一次；只给真正注册的站点建 client。
Future<List<VideoResourceProvider>> createBtSiteResourceProviders(
  Iterable<BtSiteConfig> sites,
  Future<http.Client> Function() clientFactory,
) async {
  final List<VideoResourceProvider> providers = <VideoResourceProvider>[];
  int index = 0;
  for (final BtSiteConfig site in sites) {
    if (!site.enabled || site.effectiveVideoCategories.isEmpty) continue;
    final VideoResourceProvider? provider = createBtSiteResourceProvider(
      site,
      await clientFactory(),
      index: index++,
    );
    if (provider != null) providers.add(provider);
  }
  return providers;
}
