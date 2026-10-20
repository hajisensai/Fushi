import 'dart:async';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_worker.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_memory.dart';
import 'package:fushi_engine/media/torrent/tracker_subscription.dart';
import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:meta/meta.dart';

/// [EmbeddedTorrentHost] 的 UI isolate 一侧（BUG-3571）。
///
/// 宿主整体跑在 [EmbeddedTorrentWorker] 的专用 isolate 里；这里的每个方法都
/// 是一条粗粒度命令，返回 `Future`，**绝不在调用方 isolate 上碰 FFI**。生产代码
/// （app / 无头服务端）只能经本类使用内置引擎，守卫
/// `fushi/test/media/torrent/embedded_torrent_off_ui_isolate_guard_test.dart`。
///
/// 命令在工作 isolate 里按发送顺序逐条执行，所以「先 applySessionSettings、
/// 再 setUploadPolicy」这类先后依赖照旧成立，调用方不必互相 await。
class EmbeddedTorrentHostClient {
  EmbeddedTorrentHostClient._(this._worker)
    : _hasRestored = _worker.hasRestoredAtOpen;

  final EmbeddedTorrentWorker _worker;
  int _nextViewId = 0;
  bool _hasRestored;

  /// [post] 已经为「工作 isolate 已关」记过一笔（之后静默丢弃，不每 tick 刷屏）。
  bool _loggedPostAfterClose = false;

  /// 起工作 isolate 并在其中打开宿主。DLL 缺失 / session 创建失败返回 null。
  ///
  /// [factory] 仅测试覆盖（顶层函数，在工作 isolate 里执行）。
  static Future<EmbeddedTorrentHostClient?> open(
    EmbeddedTorrentHostOpenArgs args, {
    EmbeddedTorrentHostFactory factory = openEmbeddedTorrentHost,
  }) async {
    final EmbeddedTorrentWorker? worker = await EmbeddedTorrentWorker.spawn(
      args,
      factory: factory,
    );
    if (worker == null) return null;
    return EmbeddedTorrentHostClient._(worker);
  }

  EmbeddedTorrentHostCapabilities get capabilities => _worker.capabilities;

  /// 底层引擎版本串（诊断/probe 用）。
  String get libtorrentVersion => capabilities.libtorrentVersion;

  /// 见 [EmbeddedTorrentHost.hasRestored]（本端镜像：open 时的握手值 +
  /// 之后每次 [restoreFromResume] 的结果）。
  bool get hasRestored => _hasRestored;

  bool get isClosed => _worker.isClosed;

  /// 客户端失效时完成（[dispose]，或工作 isolate 意外退出）；从不以错误完成。
  /// 持有方（[EmbeddedTorrentHostSlot]）据此摘下失效客户端，下次需要时重建。
  Future<void> get closed => _worker.closed;

  /// 工作 isolate 是否没经 [dispose] 就退出了（崩溃 / 未捕获错误）。
  bool get exitedUnexpectedly => _worker.exitedUnexpectedly;

  /// 投递式入口：调用方不等回执的命令（铺设置、每 tick 的扫描）一律经这里发，
  /// 别裸 `unawaited(client.xxx())`——工作 isolate 抛错或已关时那会变成 zone
  /// 未处理异步错误。
  ///
  /// [command] 是本客户端某个方法刚返回的 future（如 `post('applyLimits',
  /// client.applyLimits(...))`）；命令照常按发送顺序执行。失败记进
  /// [engineLog]：命令自身的错误每次都记；「工作 isolate 已关」只在第一次记
  /// 一条诊断——关掉之后每 tick 的投递都会撞上它，那是同一件事，
  /// 真正的退出原因已由 [EmbeddedTorrentWorker] 记过。
  void post(String operation, Future<Object?> command) {
    unawaited(
      command.then<void>(
        (Object? _) {},
        onError: (Object error, StackTrace stack) {
          if (error is EmbeddedTorrentWorkerClosed) {
            if (_loggedPostAfterClose) return;
            _loggedPostAfterClose = true;
            engineLog.logDiagnostic(
              'EmbeddedTorrentHostClient.$operation',
              'dropped: embedded torrent worker is closed',
            );
            return;
          }
          engineLog.log('EmbeddedTorrentHostClient.$operation', error, stack);
        },
      ),
    );
  }

