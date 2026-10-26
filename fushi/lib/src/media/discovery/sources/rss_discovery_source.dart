/// 用户自配 RSS 搜索站的发现源 adapter（书 / 有声书 / 漫画 / 游戏）。
///
/// 一个实例 = 一个**启用且勾了发现页域**的站（`resource_rss_sites` 里的一条
/// [RssSearchSiteConfig]），与视频资源搜索共用同一份清单与同一个网络层
/// [RssSearchClient]。只支持关键词搜索；能不能翻页取决于站点模板里有没有
/// `{page}`（[RssSearchSiteConfig.supportsPaging]）。
///
/// 小说域结果经 [classifyLiteratureTitle] 打「小说 / 漫画」标记（公共种子站的
/// 文学类目常把两者混放），其余域恒 [DiscoveryContentHint.none]。
///
/// 列表阶段不物化 payload：磁链要与条目 info hash 复核、`.torrent` 要下载校验，
/// 都放到用户点下载时经 [resolvePayload] → [RssSearchClient.resolveItem] 做，
/// 结果再换成下载动作认识的发现 payload（磁链 → [DiscoveryTorrentPayload]，
/// 校验过的 metainfo → 全选文件的 [DiscoverySelectedTorrentPayload]）。
library;

import 'dart:collection';

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/discovery/literature_title_classifier.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';

/// 发现源的 http client 工厂（app 侧传 `createDownloadHttpClient`，走全应用
/// 代理装配）。
typedef RssDiscoveryHttpClientFactory = Future<http.Client> Function();

/// 列表阶段记住的条目上限：[resolvePayload] 只能拿到发现条目，下载所需的
/// 磁链 / `.torrent` 地址 / info hash 留在源里按条目 id 找回。超出上限丢最早的。
const int kRssDiscoveryRememberedItems = 1000;

class RssDiscoverySource extends MediaDiscoverySource {
  RssDiscoverySource({
    required this.site,
    RssDiscoveryHttpClientFactory? httpClientFactory,
    RssSearchClient? client,
    this.priority = 30,
  }) : assert(httpClientFactory == null || client == null),
       _providedClient = client,
       _httpClientFactory = httpClientFactory;

  /// 这个站在发现页里该不该出现：启用且至少勾了一个发现页域。
  static bool appliesTo(RssSearchSiteConfig site) =>
      site.enabled && site.discoveryKinds.isNotEmpty;

  final RssSearchSiteConfig site;
  final RssSearchClient? _providedClient;
  final RssDiscoveryHttpClientFactory? _httpClientFactory;
  Future<RssSearchClient>? _clientFuture;
  bool _closed = false;

  /// 条目 id → 列表阶段解析出的 RSS 条目（见 [kRssDiscoveryRememberedItems]）。
  final LinkedHashMap<String, RssSearchItem> _remembered =
      LinkedHashMap<String, RssSearchItem>();

  /// 与视频资源 provider 的回执 / 失败同一个 id（`rss:<siteId>`），源徽标上的
  /// 失败与日志能对上同一个站。
  @override
  String get id => rssSiteProviderId(site.id);

  @override
  String get displayName => site.name;

  /// 自配源排在内置源之后（与 OPDS / AList 自配源同档）。
  @override
  final int priority;

  @override
  bool get isUserConfigured => true;

  /// 用户添加的公共种子站仍是第三方站点（游戏资源风险说明照常弹）。
  @override
  bool get isExternalSite => true;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
    kinds: site.discoveryKinds,
    supportsPaging: site.supportsPaging,
  );

  Future<RssSearchClient> _client() {
    if (_closed) throw StateError('RSS discovery source is closed');
    final RssSearchClient? provided = _providedClient;
    if (provided != null) return Future<RssSearchClient>.value(provided);
    return _clientFuture ??= () async {
      final RssDiscoveryHttpClientFactory? factory = _httpClientFactory;
      return RssSearchClient(client: factory == null ? null : await factory());
    }();
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    if (!site.appliesToDiscovery(request.kind)) {
      return ProviderBatchResult<DiscoveryResultPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'RSS site does not cover this media kind',
        ),
      );
    }
    final List<RssSearchItem> items;
    try {
      items = await (await _client()).searchSite(
        site,
        (request.query ?? '').trim(),
        page: request.page,
      );
    } on ExternalProviderFailure catch (failure) {
      return ProviderBatchResult<DiscoveryResultPage>.failure(failure);
    }
    // 小说域结果按标题打「小说 / 漫画」标记，供发现页「隐藏疑似漫画」筛选；
    // 其余域恒 none。
    final bool classify = request.kind == DiscoveryMediaKind.novel;
    final List<DiscoveryEntry> entries = <DiscoveryEntry>[];
    for (final RssSearchItem item in items) {
      _remember(item);
      entries.add(
        DiscoveryResourceItem(
          sourceId: id,
          id: item.remoteId,
          title: item.title,
          kind: request.kind,
          payloadKind: DiscoveryPayloadKind.torrent,
          sizeBytes: item.sizeBytes,
          dateText: item.publishedAt?.toLocal().toString().split('.').first,
          seeders: item.seeders,
          leechers: item.leechers,
          detailUrl: item.detailsUrl,
          category: item.category,
          trusted: item.trusted,
          contentHint: classify
              ? classifyLiteratureTitle(
                  title: item.title,
                  sizeBytes: item.sizeBytes,
                )
              : DiscoveryContentHint.none,
        ),
      );
    }
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(
          entries: entries,
          page: request.page,
          // 没有 `{page}` 的站只有一页；有的站翻过末页返回空页即到底。
          hasMore: site.supportsPaging && items.isNotEmpty,
        ),
      ],
    );
  }

  void _remember(RssSearchItem item) {
    _remembered.remove(item.remoteId);
    _remembered[item.remoteId] = item;
    while (_remembered.length > kRssDiscoveryRememberedItems) {
      _remembered.remove(_remembered.keys.first);
    }
  }

  @override
  Future<DiscoveryPayload> resolvePayload(DiscoveryResourceItem item) async {
    final RssSearchItem? remembered = _remembered[item.id];
    if (remembered == null) {
      // 源在设置改动后会整体重建，旧列表里的条目在新实例里找不回：让用户重搜，
      // 而不是拿标题去猜一个种子。
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'resolvePayload',
        kind: ExternalProviderFailureKind.notFound,
        message: 'search result expired; search again',
      );
    }
    final TorrentAddPayload payload = await (await _client()).resolveItem(
      site,
      remembered,
    );
    return switch (payload) {
      TorrentMagnetPayload(:final String magnetUri) => DiscoveryTorrentPayload(
        magnetUri: magnetUri,
      ),
      TorrentMetainfoPayload(:final bytes) => _selectAll(
        inspectTorrentMetainfo(bytes),
        item.title,
      ),
    };
  }

  static DiscoverySelectedTorrentPayload _selectAll(
    InspectedTorrentMetainfo metainfo,
    String title,
  ) => DiscoverySelectedTorrentPayload(
    metainfo: metainfo,
    selectedFileIndexes: <int>{
      for (final InspectedTorrentFile file in metainfo.files) file.index,
    },
    resourceTitle: title,
  );

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _remembered.clear();
    final Future<RssSearchClient>? client = _clientFuture;
    if (client != null) {
      client.then((RssSearchClient value) => value.close());
    }
    // 注入的 [RssSearchClient] 归调用方所有，不在这里关。
  }
}
