/// 「下载后端 = 互联设备」：把一台已配对 Fushi（典型是跑在直连 VM 上的
/// fushi_server）的 BT 引擎当成本机的 [TorrentBackend] 用（`/api/torrent-engine`）。
///
/// 与外接 qBittorrent 同一层、同一契约：本机的下载管线、任务行、整理、入库、订阅、
/// 互联代下载全部照旧跑在本机，只有 BT 引擎在对端；下载落盘位置由路径映射
/// （按本后端的配置档 id）对上。所有方法容错——失败一律返回 null / false / 空表，
/// 绝不抛（连不上时的「后端离线」由管线经 [probeConnection] 判定，与 qb 一致）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/torrent/remote_torrent_wire.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/tracker_subscription.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// 每台 host 最近一次探到的引擎能力（按 [InterconnectHostRef.key]）。
///
/// [TorrentPauseBackend.pauseControlAvailable] / [TorrentDetailBackend.detailAvailable]
/// 是同步 getter，而管线每个 tick 都新建后端实例：能力必须跨实例缓存，否则每个
/// 新实例在首次往返前都只能瞎猜。
final Map<String, TorrentEngineCapability> _capabilityCache =
    <String, TorrentEngineCapability>{};

/// 仅测试：清空能力缓存。
@visibleForTesting
void resetRemoteTorrentEngineCapabilityCache() => _capabilityCache.clear();

