import 'dart:io';

import 'package:hibiki/src/media/torrent/download_save_root.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/media/torrent/torrent_task_display.dart';
import 'package:hibiki_torrent/hibiki_torrent.dart';

/// [TorrentBackend] 的内置 libtorrent 实现（阶段1b：Windows 先行）。
///
/// 映射约定：
/// - 分类 = `<活动下载根>/<category>/` 子目录：add 落到活动根的分类目录，
///   listTorrents 按 [TorrentSaveRoots.ownsCategoryPath] 认**所有**根（活动 +
///   历史）—— 目录即真相，不另建分类账本。TODO-1961：用户改下载目录后，旧任务
///   的 savePath 仍指着旧根，只认单根会让它们整批从下载页消失。
/// - [addTorrent] 只接受 magnet 链接与本地 .torrent 文件路径；
///   http(s) .torrent URL 是外接 qb 的能力，内置引擎的选种链路
///   （Nyaa）本来就产 magnet，不为不存在的调用方加下载器。
/// - firstLastPiecePrio：libtorrent 无 add 期开关（元数据未就绪无从提优），
///   记入 [_pendingFirstLast]，在每次 [listTorrents] 轮询时补应用 ——
///   上层服务本就以 20s tick 轮询，无需额外定时器。
/// - close 只关本后端持有的 session；引擎（DLL）进程级共享不关。
class EmbeddedTorrentBackend
    implements
        TorrentRemovalBackend,
        TorrentPauseBackend,
        TorrentDetailBackend {
  EmbeddedTorrentBackend({
    required EmbeddedTorrentSession session,
    required TorrentSaveRoots saveRoots,
    bool closesSession = true,
    EmbeddedPauseControl? pauseControl,
  })  : _session = session,
        _saveRoots = saveRoots,
        _closesSession = closesSession,
        _pauseControl = pauseControl;

  final EmbeddedTorrentSession _session;

  /// TODO-2481：宿主注入的暂停控制通道；null = standalone（自持 session），
  /// 退化为直接调 session + 自持暂停集合（backend 与 session 同寿命）。
  final EmbeddedPauseControl? _pauseControl;

  /// standalone 形态下自持的「已知暂停」集合（infohash 小写）。
  final Set<String> _localPaused = <String>{};

  /// 活动根 + 历史根。写入只用活动根，列表认全部（见类注释）。
  final TorrentSaveRoots _saveRoots;

  /// close() 是否真的销毁底层 session。standalone/测试用途持有自己的
  /// session → true；app 侧 [EmbeddedTorrentHost] 派发的短命适配器共享
  /// 常驻 session → false（每 tick 建/关适配器不能连累会话）。
  final bool _closesSession;

  /// 已添加但 firstLastPiecePrio 尚未应用成功（等元数据）的种子。
  final Set<String> _pendingFirstLast = <String>{};

  /// 就绪测试 = 引擎版本串（如 `libtorrent 2.0.11.0`）；session 已关返回 null。
  @override
  Future<String?> probeConnection() async {
    if (_session.isClosed) return null;
    final String version = _session.engine.libtorrentVersion();
    return version.isEmpty ? null : 'libtorrent $version';
  }

  /// 分类目录建好即可用（永远建在**活动**根下）。
  @override
  Future<bool> prepareCategory(String category) async {
    try {
      await Directory(_categoryPath(category)).create(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    final String savePath = _categoryPath(category);
    if (!await prepareCategory(category)) return false;
    final HtAddResult result;
    if (magnetOrUrl.startsWith('magnet:')) {
      result = _session.addMagnet(
        magnetOrUrl,
        savePath: savePath,
        sequential: sequential,
      );
    } else if (magnetOrUrl.toLowerCase().endsWith('.torrent') &&
        !magnetOrUrl.contains('://')) {
      result = _session.addTorrentFile(
        magnetOrUrl,
        savePath: savePath,
        sequential: sequential,
      );
    } else {
      // http(s) .torrent URL：内置引擎不支持（见类注释）。
      return false;
    }
    if (!result.ok || result.id == null) return false;
    if (firstLastPiecePrio) {
      // 立即试一次（.torrent 文件路径元数据现成）；不成留待轮询补。
      if (_session.applyFirstLastPriority(result.id!) != 1) {
        _pendingFirstLast.add(result.id!);
      }
    }
    return true;
  }

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async {
    _applyPendingFirstLast();
    return _session
        .listTorrents()
        .where(
          (HtTorrentStatus t) =>
              category == null ||
              _saveRoots.ownsCategoryPath(t.savePath, category),
        )
        .map(_toSnapshot)
        .toList(growable: false);
  }

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async {
    final List<HtFileEntry>? files = _session.torrentFiles(torrentId);
    if (files == null) return const <TorrentFileEntry>[];
    return files
        .map(
          (HtFileEntry f) => TorrentFileEntry(
            name: f.path,
            size: f.size,
            progress: f.size <= 0 ? 1.0 : (f.done / f.size).clamp(0.0, 1.0),
            index: f.index,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<bool> removeTorrent(
    String torrentId, {
    bool deleteFiles = false,
  }) async =>
      _session.removeTorrent(torrentId, deleteFiles: deleteFiles);

  /// 暂停/恢复原语与上传策略同一组 DLL 符号；老随包 DLL 缺符号时 false。
  @override
  bool get pauseControlAvailable =>
      _pauseControl?.available() ?? _session.supportsUploadControl;

  @override
  Future<bool> pauseTorrent(String torrentId) async {
    final EmbeddedPauseControl? control = _pauseControl;
    if (control != null) return control.pause(torrentId);
    final String id = torrentId.toLowerCase();
    if (!_session.pauseTorrent(id, pause: true)) return false;
    _localPaused.add(id);
    return true;
  }

  @override
  Future<bool> resumeTorrent(String torrentId) async {
    final EmbeddedPauseControl? control = _pauseControl;
    if (control != null) return control.resume(torrentId);
    final String id = torrentId.toLowerCase();
    if (!_session.pauseTorrent(id, pause: false)) return false;
    _localPaused.remove(id);
    return true;
  }

  /// 该种子是否已知处于暂停态（宿主真相优先；standalone 用自持集合）。
  bool _isPausedForDisplay(String infoHash) =>
      _pauseControl?.isPaused(infoHash) ??
      _localPaused.contains(infoHash.toLowerCase());

  // ── TODO-2482：TorrentDetailBackend（详情页数据面）──────────────────

  /// 详情批次与随包 DLL 的符号组绑定；老 DLL 缺符号时 false（UI 显示
  /// 「当前后端不支持」而不是空白）。
  @override
  bool get detailAvailable => _session.supportsDetailInfo;

  @override
  Future<List<TorrentPeerDetail>?> listPeers(String torrentId) async {
    final List<HtPeerInfo>? peers = _session.torrentPeers(torrentId);
    if (peers == null) return null;
    return peers
        .map(
          (HtPeerInfo p) => TorrentPeerDetail(
            address: p.ip,
            port: p.port,
            client: p.client,
            progress: p.progress,
            downSpeedBps: p.downSpeed,
            upSpeedBps: p.upSpeed,
            // 语义对齐 qb：downloaded = 从该 peer 下到的字节（native
            // total_download 同义）、uploaded = 喂给该 peer 的字节。
            downloadedBytes: p.totalDownload,
            uploadedBytes: p.totalUpload,
            flags: formatTorrentPeerFlags(p.flagsBits),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<TorrentTrackerDetail>?> listTrackers(String torrentId) async {
    final List<HtTrackerInfo>? trackers = _session.torrentTrackers(torrentId);
    if (trackers == null) return null;
    return trackers
        .map(
          (HtTrackerInfo t) => TorrentTrackerDetail(
            url: t.url,
            tier: t.tier,
            status: t.updating
                ? TorrentTrackerStatus.updating
                : t.working
                    ? TorrentTrackerStatus.working
                    : (t.fails > 0 || t.lastError.isNotEmpty)
                        ? TorrentTrackerStatus.notWorking
                        : TorrentTrackerStatus.notContacted,
            seeds: t.scrapeComplete,
            leeches: t.scrapeIncomplete,
            downloaded: t.scrapeDownloaded,
            message: t.message.isNotEmpty ? t.message : t.lastError,
          ),
        )
        .toList(growable: false);
  }

  /// libtorrent download_priority（0~7）→ 三态。1~5 归 normal、6~7 归
  /// high（与 qb 的 filePrio 值域折叠口径一致）。
  @override
  Future<List<TorrentFilePriority>?> filePriorities(String torrentId) async {
    final List<int>? raw = _session.getFilePriorities(torrentId);
    if (raw == null) return null;
    return raw
        .map(
          (int p) => p <= 0
              ? TorrentFilePriority.skip
              : p >= 6
                  ? TorrentFilePriority.high
                  : TorrentFilePriority.normal,
        )
        .toList(growable: false);
  }

  @override
  Future<bool> setFilePriority(
    String torrentId,
    int fileIndex,
    TorrentFilePriority priority,
  ) async {
    final int value = switch (priority) {
      TorrentFilePriority.skip => 0,
      TorrentFilePriority.normal => 4,
      TorrentFilePriority.high => 7,
    };
    return _session.setFilePriority(torrentId, fileIndex, value);
  }

  @override
  Future<TorrentSessionStatusInfo?> sessionStatus() async {
    final HtSessionStatus? status = _session.sessionStatus();
    if (status == null) return null;
    return TorrentSessionStatusInfo(
      dhtEnabled: status.dhtRunning,
      dhtNodes: status.dhtNodes,
      lsdEnabled: status.lsdEnabled,
      pexEnabled: status.pexEnabled,
      listenPort: status.listenPort,
      downRateBps: status.downRate,
      upRateBps: status.upRate,
      portMappings: status.portMappings
          .map(
            (HtPortMapping m) => TorrentPortMappingInfo(
              transport: m.transport,
              protocol: m.protocol,
              externalPort: m.externalPort,
              ok: m.ok,
              error: m.error,
            ),
          )
          .toList(growable: false),
    );
  }

  /// 内置引擎位图只有持有/未持有两态：'1' → 2（已持有）、'0' → 0（缺）。
  @override
  Future<TorrentPieceStates?> pieceStates(String torrentId) async {
    final HtPieceMap? map = _session.torrentPieces(torrentId);
    if (map == null) return null;
    return TorrentPieceStates(
      states: map.have.codeUnits
          .map((int c) => c == 0x31 ? 2 : 0)
          .toList(growable: false),
    );
  }

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async =>
      _toStorageResult(_session.renameFile(torrentId, fileIndex, newPath));

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async =>
      _toStorageResult(_session.moveStorage(torrentId, newSavePath));

  static TorrentStorageResult _toStorageResult(HtStorageOpResult r) =>
      TorrentStorageResult(ok: r.ok, path: r.path, error: r.error);

  @override
  void close() {
    if (_closesSession) _session.close();
  }

  String _categoryPath(String category) => _saveRoots.categoryPathFor(category);

  /// 元数据未就绪时挂起的首尾块提优，随轮询补应用。
  void _applyPendingFirstLast() {
    if (_pendingFirstLast.isEmpty) return;
    _pendingFirstLast.removeWhere((String id) {
      final int result = _session.applyFirstLastPriority(id);
      // 1 = 应用成功；-1 = 种子已不存在 —— 两者都不必再试。
      return result != 0;
    });
  }

  TorrentSnapshot _toSnapshot(HtTorrentStatus t) {
    // TODO-2481：native 的 state_label 不导出 paused（libtorrent 里 paused
    // 是 flag 不是 state），已知暂停的种子把 state 覆写成 qb 词汇
    // pausedDL/pausedUP —— UI 状态文本与 [TorrentSnapshot.isComplete]
    // （pausedUP 属做种类）吃的都是这个词。
    final String state = _isPausedForDisplay(t.id)
        ? (t.isFinished ? 'pausedUP' : 'pausedDL')
        : t.state;
    return TorrentSnapshot(
      hash: t.id,
      name: t.name,
      progress: t.progress,
      state: state,
      savePath: t.savePath,
      contentPath: t.contentPath,
      amountLeft: t.left,
      // BUG-1294：native 一直导出速率/流量/peer 数，此前在这里被丢弃。
      downRateBps: t.downRate,
      upRateBps: t.upRate,
      downloadedBytes: t.downloaded,
      uploadedBytes: t.uploaded,
      numPeers: t.numPeers,
      // TODO-2482：详情拆分字段（老 DLL 缺键时 -1 原样透传 = 未提供）。
      numSeeds: t.numSeeds,
      numLeechs: t.numSeeds >= 0 ? t.numPeers - t.numSeeds : -1,
      swarmSeeds: t.numComplete,
      swarmLeechs: t.numIncomplete,
      numConnections: t.numConnections,
      activeDurationSeconds: t.activeDurationSeconds,
      seedingDurationSeconds: t.seedingDurationSeconds,
    );
  }
}

/// TODO-2481：宿主注入的暂停控制通道。暂停状态的真相在常驻
/// `EmbeddedTorrentHost`（短命适配器每 tick 重建，自持状态活不过一轮），
/// backend 只做转发；standalone 场景不传，backend 退化为直连 session。
class EmbeddedPauseControl {
  const EmbeddedPauseControl({
    required this.available,
    required this.pause,
    required this.resume,
    required this.isPaused,
  });

  /// 运行时能力位（老 DLL 缺 `ht_pause_torrent` 符号时 false）。
  final bool Function() available;

  /// 暂停一个种子（入参 infohash），返回是否成功。
  final bool Function(String infoHash) pause;

  /// 恢复一个种子，返回是否成功。
  final bool Function(String infoHash) resume;

  /// 该种子当前是否已知处于暂停态（用户或策略）。
  final bool Function(String infoHash) isPaused;
}
