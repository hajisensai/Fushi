/// nyaa 系站点的发现源 adapter：复用 `NyaaClient`（RSS 首屏 + HTML 翻页），
/// 一个实例 = 一个站点（nyaa.si / sukebei.nyaa.si），媒体域 → 站点分类 id 的
/// 映射由组装点给定：
///
/// - nyaa.si：小说 `3_0`（Literature）、有声书 `2_0`（Audio）、动画 `1_0`
/// - sukebei.nyaa.si：galgame `1_3`（Art - Games）
///
/// 产出 torrent payload：UI 分流给 torrent 后端，不进 HTTP 下载队列。
library;

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/nyaa_client.dart';

class NyaaDiscoverySource extends MediaDiscoverySource {
  NyaaDiscoverySource({
    required this.id,
    required this.displayName,
    required Map<DiscoveryMediaKind, String> categoryByKind,
    required NyaaClient client,
    this.priority = 10,
    this.trustedOnly = false,
  })  : _categoryByKind =
            Map<DiscoveryMediaKind, String>.unmodifiable(categoryByKind),
        _client = client;

  @override
  final String id;

  @override
  final String displayName;

  @override
  final int priority;

  /// 只收 trusted 发布（nyaa `f=2`）。
  final bool trustedOnly;

  final Map<DiscoveryMediaKind, String> _categoryByKind;
  final NyaaClient _client;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
        kinds: _categoryByKind.keys,
        supportsPaging: true,
      );

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
      filter: trustedOnly ? '2' : '0',
      page: request.page,
    );
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
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
                dateText:
                    torrent.pubDate?.toLocal().toString().split('.').first,
                seeders: torrent.seeders,
                leechers: torrent.leechers,
                detailUrl: torrent.pageUrl,
                note: torrent.trusted ? 'trusted' : null,
              ),
          ],
          page: request.page,
          // 过了末页 nyaa 返回空列表（client 把 404 归一成空）；空页即到底。
          hasMore: torrents.isNotEmpty,
        ),
      ],
    );
  }

  @override
  void close() => _client.close();
}