  /// 底层 DLL 是否支持把限速套到局域网 peer。
  bool get supportsLocalPeerRateLimit =>
      capabilities.supportsLocalPeerRateLimit;

  /// 底层 DLL 是否具备 per-torrent 暂停/恢复原语。
  bool get supportsPauseControl => capabilities.supportsPauseControl;

  /// 见 [EmbeddedTorrentHost.restoreFromResume]。
  Future<int> restoreFromResume(Set<String>? keepIds) async {
    final (int restored, bool hasRestored) = await _worker.run(
      _restoreFromResume(keepIds),
    );
    _hasRestored = hasRestored;
    return restored;
  }

  /// 见 [EmbeddedTorrentHost.saveResumeSnapshot]。
  Future<int?> saveResumeSnapshot(Set<String>? keepIds, {bool force = false}) =>
      _worker.run(_saveResumeSnapshot(keepIds, force));

  /// 进程退出前的最后一次 resume 保存（不关 session），见
  /// [EmbeddedTorrentHost.flushResumeForExit]。工作 isolate 已关时 no-op。
  Future<void> flushResumeForExit(Set<String>? keepIds) async {
    if (isClosed) return;
    try {
      await _worker.run(_flushResumeForExit(keepIds));
    } on EmbeddedTorrentWorkerClosed {
      // 关闭与退出竞发：关闭路径自己已存过一次。
    }
  }

  /// 见 [EmbeddedTorrentHost.applyLimits]。
  Future<bool> applyLimits({
    int downloadKbps = 0,
    int uploadKbps = 0,
    int maxConnections = 0,
    bool limitLocalPeers = false,
  }) => _worker.run(
    _applyLimits(downloadKbps, uploadKbps, maxConnections, limitLocalPeers),
  );

  /// 见 [EmbeddedTorrentHost.applyMemorySettings]。
  Future<bool> applyMemorySettings(
    TorrentMemorySettings settings, {
    int connectionsLimit = 0,
  }) => _worker.run(_applyMemorySettings(settings, connectionsLimit));

  /// 见 [EmbeddedTorrentHost.applySessionSettings]。
  Future<bool> applySessionSettings(QbConnectionConfig config) =>
      _worker.run(_applySessionSettings(config));

  /// 见 [EmbeddedTorrentHost.applyProxy]。
  Future<bool> applyProxy(String? hostPort, {bool mixed = false}) =>
      _worker.run(_applyProxy(hostPort, mixed));

  /// 见 [EmbeddedTorrentHost.setExtraTrackers]。
  Future<void> setExtraTrackers(List<String> trackers) =>
      _worker.run(_setExtraTrackers(List<String>.of(trackers)));

  /// 见 [EmbeddedTorrentHost.addDhtNodes]。
  Future<int> addDhtNodes(List<String> hostPorts) =>
      _worker.run(_addDhtNodes(List<String>.of(hostPorts)));

  /// 见 [EmbeddedTorrentHost.sessionStatus]。
  Future<FtSessionStatus?> sessionStatus() => _worker.run(_sessionStatus);

  /// 见 [EmbeddedTorrentHost.reconcileNetworkDiscoveryState]。
  Future<bool> reconcileNetworkDiscoveryState() =>
      _worker.run(_reconcileNetworkDiscoveryState);

  /// 见 [EmbeddedTorrentHost.applyAntiLeechConfig]。
  Future<void> applyAntiLeechConfig(QbConnectionConfig config) =>
      _worker.run(_applyAntiLeechConfig(config));

  /// 见 [EmbeddedTorrentHost.setUploadPolicy]。
  Future<void> setUploadPolicy(QbConnectionConfig config) =>
      _worker.run(_setUploadPolicy(config));

  /// 见 [EmbeddedTorrentHost.sweepAntiLeech]。
  Future<int> sweepAntiLeech() => _worker.run(_sweepAntiLeech);

  /// 见 [EmbeddedTorrentHost.sweepUploadPolicy]。
  Future<int> sweepUploadPolicy() => _worker.run(_sweepUploadPolicy);

  /// 见 [EmbeddedTorrentHost.setActiveSaveRoot]。
  Future<void> setActiveSaveRoot(String newActiveRoot) =>
      _worker.run(_setActiveSaveRoot(newActiveRoot));

