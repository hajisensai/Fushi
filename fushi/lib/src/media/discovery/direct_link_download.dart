/// 直链下载：把一条用户给的 http(s) 地址包成 [DiscoveryResourceItem]，送进下载中心
/// 既有的直链队列 [DiscoveryDownloadQueue]（`AppModel.discoveryDownloadQueue`），
/// 下载、续传、重试、自动入库全走那条队列，这里不另写下载器。
///
/// 发现页条目由各发现源 resolve payload；直链条目没有发现源，payload 在入队时就
/// 物化好，由 [kDirectLinkDiscoverySourceId] 标记，AppModel 的 resolver 认到这个源
/// id 时直接用条目自带的 payload（见 `AppModel.discoveryDownloadQueue`）。
library;

import 'package:fushi_engine/media/discovery/discovery_download_queue.dart'
    show DiscoveryDownloadQueue;
import 'package:fushi_engine/media/discovery/discovery_models.dart';

/// 直链条目的伪来源 id（不在发现源注册表里，只给队列的 resolver 与任务行用）。
const String kDirectLinkDiscoverySourceId = 'direct-link';

/// 直链条目的 payload：只有带 [kDirectLinkDiscoverySourceId] 且已物化 http payload
/// 的条目才返回非 null（其余条目照旧交给发现源 resolve）。
DiscoveryHttpPayload? directLinkPayloadOf(DiscoveryResourceItem item) {
  if (item.sourceId != kDirectLinkDiscoverySourceId) return null;
  final DiscoveryPayload? payload = item.payload;
  return payload is DiscoveryHttpPayload ? payload : null;
}

/// 用户给的地址 → 直链条目。只认 http / https 且有主机名；否则抛 [FormatException]。
/// [title] 缺省取 URL 最后一段非空路径（解码后），再缺省用主机名。
DiscoveryResourceItem buildDirectLinkDiscoveryItem({
  required String url,
  required DiscoveryMediaKind kind,
  String? title,
}) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw FormatException('不是 http(s) 直链', url);
  }
  final String normalized = uri.toString();
  return DiscoveryResourceItem(
    sourceId: kDirectLinkDiscoverySourceId,
    // 去重身份：同一地址未完成时不重复入队（队列按 sourceId + id 判）。
    id: normalized,
    title: _directLinkTitle(uri, title),
    kind: kind,
    payloadKind: DiscoveryPayloadKind.httpFile,
    payload: DiscoveryHttpPayload(url: normalized),
  );
}

String _directLinkTitle(Uri uri, String? explicit) {
  final String? given = explicit?.trim();
  if (given != null && given.isNotEmpty) return given;
  for (final String segment in uri.pathSegments.reversed) {
    if (segment.trim().isEmpty) continue;
    try {
      return Uri.decodeComponent(segment);
    } on ArgumentError {
      return segment;
    }
  }
  return uri.host;
}
