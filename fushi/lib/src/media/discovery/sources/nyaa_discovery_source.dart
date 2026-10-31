/// Nyaa 式站点的发现源 adapter：复用 `NyaaClient`（HTML 搜索页，服务端按做种
/// 降序），一个实例 = 一个用户添加的 BT 站。媒体域 → 站点分类号的映射来自添加
/// 站点时的自动探测（站点分类下拉，见引擎 `mapNyaaCategoriesToDomains`），由
/// 组装点（`AppModel.mediaDiscoveryService`）给定。没有内置站点。
///
/// 产出 torrent payload：UI 分流给 torrent 后端，不进 HTTP 下载队列。
///
/// 小说域结果经 `classifyNyaaLiterature` 打 [DiscoveryResourceItem.contentHint]
/// （Literature 分类里漫画与小说混放，站方不区分）；其余域恒
/// [DiscoveryContentHint.none]。
library;

import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi/src/media/discovery/nyaa_literature_classifier.dart';

/// 请求时取当前 Nyaa 过滤三态的回调（偏好可随时变，源实例常驻，所以按次读）。
typedef NyaaQualityFilterProvider = NyaaQualityFilter Function();

NyaaQualityFilter _allFilter() => NyaaQualityFilter.all;

NyaaQualityFilter _trustedOnlyFilter() => NyaaQualityFilter.trustedOnly;

class NyaaDiscoverySource extends MediaDiscoverySource {
  NyaaDiscoverySource({
    required this.id,
    required this.displayName,
    required Map<DiscoveryMediaKind, String> categoryByKind,
    required NyaaClient client,
    this.priority = 10,
    this.trustedOnly = false,
    bool userConfigured = false,
    NyaaQualityFilterProvider? qualityFilter,
  }) : _userConfigured = userConfigured,
       _categoryByKind = Map<DiscoveryMediaKind, String>.unmodifiable(
         categoryByKind,
       ),
       _client = client,
       _qualityFilter =
           qualityFilter ?? (trustedOnly ? _trustedOnlyFilter : _allFilter);

  @override
  final String id;

  @override
  final String displayName;

  @override
  final int priority;

  final bool _userConfigured;

  /// 用户 BT 站展开的源为 true：它的开关是站点配置自己的 `enabled`，不进内置源
  /// 停用清单（见 [MediaDiscoverySource.isUserConfigured]）。
  @override
  bool get isUserConfigured => _userConfigured;

  /// 只收 trusted 发布（nyaa `f=2`）的固定档；给了 `qualityFilter` 时以后者为准。
  final bool trustedOnly;

  final Map<DiscoveryMediaKind, String> _categoryByKind;
  final NyaaClient _client;
  final NyaaQualityFilterProvider _qualityFilter;

  @override
  DiscoveryCapabilities get capabilities =>
      DiscoveryCapabilities(kinds: _categoryByKind.keys, supportsPaging: true);

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    final String? category = _categoryByKind[request.kind];
    if (category == null) {
      return ProviderBatchResult<DiscoveryResultPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'media kind not mapped to a nyaa category',
        ),
      );
    }
    final List<NyaaTorrent> torrents = await _client.search(
      request.query!.trim(),
      category: category,
      filter: _qualityFilter().queryValue,
      page: request.page,
    );
    final bool classify = request.kind == DiscoveryMediaKind.novel;
    return ProviderBatchResult<DiscoveryResultPage>.success(<
      DiscoveryResultPage
    >[
      DiscoveryResultPage(
        entries: <DiscoveryEntry>[
          for (final NyaaTorrent torrent in torrents)
            DiscoveryResourceItem(
              sourceId: id,
              // 详情页 URL 含站内种子 id，是最稳的源内身份。
              id: torrent.pageUrl,
              title: torrent.title,
              kind: request.kind,
              payloadKind: DiscoveryPayloadKind.torrent,
              payload: DiscoveryTorrentPayload(magnetUri: torrent.magnet),
              sizeBytes: torrent.sizeBytes,
              dateText: torrent.pubDate?.toLocal().toString().split('.').first,
              seeders: torrent.seeders,
              leechers: torrent.leechers,
              detailUrl: torrent.pageUrl,
              category: torrent.categoryId.isEmpty ? null : torrent.categoryId,
              trusted: torrent.trusted,
              remake: torrent.remake,
              contentHint: classify
                  ? classifyNyaaLiterature(
                      title: torrent.title,
                      sizeBytes: torrent.sizeBytes,
                      categoryId: torrent.categoryId,
                    )
                  : DiscoveryContentHint.none,
            ),
        ],
        page: request.page,
        // 过了末页 nyaa 返回空列表（client 把 404 / 越界页归一成空）；空页即到底。
        hasMore: torrents.isNotEmpty,
      ),
    ]);
  }

  @override
  void close() => _client.close();
}

/// 用户 BT 站 → 发现源：启用、Nyaa 式、且至少一个发现域在该站有分类的站点各展开
/// 一个 [NyaaDiscoverySource]（id `bt-<siteId>`、`isUserConfigured`），域 → 分类号
/// 取自添加站点时探测出的映射。其它格式的站点只有视频资源搜索，不进发现页。
List<NyaaDiscoverySource> nyaaDiscoverySourcesForBtSites(
  Iterable<BtSiteConfig> sites, {
  NyaaQualityFilterProvider? qualityFilter,
  NyaaClient Function(BtSiteConfig site)? clientFactory,
}) => <NyaaDiscoverySource>[
  for (final BtSiteConfig site in sites)
    if (site.enabled &&
        site.format == BtSiteFormat.nyaa &&
        site.effectiveDiscoveryKinds.isNotEmpty)
      NyaaDiscoverySource(
        id: site.discoverySourceId,
        displayName: site.displayName,
        priority: 10,
        userConfigured: true,
        categoryByKind: <DiscoveryMediaKind, String>{
          for (final BtSiteDomain domain in site.effectiveDomains)
            if (domain.discoveryKind case final DiscoveryMediaKind kind)
              kind: site.nyaaCategories[domain]!,
        },
        client:
            clientFactory?.call(site) ??
            NyaaClient(baseUrl: site.baseUrl.toString()),
        qualityFilter: qualityFilter,
      ),
];