  /// 见 [EmbeddedTorrentHost.pauseTorrentByUser]。
  Future<bool> pauseTorrentByUser(String infoHash) =>
      _worker.run(_pauseTorrentByUser(infoHash));

  /// 见 [EmbeddedTorrentHost.resumeTorrentByUser]。
  Future<bool> resumeTorrentByUser(String infoHash) =>
      _worker.run(_resumeTorrentByUser(infoHash));

  /// 派发一个短命后端代理（共享常驻 session；其 close 不销毁会话）。
  EmbeddedTorrentBackendProxy backendView({
    TrackerSubscriptionService? trackerSubscriptionService,
    bool autoAddTrackerSubscription = false,
    String trackerSubscriptionUrl = '',
  }) {
    return EmbeddedTorrentBackendProxy(
      host: Future<EmbeddedTorrentHostClient?>.value(this),
      capabilities: capabilities,
      trackerSubscriptionService: trackerSubscriptionService,
      autoAddTrackerSubscription: autoAddTrackerSubscription,
      trackerSubscriptionUrl: trackerSubscriptionUrl,
    );
  }

  /// 释放常驻 session（强制存一次 resume 后关 session、退出工作 isolate）。
  /// 幂等。见 [EmbeddedTorrentHost.dispose]。
  Future<void> dispose({Set<String>? keepIds}) =>
      _worker.close(_disposeHost(keepIds));

  Future<R> _run<R>(EmbeddedTorrentCommand<R> command) => _worker.run(command);

  /// 仅测试：在工作 isolate 里执行任意命令（读假绑定在那边记下的调用等）。
  @visibleForTesting
  Future<R> runForTesting<R>(EmbeddedTorrentCommand<R> command) =>
      _worker.run(command);

  int _allocateViewId() => _nextViewId++;
}

