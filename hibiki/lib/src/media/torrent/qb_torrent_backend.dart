import 'package:hibiki/src/media/torrent/qbittorrent_client.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';

/// [TorrentBackend] 的外接 qBittorrent 实现：纯转发适配器，把接口语义
/// 一一映射到 [QBittorrentClient] 的 WebUI 调用，不加任何额外逻辑。
class QbTorrentBackend
    implements
        TorrentRemovalBackend,
        TorrentPauseBackend,
        TorrentDetailBackend,
        TorrentMetainfoBackend {
  QbTorrentBackend(this._client);

  final QBittorrentClient _client;

  /// qb WebUI 一直有暂停/恢复端点（4.x pause/resume、5.x stop/start，
  /// 客户端已双名兼容），能力恒可用。
  @override
  bool get pauseControlAvailable => true;

  @override
  Future<bool> pauseTorrent(String torrentId) =>
      _client.pauseTorrent(torrentId);

  @override
  Future<bool> resumeTorrent(String torrentId) =>
      _client.resumeTorrent(torrentId);

  /// 连接测试 = 拉 WebUI 版本号（如 `v4.6.5`）；失败返回 null。
  @override
  Future<String?> probeConnection() => _client.fetchVersion();

  /// 最近一次连接/登录失败的可读原因（BUG-1295：设置页测试连接透传显示，
  /// 不再把网络不通/账密错/IP 被封折叠成同一句话）。
  String? get lastProbeFailure => _client.lastFailure;

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
  Future<bool> addTorrentMetainfo(
    TorrentMetainfoPayload payload, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) =>
      _client.addTorrentFile(
        payload.bytes,
        fileName: payload.fileName,
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
  Future<bool> removeTorrent(String torrentId, {bool deleteFiles = false}) =>
      _client.deleteTorrent(torrentId, deleteFiles: deleteFiles);

  /// TODO-1961-c：qb 的 renameFile 认的是**旧相对路径**而不是文件下标，
  /// 所以先用文件列表把下标翻成路径（内置引擎那边下标就是天然主键）。
  /// 翻不出来说明种子/下标不对，直接报错而不是猜一个路径去改。
  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async {
    final List<TorrentFileEntry> files = await _client.fetchTorrentFiles(
      torrentId,
    );
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
      ok: ok,
      path: ok ? newPath : null,
      error: error,
    );
  }

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async {
    final (bool ok, String? error) = await _client.setLocation(
      hash: torrentId,
      location: newSavePath,
    );
    return TorrentStorageResult(
      ok: ok,
      path: ok ? newSavePath : null,
      error: error,
    );
  }

  /// TODO-2482：qb WebUI API v2（qBittorrent 4.1+）从一开始就带全部详情
  /// 端点（peers/trackers/files/filePrio/transfer/pieceStates），能力恒可用。
  @override
  bool get detailAvailable => true;

  @override
  Future<List<TorrentPeerDetail>?> listPeers(String torrentId) =>
      _client.fetchTorrentPeers(torrentId);

  @override
  Future<List<TorrentTrackerDetail>?> listTrackers(String torrentId) =>
      _client.fetchTrackers(torrentId);

  @override
  Future<List<TorrentFilePriority>?> filePriorities(String torrentId) =>
      _client.fetchFilePriorities(torrentId);

  /// 中性优先级 → qb filePrio 写值：skip=0 / normal=1 / high=6
  /// （与 [TorrentFilePriority] 的 doc 注释映射一致；读侧 1/4/5 都归
  /// normal，写侧统一写 1）。
  static int _qbPriorityValue(TorrentFilePriority priority) {
    switch (priority) {
      case TorrentFilePriority.skip:
        return 0;
      case TorrentFilePriority.normal:
        return 1;
      case TorrentFilePriority.high:
        return 6;
    }
  }

  @override
  Future<bool> setFilePriority(
    String torrentId,
    int fileIndex,
    TorrentFilePriority priority,
  ) =>
      _client.setFilePriority(
        hash: torrentId,
        fileIndexes: <int>[fileIndex],
        priority: _qbPriorityValue(priority),
      );

  @override
  Future<TorrentSessionStatusInfo?> sessionStatus() =>
      _client.fetchSessionStatus();

  @override
  Future<TorrentPieceStates?> pieceStates(String torrentId) =>
      _client.fetchPieceStates(torrentId);

  @override
  void close() => _client.close();
}
