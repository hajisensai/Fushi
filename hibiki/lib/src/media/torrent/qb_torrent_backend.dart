import 'package:hibiki/src/media/torrent/qbittorrent_client.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';

/// [TorrentBackend] 的外接 qBittorrent 实现：纯转发适配器，把接口语义
/// 一一映射到 [QBittorrentClient] 的 WebUI 调用，不加任何额外逻辑。
class QbTorrentBackend implements TorrentBackend {
  QbTorrentBackend(this._client);

  final QBittorrentClient _client;

  /// 连接测试 = 拉 WebUI 版本号（如 `v4.6.5`）；失败返回 null。
  @override
  Future<String?> probeConnection() => _client.fetchVersion();

  /// 确保分类存在（qb 侧 409 已存在也算成功）。
  @override
  Future<bool> prepareCategory(String category) =>
      _client.ensureCategory(category);

  /// 添加单条下载，透传顺序下载与首尾块优先开关。
  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) =>
      _client.addTorrents(
        <String>[magnetOrUrl],
        category: category,
        sequentialDownload: sequential,
        firstLastPiecePrio: firstLastPiecePrio,
      );

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) =>
      _client.fetchTorrents(category: category);

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) =>
      _client.fetchTorrentFiles(torrentId);

  @override
  void close() => _client.close();
}