/// [EmbeddedTorrentHostClient] 派发的 [TorrentBackend]：每个方法转发到工作
/// isolate 里的一个 [EmbeddedTorrentBackend] 视图（首次使用时建，close 时释放）。
///
/// [host] 是 Future：app 的后端工厂是同步的（下载服务每 tick 同步取后端），而
/// 起工作 isolate 是异步的——工厂先同步交出代理，方法里再等宿主就绪。宿主最终
/// 没打开（session 创建失败）时一律按「后端不可用」作答（false / 空 / null），
/// 与 [TorrentBackend] 的容错契约同姿态。
///
/// 订阅 tracker 在本 isolate 拉（app 装配的代理感知 http client 带不过 isolate
/// 边界），add 成功后按 infohash 追加——与 [EmbeddedTorrentBackend] 自持订阅服务
/// 时「先 add、后拉订阅、再追加」同序。
class EmbeddedTorrentBackendProxy
    implements
        TorrentRemovalBackend,
        TorrentPauseBackend,
        TorrentDetailBackend,
        TorrentMetainfoBackend,
        TorrentPausedMetainfoBackend,
        TorrentBulkFilePriorityBackend,
        TorrentTrackerMutationBackend {
  EmbeddedTorrentBackendProxy({
    required Future<EmbeddedTorrentHostClient?> host,
    required EmbeddedTorrentHostCapabilities capabilities,
    TrackerSubscriptionService? trackerSubscriptionService,
    bool autoAddTrackerSubscription = false,
    String trackerSubscriptionUrl = '',
  }) : _host = host,
       _capabilities = capabilities,
       _trackerSubscriptionService = trackerSubscriptionService,
       _autoAddTrackerSubscription = autoAddTrackerSubscription,
       _trackerSubscriptionUrl = trackerSubscriptionUrl;

  final Future<EmbeddedTorrentHostClient?> _host;
  final EmbeddedTorrentHostCapabilities _capabilities;
  final TrackerSubscriptionService? _trackerSubscriptionService;
  final bool _autoAddTrackerSubscription;
  final String _trackerSubscriptionUrl;

  /// 工作 isolate 里的视图（首次使用时登记；null = 宿主不可用）。
  Future<(EmbeddedTorrentHostClient, int)?>? _view;
  bool _closed = false;

  Future<(EmbeddedTorrentHostClient, int)?> _ensureView() =>
      _view ??= _openView();

  Future<(EmbeddedTorrentHostClient, int)?> _openView() async {
    final EmbeddedTorrentHostClient? client = await _host;
    if (client == null || client.isClosed) return null;
    final int viewId = client._allocateViewId();
    await client._run(_openViewCommand(viewId));
    return (client, viewId);
  }

  /// 在视图上执行一条命令；宿主不可用 / 已关 / 命令抛错时返回 [fallback]
  /// （抛错会记日志，不静默）。
  Future<R> _onView<R>(
    String operation,
    R fallback,
    EmbeddedTorrentCommand<R> Function(int viewId) build,
  ) async {
    if (_closed) return fallback;
    try {
      final (EmbeddedTorrentHostClient, int)? view = await _ensureView();
      if (view == null) return fallback;
      return await view.$1._run(build(view.$2));
    } on EmbeddedTorrentWorkerClosed {
      return fallback;
    } on EmbeddedTorrentWorkerError catch (e, s) {
      engineLog.log('EmbeddedTorrentBackendProxy.$operation', e, s);
      return fallback;
    }
  }

  @override
  Future<String?> probeConnection() =>
      _onView<String?>('probeConnection', null, _probeConnection);

  @override
  Future<bool> prepareCategory(String category) => _onView<bool>(
    'prepareCategory',
    false,
    (int v) => _prepareCategory(v, category),
  );

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    final String? id = await _onView<String?>(
      'addTorrent',
      null,
      (int v) => _addTorrent(
        v,
        magnetOrUrl,
        category,
        savePath,
        sequential,
        firstLastPiecePrio,
      ),
    );
    if (id == null) return false;
    await _addSubscriptionTrackers(id);
    return true;
  }

  @override
  Future<bool> addTorrentMetainfo(
    TorrentMetainfoPayload payload, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    final String? id = await _onView<String?>(
      'addTorrentMetainfo',
      null,
      (int v) => _addTorrentMetainfo(
        v,
        payload,
        category,
        savePath,
        sequential,
        firstLastPiecePrio,
      ),
    );
    if (id == null) return false;
    await _addSubscriptionTrackers(id);
    return true;
  }

  @override
  Future<bool> addTorrentMetainfoPaused(
    TorrentMetainfoPayload payload, {
    required String category,
    String? savePath,
  }) async {
    final String? id = await _onView<String?>(
      'addTorrentMetainfoPaused',
      null,
      (int v) => _addTorrentMetainfoPaused(v, payload, category, savePath),
    );
    if (id == null) return false;
    await _addSubscriptionTrackers(id);
    return true;
  }

  Future<void> _addSubscriptionTrackers(String torrentId) async {
    final TrackerSubscriptionService? service = _trackerSubscriptionService;
    if (!_autoAddTrackerSubscription ||
        service == null ||
        _trackerSubscriptionUrl.trim().isEmpty) {
      return;
    }
    final List<String> trackers;
    try {
      trackers = await service.fetch(_trackerSubscriptionUrl);
    } on Object {
      return;
    }
    if (trackers.isEmpty) return;
    await addTrackers(torrentId, trackers);
  }

  @override
  Future<bool> addTrackers(String torrentId, Iterable<String> trackerUrls) {
    final List<String> urls = trackerUrls.toList(growable: false);
    return _onView<bool>(
      'addTrackers',
      false,
      (int v) => _addTrackers(v, torrentId, urls),
    );
  }

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) =>
      _onView<List<TorrentSnapshot>>(
        'listTorrents',
        const <TorrentSnapshot>[],
        (int v) => _listTorrents(v, category),
      );

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) =>
      _onView<List<TorrentFileEntry>>(
        'listFiles',
        const <TorrentFileEntry>[],
        (int v) => _listFiles(v, torrentId),
      );

  @override
  Future<bool> removeTorrent(String torrentId, {bool deleteFiles = false}) =>
      _onView<bool>(
        'removeTorrent',
        false,
        (int v) => _removeTorrent(v, torrentId, deleteFiles),
      );

  @override
  bool get pauseControlAvailable => _capabilities.supportsPauseControl;

  @override
  Future<bool> pauseTorrent(String torrentId) => _onView<bool>(
    'pauseTorrent',
    false,
    (int v) => _pauseTorrent(v, torrentId),
  );

  @override
  Future<bool> resumeTorrent(String torrentId) => _onView<bool>(
    'resumeTorrent',
    false,
    (int v) => _resumeTorrent(v, torrentId),
  );

  @override
  bool get detailAvailable => _capabilities.supportsDetailInfo;

  @override
  Future<List<TorrentPeerDetail>?> listPeers(String torrentId) =>
      _onView<List<TorrentPeerDetail>?>(
        'listPeers',
        null,
        (int v) => _listPeers(v, torrentId),
      );

  @override
  Future<List<TorrentTrackerDetail>?> listTrackers(String torrentId) =>
      _onView<List<TorrentTrackerDetail>?>(
        'listTrackers',
        null,
        (int v) => _listTrackers(v, torrentId),
      );

  @override
  Future<List<TorrentFilePriority>?> filePriorities(String torrentId) =>
      _onView<List<TorrentFilePriority>?>(
        'filePriorities',
        null,
        (int v) => _filePriorities(v, torrentId),
      );

  @override
  Future<bool> setFilePriority(
    String torrentId,
    int fileIndex,
    TorrentFilePriority priority,
  ) => _onView<bool>(
    'setFilePriority',
    false,
    (int v) => _setFilePriority(v, torrentId, fileIndex, priority),
  );

  @override
  Future<bool> setFilePriorities(
    String torrentId,
    Iterable<int> fileIndexes,
    TorrentFilePriority priority,
  ) {
    final List<int> indexes = fileIndexes.toList(growable: false);
    return _onView<bool>(
      'setFilePriorities',
      false,
      (int v) => _setFilePriorities(v, torrentId, indexes, priority),
    );
  }

  @override
  Future<TorrentSessionStatusInfo?> sessionStatus() =>
      _onView<TorrentSessionStatusInfo?>(
        'sessionStatus',
        null,
        _viewSessionStatus,
      );

  @override
  Future<TorrentPieceStates?> pieceStates(String torrentId) =>
      _onView<TorrentPieceStates?>(
        'pieceStates',
        null,
        (int v) => _pieceStates(v, torrentId),
      );

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) => _onView<TorrentStorageResult>(
    'renameFile',
    const TorrentStorageResult(ok: false, error: 'torrent engine closed'),
    (int v) => _renameFile(v, torrentId, fileIndex, newPath),
  );

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) => _onView<TorrentStorageResult>(
    'moveStorage',
    const TorrentStorageResult(ok: false, error: 'torrent engine closed'),
    (int v) => _moveStorage(v, torrentId, newSavePath),
  );

  /// 释放工作 isolate 里的视图；不关 session。
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final Future<(EmbeddedTorrentHostClient, int)?>? view = _view;
    if (view == null) return;
    unawaited(
      view
          .then(((EmbeddedTorrentHostClient, int)? opened) async {
            if (opened == null || opened.$1.isClosed) return;
            try {
              await opened.$1._run(_closeViewCommand(opened.$2));
            } on EmbeddedTorrentWorkerClosed {
              // 宿主已释放：视图随 isolate 一起没了。
            }
          })
          .catchError((Object e, StackTrace s) {
            engineLog.log('EmbeddedTorrentBackendProxy.close', e, s);
          }),
    );
  }
}

