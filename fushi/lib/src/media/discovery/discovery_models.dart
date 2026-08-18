/// 统一发现页的领域模型：跨媒体域（小说/有声书/游戏/漫画）的在线**资源**发现契约。
///
/// 与视频域的元数据发现（`video_discovery_provider.dart`，TMDB/AniList 作品条目 +
/// 跨源身份合并）不同，这里发现的是**可下载资源**（种子/HTTP 直链）：资源天然按源
/// 展示、不做跨源去重合并；聚合只做扇出与部分成功语义（`media_discovery_service.dart`）。
///
/// 条目分两形：目录（[DiscoveryFolder]，仅目录型源产生，点进去继续 browse）与
/// 资源（[DiscoveryResourceItem]，可下载）。用 sealed 层级而不是 `isDirectory` 布尔位，
/// 让「目录没有 payload/体积/做种数」在类型上成立，而不是一堆可空字段的运行时约定。
library;

/// 发现页覆盖的媒体域。各域独立枚举（见根 CLAUDE.md 术语表），与持久化的
/// `MediaKind` 等值域互不混用；本枚举只活在发现/下载编排层，不落库。
enum DiscoveryMediaKind { novel, audiobook, game, manga }

/// 条目将来会产出的 payload 形态。源在**列表阶段**就已知自己产什么
/// （nyaa 恒 torrent、AList/shinnku 恒 http），UI 拿到条目即可分流下载动作：
/// torrent 走既有 torrent 后端（`pushGenericMagnet` 链路），http 走
/// `DiscoveryDownloadQueue`——不需要先 resolve 再分流。
enum DiscoveryPayloadKind { torrent, httpFile }

/// 可执行的下载 payload。列表阶段能给就随条目带上（[DiscoveryResourceItem.payload]）；
/// 直链带临期签名的源（AList `/api/fs/get`）列表阶段给 null，下载时经
/// `MediaDiscoverySource.resolvePayload` 延迟物化。
sealed class DiscoveryPayload {
  const DiscoveryPayload();
}

/// 磁链/种子：交给 torrent 后端。
final class DiscoveryTorrentPayload extends DiscoveryPayload {
  const DiscoveryTorrentPayload({required this.magnetUri});

  final String magnetUri;
}

/// HTTP 直链：交给 HTTP 下载队列。
final class DiscoveryHttpPayload extends DiscoveryPayload {
  const DiscoveryHttpPayload({
    required this.url,
    this.headers = const <String, String>{},
    this.fileName,
    this.sizeBytes,
  });

  final String url;

  /// 该直链要求的额外请求头（Referer/UA 防盗链等）。
  final Map<String, String> headers;

  /// 服务端真实文件名（可与展示标题不同）；null 时由下载侧从 URL 推导。
  final String? fileName;

  final int? sizeBytes;
}

/// 发现结果里的一个条目：目录或资源。
sealed class DiscoveryEntry {
  const DiscoveryEntry({required this.sourceId, required this.title});

  /// 产生本条目的源 id（聚合列表里渲染源徽标用）。
  final String sourceId;

  final String title;
}

/// 目录：点击后以 [DiscoveryRequest.path] = [path] 对同源继续 browse。
final class DiscoveryFolder extends DiscoveryEntry {
  const DiscoveryFolder({
    required super.sourceId,
    required super.title,
    required this.path,
  });

  /// 源内路径（源自定义语义，聚合层只透传）。
  final String path;
}

/// 可下载资源。
final class DiscoveryResourceItem extends DiscoveryEntry {
  const DiscoveryResourceItem({
    required super.sourceId,
    required super.title,
    required this.id,
    required this.kind,
    required this.payloadKind,
    this.payload,
    this.sizeBytes,
    this.dateText,
    this.seeders,
    this.leechers,
    this.coverUrl,
    this.detailUrl,
    this.note,
  });

  /// 源内稳定 id（去重/防重复入队的身份键；语义源自定义：文件路径、种子页 URL 等）。
  final String id;

  final DiscoveryMediaKind kind;

  final DiscoveryPayloadKind payloadKind;

  /// 列表阶段已物化的 payload；null 表示需要下载时向源 resolve。
  final DiscoveryPayload? payload;

  final int? sizeBytes;

  /// 展示用的发布时间原文（不解析成 DateTime——各源格式/时区五花八门，
  /// 排序仍按源返回顺序，解析只会制造错序假象）。
  final String? dateText;

  /// 种子健康度（仅 torrent 源）。
  final int? seeders;
  final int? leechers;

  final String? coverUrl;

  /// 外部详情页（nyaa view 页、shinnku 条目页）；「在浏览器打开」动作用。
  final String? detailUrl;

  /// 源特定的一句话标注（shinnku 的「熟肉/生肉/手机」、平台标签等），
  /// 原样展示，不参与任何逻辑。
  final String? note;
}

/// 一次发现请求。[query] 非空白即搜索，否则是目录浏览（[path] null = 源根）。
class DiscoveryRequest {
  const DiscoveryRequest({
    required this.kind,
    this.query,
    this.path,
    this.page = 1,
    this.pageSize = 50,
  })  : assert(page > 0),
        assert(pageSize > 0);

  final DiscoveryMediaKind kind;
  final String? query;

  /// browse 位置（源内路径）。**浏览整个是源内语义**（根目录也一样）：聚合
  /// （全部来源）模式只允许 search，见 `MediaDiscoveryService.load` 的入参
  /// 约束与 BUG-1711。
  final String? path;

  final int page;
  final int pageSize;

  bool get isSearch => query?.trim().isNotEmpty == true;
}

/// 单源单页结果。
class DiscoveryResultPage {
  DiscoveryResultPage({
    required Iterable<DiscoveryEntry> entries,
    required this.page,
    required this.hasMore,
  }) : entries = List<DiscoveryEntry>.unmodifiable(entries);

  final List<DiscoveryEntry> entries;
  final int page;
  final bool hasMore;
}

/// 源能力声明：聚合层据此决定一次请求扇出到哪些源，而不是调了再看报错。
class DiscoveryCapabilities {
  DiscoveryCapabilities({
    required Iterable<DiscoveryMediaKind> kinds,
    this.supportsSearch = true,
    this.supportsBrowse = false,
    this.supportsPaging = false,
  }) : kinds = Set<DiscoveryMediaKind>.unmodifiable(kinds);

  final Set<DiscoveryMediaKind> kinds;
  final bool supportsSearch;
  final bool supportsBrowse;
  final bool supportsPaging;
}