class RemoteFushiTorrentBackend
    implements
        TorrentRemovalBackend,
        TorrentPauseBackend,
        TorrentDetailBackend,
        TorrentMetainfoBackend,
        TorrentPausedMetainfoBackend,
        TorrentBulkFilePriorityBackend,
        TorrentTrackerMutationBackend {
  RemoteFushiTorrentBackend({
    required SyncRepository repo,
    required this.host,
    http.Client? plainClient,
    @visibleForTesting InterconnectHostChannel? channel,
    TrackerSubscriptionService? trackerSubscriptionService,
    bool autoAddTrackerSubscription = false,
    String trackerSubscriptionUrl = '',
    Duration requestTimeout = const Duration(seconds: 30),
    Duration probeTimeout = const Duration(seconds: 6),
  }) : _channel =
           channel ??
           InterconnectHostChannel(
             repo: repo,
             host: host,
             plainClient: plainClient,
           ),
       _trackerSubscriptionService = trackerSubscriptionService,
       _autoAddTrackerSubscription = autoAddTrackerSubscription,
       _trackerSubscriptionUrl = trackerSubscriptionUrl,
       _requestTimeout = requestTimeout,
       _probeTimeout = probeTimeout {
    // 还没探过这台 host：后台补一次，让下一个实例的能力位是真值。
    if (!_capabilityCache.containsKey(host.key)) {
      unawaited(refreshCapability());
    }
  }

  /// 被借用引擎的那台 host。
  final InterconnectHostRef host;
  final InterconnectHostChannel _channel;
  final TrackerSubscriptionService? _trackerSubscriptionService;
  final bool _autoAddTrackerSubscription;
  final String _trackerSubscriptionUrl;
  final Duration _requestTimeout;
  final Duration _probeTimeout;
  bool _closed = false;

  /// 最近一次 [probeConnection] 失败的原因（设置页「测试连接」原样展示）；成功后清空。
  String? lastProbeFailure;

  /// 最近一次探到的能力；没探过 = null。
  TorrentEngineCapability? get capability => _capabilityCache[host.key];

  /// 没探过时按「对端是 Fushi 引擎、能力齐全」乐观处理：内置引擎与 qb 都实现全部
  /// 能力，真不支持时对端回 `ok:false`，调用方按失败处理（不会静默成功）。
  @override
  bool get pauseControlAvailable => capability?.pauseControlAvailable ?? true;

  @override
  bool get detailAvailable => capability?.detailAvailable ?? true;

  /// 重新探这台 host 的 `torrentEngine` 能力并写进缓存；探不到返回 null（缓存保留
  /// 上一次的值：一次网络抖动不该把能力位翻成 false）。
  Future<TorrentEngineCapability?> refreshCapability() async {
    if (_closed) return null;
    lastProbeFailure = null;
    try {
      final InterconnectCapabilityOutcome<TorrentEngineCapability> outcome =
          await probeInterconnectCapability<TorrentEngineCapability>(
            _channel,
            label: host.anchorUrl,
            timeout: _probeTimeout,
            parse: (Map<String, dynamic> caps, _) =>
                TorrentEngineCapability.fromJson(
                  caps[kTorrentEngineCapability],
                ),
          );
      if (outcome is InterconnectCapabilityAvailable<TorrentEngineCapability>) {
        _capabilityCache[host.key] = outcome.target;
        return outcome.target;
      }
      if (outcome
          is InterconnectCapabilityUnavailable<TorrentEngineCapability>) {
        lastProbeFailure =
            outcome.failure == InterconnectHostFailure.unsupported
            ? 'this device does not lend its torrent engine '
                  '(update Fushi on it)'
            : 'device unreachable: ${outcome.failure.name}';
      }
    } on Object {
      // 通道被关（cancelled）或其他意外：保持缓存不变。
    }
    return null;
  }

  /// 发一条命令；连不上 / 对端报错 → null（调用方映射成契约里的失败值）。
  Future<Map<String, dynamic>?> _call(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String> query = const <String, String>{},
    bool idempotent = false,
  }) async {
    if (_closed) return null;
    final InterconnectChannelResponse r;
    try {
      r = await _channel.send(
        method,
        '$kTorrentEngineRoutePrefix$path',
        query: query,
        body: body == null ? null : InterconnectRequestBody.json(body),
        timeout: _requestTimeout,
        idempotent: idempotent || method == 'GET',
      );
    } on InterconnectChannelException {
      return null;
    }
    if (r.statusCode >= 400) {
      // 400 / 404 是请求或状态问题（路径越界、种子不是远程任务）——记下原文，
      // 503 / 连接类是对端此刻没引擎，属于离线，不刷日志。
      if (r.statusCode != 503) {
        engineLog.logDiagnostic(
          'RemoteFushiTorrentBackend',
          '$method $path → HTTP ${r.statusCode}: '
              '${r.jsonString('error') ?? r.text}',
        );
      }
      return null;
    }
    return r.jsonObject ?? <String, dynamic>{};
  }

  String _t(String torrentId) =>
      '/torrents/${Uri.encodeComponent(torrentId.trim().toLowerCase())}';

  Future<bool> _ok(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String> query = const <String, String>{},
  }) async =>
      (await _call(method, path, body: body, query: query))?['ok'] == true;

  @override
  Future<String?> probeConnection() async {
    final TorrentEngineCapability? cap = await refreshCapability();
    if (cap == null) return null;
    if (!cap.supported) {
      lastProbeFailure =
          'the device has no usable torrent engine (backend: ${cap.backend})';
      return null;
    }
    final Map<String, dynamic>? r = await _call('GET', '/probe');
    final Object? version = r?['version'];
    if (version == null) {
      lastProbeFailure = 'the device did not answer the engine probe';
      return null;
    }
    return 'Fushi ${cap.backend} $version';
  }

  @override
  Future<bool> prepareCategory(String category) =>
      _ok('POST', '/categories', body: <String, Object?>{'category': category});

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) => _add(<String, Object?>{
    'magnet': magnetOrUrl,
    'category': category,
    'savePath': ?savePath,
    'sequential': sequential,
    'firstLastPiecePrio': firstLastPiecePrio,
  });

  @override
  Future<bool> addTorrentMetainfo(
    TorrentMetainfoPayload payload, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) => _add(<String, Object?>{
    'torrent': base64Encode(payload.bytes),
    'fileName': payload.fileName,
    'category': category,
    'savePath': ?savePath,
    'sequential': sequential,
    'firstLastPiecePrio': firstLastPiecePrio,
  });

  @override
  Future<bool> addTorrentMetainfoPaused(
    TorrentMetainfoPayload payload, {
    required String category,
    String? savePath,
  }) => _add(<String, Object?>{
    'torrent': base64Encode(payload.bytes),
    'fileName': payload.fileName,
    'category': category,
    'savePath': ?savePath,
    'paused': true,
  });

  Future<bool> _add(Map<String, Object?> body) async {
    final Map<String, dynamic>? r = await _call(
      'POST',
      '/torrents',
      body: body,
    );
    if (r == null || r['ok'] != true) return false;
    final String hash = '${r['hash'] ?? ''}';
    if (hash.isNotEmpty) await _addSubscriptionTrackers(hash);
    return true;
  }

  /// 与内置引擎同序：先加种子、再拉订阅、再追加 tracker。订阅在本机拉（本机的
  /// 代理 / 网络设置），追加命令发给对端。订阅失败不影响任务创建。
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
  Future<bool> addTrackers(String torrentId, Iterable<String> trackerUrls) =>
      _ok(
        'POST',
        '${_t(torrentId)}/trackers',
        body: <String, Object?>{'urls': trackerUrls.toList(growable: false)},
      );

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async {
    final Map<String, dynamic>? r = await _call(
      'GET',
      '/torrents',
      query: category == null
          ? const <String, String>{}
          : <String, String>{'category': category},
    );
    return decodeTorrentWireList<TorrentSnapshot>(
      r?['torrents'],
      torrentSnapshotFromWire,
    );
  }

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async {
    final Map<String, dynamic>? r = await _call(
      'GET',
      '${_t(torrentId)}/files',
    );
    return decodeTorrentWireList<TorrentFileEntry>(
      r?['files'],
      torrentFileEntryFromWire,
    );
  }

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) => _storage('${_t(torrentId)}/rename', <String, Object?>{
    'fileIndex': fileIndex,
    'newPath': newPath,
  });

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) => _storage('${_t(torrentId)}/move', <String, Object?>{
    'savePath': newSavePath,
  });

  /// 改名 / 移动：失败原因必须能原样呈现给用户（[TorrentStorageResult] 契约），
  /// 所以这里不走 [_call] 的「报错即 null」，而是把对端的错误原文带回来。
  Future<TorrentStorageResult> _storage(
    String path,
    Map<String, Object?> body,
  ) async {
    if (_closed) {
      return const TorrentStorageResult.failure('backend closed');
    }
    final InterconnectChannelResponse r;
    try {
      r = await _channel.send(
        'POST',
        '$kTorrentEngineRoutePrefix$path',
        body: InterconnectRequestBody.json(body),
        timeout: _requestTimeout,
      );
    } on InterconnectChannelException catch (e) {
      return TorrentStorageResult.failure(
        'the download device is unreachable (${e.code})',
      );
    }
    if (r.statusCode >= 400) {
      return TorrentStorageResult.failure(
        r.jsonString('error') ?? 'HTTP ${r.statusCode}: ${r.text}',
      );
    }
    return torrentStorageResultFromWire(r.jsonObject);
  }

  @override
  Future<bool> removeTorrent(String torrentId, {bool deleteFiles = false}) =>
      _ok(
        'DELETE',
        _t(torrentId),
        query: <String, String>{'deleteFiles': '$deleteFiles'},
      );

  @override
  Future<bool> pauseTorrent(String torrentId) =>
      _ok('POST', '${_t(torrentId)}/pause');

  @override
  Future<bool> resumeTorrent(String torrentId) =>
      _ok('POST', '${_t(torrentId)}/resume');

  @override
  Future<List<TorrentPeerDetail>?> listPeers(String torrentId) async {
    final Map<String, dynamic>? r = await _call(
      'GET',
      '${_t(torrentId)}/peers',
    );
    if (r == null || r['peers'] is! List) return null;
    return decodeTorrentWireList<TorrentPeerDetail>(
      r['peers'],
      torrentPeerDetailFromWire,
    );
  }

  @override
  Future<List<TorrentTrackerDetail>?> listTrackers(String torrentId) async {
    final Map<String, dynamic>? r = await _call(
      'GET',
      '${_t(torrentId)}/trackers',
    );
    if (r == null || r['trackers'] is! List) return null;
    return decodeTorrentWireList<TorrentTrackerDetail>(
      r['trackers'],
      torrentTrackerDetailFromWire,
    );
  }

  @override
  Future<List<TorrentFilePriority>?> filePriorities(String torrentId) async {
    final Map<String, dynamic>? r = await _call(
      'GET',
      '${_t(torrentId)}/priorities',
    );
    final Object? raw = r?['priorities'];
    if (raw is! List) return null;
    final List<TorrentFilePriority> out = <TorrentFilePriority>[];
    for (final Object? v in raw) {
      // 位置即文件下标：认不出的值不能跳过（会错位），整份作废。
      final TorrentFilePriority? p = torrentFilePriorityFromWire(v);
      if (p == null) return null;
      out.add(p);
    }
    return out;
  }

  @override
  Future<bool> setFilePriority(
    String torrentId,
    int fileIndex,
    TorrentFilePriority priority,
  ) => setFilePriorities(torrentId, <int>[fileIndex], priority);

  @override
  Future<bool> setFilePriorities(
    String torrentId,
    Iterable<int> fileIndexes,
    TorrentFilePriority priority,
  ) {
    final List<int> indexes = fileIndexes.toList(growable: false);
    if (indexes.isEmpty) return Future<bool>.value(true);
    return _ok(
      'POST',
      '${_t(torrentId)}/priorities',
      body: <String, Object?>{'indexes': indexes, 'priority': priority.name},
    );
  }

  @override
  Future<TorrentSessionStatusInfo?> sessionStatus() async =>
      torrentSessionStatusFromWire(
        (await _call('GET', '/session'))?['session'],
      );

  @override
  Future<TorrentPieceStates?> pieceStates(String torrentId) async {
    final Object? raw = (await _call(
      'GET',
      '${_t(torrentId)}/pieces',
    ))?['pieces'];
    if (raw is! List) return null;
    return TorrentPieceStates(
      states: <int>[for (final Object? v in raw) v is int ? v : 0],
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _channel.close();
  }
}