// ── 工作 isolate 命令 ─────────────────────────────────────────────────────
//
// 每条命令都由顶层函数构造：闭包只捕获参数（要发送进工作 isolate，不能捕获
// 持有 ReceivePort 的客户端/代理实例）。

EmbeddedTorrentCommand<(int, bool)> _restoreFromResume(Set<String>? keepIds) =>
    (EmbeddedTorrentWorkerState s) {
      final int restored = s.host.restoreFromResume(keepIds);
      return (restored, s.host.hasRestored);
    };

EmbeddedTorrentCommand<int?> _saveResumeSnapshot(
  Set<String>? keepIds,
  bool force,
) =>
    (EmbeddedTorrentWorkerState s) =>
        s.host.saveResumeSnapshot(keepIds, force: force);

EmbeddedTorrentCommand<int?> _flushResumeForExit(Set<String>? keepIds) =>
    (EmbeddedTorrentWorkerState s) => s.host.flushResumeForExit(keepIds);

EmbeddedTorrentCommand<bool> _applyLimits(
  int downloadKbps,
  int uploadKbps,
  int maxConnections,
  bool limitLocalPeers,
) =>
    (EmbeddedTorrentWorkerState s) => s.host.applyLimits(
      downloadKbps: downloadKbps,
      uploadKbps: uploadKbps,
      maxConnections: maxConnections,
      limitLocalPeers: limitLocalPeers,
    );

