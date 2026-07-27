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

  /// TODO-1961-c：qb 的 renameFile 认的是**旧相对路径**而不是文件下标，
  /// 所以先用文件列表把下标翻成路径（内置引擎那边下标就是天然主键）。
  /// 翻不出来说明种子/下标不对，直接报错而不是猜一个路径去改。
  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async {
    final List<TorrentFileEntry> files =
        await _client.fetchTorrentFiles(torrentId);
    String? oldPath;
    for (final TorrentFileEntry f in files) {
      if (f.index == fileIndex) {
        oldPath = f.name;
        break;
      }
    }
    if (oldPath == null) {
      return const TorrentStorageResult.failure('file index not found');
    }
    final (bool ok, String? error) = await _client.renameFile(
      hash: torrentId,
      oldPath: oldPath,
      newPath: newPath,
    );
    return TorrentStorageResult(
        ok: ok, path: ok ? newPath : null, error: error);
  }

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async {
    final (bool ok, String? error) =
        await _client.setLocation(hash: torrentId, location: newSavePath);
    return TorrentStorageResult(
        ok: ok, path: ok ? newSavePath : null, error: error);
  }

  @override
  void close() => _client.close();
}