EmbeddedTorrentCommand<bool> _applyMemorySettings(
  TorrentMemorySettings settings,
  int connectionsLimit,
) =>
    (EmbeddedTorrentWorkerState s) => s.host.applyMemorySettings(
      settings,
      connectionsLimit: connectionsLimit,
    );

EmbeddedTorrentCommand<bool> _applySessionSettings(QbConnectionConfig config) =>
    (EmbeddedTorrentWorkerState s) => s.host.applySessionSettings(config);

EmbeddedTorrentCommand<bool> _applyProxy(String? hostPort, bool mixed) =>
    (EmbeddedTorrentWorkerState s) => s.host.applyProxy(hostPort, mixed: mixed);

EmbeddedTorrentCommand<void> _setExtraTrackers(List<String> trackers) =>
    (EmbeddedTorrentWorkerState s) => s.host.setExtraTrackers(trackers);

EmbeddedTorrentCommand<int> _addDhtNodes(List<String> hostPorts) =>
    (EmbeddedTorrentWorkerState s) => s.host.addDhtNodes(hostPorts);

FtSessionStatus? _sessionStatus(EmbeddedTorrentWorkerState s) =>
    s.host.sessionStatus();

bool _reconcileNetworkDiscoveryState(EmbeddedTorrentWorkerState s) =>
    s.host.reconcileNetworkDiscoveryState();

EmbeddedTorrentCommand<void> _applyAntiLeechConfig(QbConnectionConfig config) =>
    (EmbeddedTorrentWorkerState s) => s.host.applyAntiLeechConfig(config);

EmbeddedTorrentCommand<void> _setUploadPolicy(QbConnectionConfig config) =>
    (EmbeddedTorrentWorkerState s) => s.host.setUploadPolicy(config);

int _sweepAntiLeech(EmbeddedTorrentWorkerState s) => s.host.sweepAntiLeech();

int _sweepUploadPolicy(EmbeddedTorrentWorkerState s) =>
    s.host.sweepUploadPolicy();

EmbeddedTorrentCommand<void> _setActiveSaveRoot(String root) =>
    (EmbeddedTorrentWorkerState s) => s.host.setActiveSaveRoot(root);

EmbeddedTorrentCommand<bool> _pauseTorrentByUser(String infoHash) =>
    (EmbeddedTorrentWorkerState s) => s.host.pauseTorrentByUser(infoHash);

EmbeddedTorrentCommand<bool> _resumeTorrentByUser(String infoHash) =>
    (EmbeddedTorrentWorkerState s) => s.host.resumeTorrentByUser(infoHash);

EmbeddedTorrentCommand<Object?> _disposeHost(Set<String>? keepIds) =>
    (EmbeddedTorrentWorkerState s) {
      s.disposeHost(keepIds: keepIds);
      return null;
    };

EmbeddedTorrentCommand<void> _openViewCommand(int viewId) =>
    (EmbeddedTorrentWorkerState s) => s.openView(viewId);

EmbeddedTorrentCommand<void> _closeViewCommand(int viewId) =>
    (EmbeddedTorrentWorkerState s) => s.closeView(viewId);

EmbeddedTorrentCommand<String?> _probeConnection(int viewId) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).probeConnection();

EmbeddedTorrentCommand<bool> _prepareCategory(int viewId, String category) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).prepareCategory(category);

EmbeddedTorrentCommand<String?> _addTorrent(
  int viewId,
  String magnetOrUrl,
  String category,
  String? savePath,
  bool sequential,
  bool firstLastPiecePrio,
) =>
    (EmbeddedTorrentWorkerState s) => s
        .view(viewId)
        .addTorrentReturningId(
          magnetOrUrl,
          category: category,
          savePath: savePath,
          sequential: sequential,
          firstLastPiecePrio: firstLastPiecePrio,
        );

EmbeddedTorrentCommand<String?> _addTorrentMetainfo(
  int viewId,
  TorrentMetainfoPayload payload,
  String category,
  String? savePath,
  bool sequential,
  bool firstLastPiecePrio,
) =>
    (EmbeddedTorrentWorkerState s) => s
        .view(viewId)
        .addTorrentMetainfoReturningId(
          payload,
          category: category,
          savePath: savePath,
          sequential: sequential,
          firstLastPiecePrio: firstLastPiecePrio,
        );

EmbeddedTorrentCommand<String?> _addTorrentMetainfoPaused(
  int viewId,
  TorrentMetainfoPayload payload,
  String category,
  String? savePath,
) =>
    (EmbeddedTorrentWorkerState s) => s
        .view(viewId)
        .addTorrentMetainfoPausedReturningId(
          payload,
          category: category,
          savePath: savePath,
        );

EmbeddedTorrentCommand<bool> _addTrackers(
  int viewId,
  String torrentId,
  List<String> urls,
) =>
    (EmbeddedTorrentWorkerState s) =>
        s.view(viewId).addTrackers(torrentId, urls);

EmbeddedTorrentCommand<List<TorrentSnapshot>> _listTorrents(
  int viewId,
  String? category,
) =>
    (EmbeddedTorrentWorkerState s) =>
        s.view(viewId).listTorrents(category: category);

EmbeddedTorrentCommand<List<TorrentFileEntry>> _listFiles(
  int viewId,
  String torrentId,
) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).listFiles(torrentId);

EmbeddedTorrentCommand<bool> _removeTorrent(
  int viewId,
  String torrentId,
  bool deleteFiles,
) =>
    (EmbeddedTorrentWorkerState s) =>
        s.view(viewId).removeTorrent(torrentId, deleteFiles: deleteFiles);

EmbeddedTorrentCommand<bool> _pauseTorrent(int viewId, String torrentId) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).pauseTorrent(torrentId);

EmbeddedTorrentCommand<bool> _resumeTorrent(int viewId, String torrentId) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).resumeTorrent(torrentId);

EmbeddedTorrentCommand<List<TorrentPeerDetail>?> _listPeers(
  int viewId,
  String torrentId,
) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).listPeers(torrentId);

EmbeddedTorrentCommand<List<TorrentTrackerDetail>?> _listTrackers(
  int viewId,
  String torrentId,
) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).listTrackers(torrentId);

EmbeddedTorrentCommand<List<TorrentFilePriority>?> _filePriorities(
  int viewId,
  String torrentId,
) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).filePriorities(torrentId);

EmbeddedTorrentCommand<bool> _setFilePriority(
  int viewId,
  String torrentId,
  int fileIndex,
  TorrentFilePriority priority,
) =>
    (EmbeddedTorrentWorkerState s) =>
        s.view(viewId).setFilePriority(torrentId, fileIndex, priority);

EmbeddedTorrentCommand<bool> _setFilePriorities(
  int viewId,
  String torrentId,
  List<int> indexes,
  TorrentFilePriority priority,
) =>
    (EmbeddedTorrentWorkerState s) =>
        s.view(viewId).setFilePriorities(torrentId, indexes, priority);

EmbeddedTorrentCommand<TorrentSessionStatusInfo?> _viewSessionStatus(
  int viewId,
) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).sessionStatus();

EmbeddedTorrentCommand<TorrentPieceStates?> _pieceStates(
  int viewId,
  String torrentId,
) =>
    (EmbeddedTorrentWorkerState s) => s.view(viewId).pieceStates(torrentId);

EmbeddedTorrentCommand<TorrentStorageResult> _renameFile(
  int viewId,
  String torrentId,
  int fileIndex,
  String newPath,
) =>
    (EmbeddedTorrentWorkerState s) =>
        s.view(viewId).renameFile(torrentId, fileIndex, newPath);

EmbeddedTorrentCommand<TorrentStorageResult> _moveStorage(
  int viewId,
  String torrentId,
  String newSavePath,
) =>
    (EmbeddedTorrentWorkerState s) =>
        s.view(viewId).moveStorage(torrentId, newSavePath);
