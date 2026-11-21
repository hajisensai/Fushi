/// 「远程 Fushi 下载引擎」（`/api/torrent-engine`）的 wire 形状。
///
/// 一台 Fushi 把另一台已配对 Fushi 的 BT 引擎当作自己的下载后端用（与外接
/// qBittorrent 同一层：后端回答「用什么引擎下」，不是「在哪台设备入库」）。
/// 两端共用本文件的编解码：host 侧路由把 [TorrentBackend] 的返回值编成 JSON，
/// client 侧的远程后端再解回同一组中性数据类，上层管线看不出差别。
///
/// 解码一律容错（缺字段取数据类的缺省值），与 [TorrentBackend]「绝不抛」的契约
/// 同姿态：对端版本不齐时少几个字段只会让 UI 少显示几项，不会把轮询打断。
library;

import 'package:fushi_engine/media/torrent/torrent_backend.dart';

/// `/api/capabilities` 里本能力的键。
const String kTorrentEngineCapability = 'torrentEngine';

/// 路由前缀。
const String kTorrentEngineRoutePrefix = '/api/torrent-engine';

/// 能力位 `features` 的取值：对应 [TorrentBackend] 的各可选能力接口。
abstract final class TorrentEngineFeature {
  static const String removal = 'removal';
  static const String pause = 'pause';
  static const String detail = 'detail';
  static const String metainfo = 'metainfo';
  static const String pausedMetainfo = 'pausedMetainfo';
  static const String trackers = 'trackers';
  static const String bulkPriority = 'bulkPriority';
}

/// host 宣告的引擎能力（`capabilities.torrentEngine`）。
class TorrentEngineCapability {
  const TorrentEngineCapability({
    required this.supported,
    required this.backend,
    this.features = const <String>{},
    this.pauseControlAvailable,
    this.detailAvailable,
    this.allowedRoots = const <String>[],
  });

  /// 解析能力位；不是 map / 没宣告 supported → null（= host 不提供）。
  static TorrentEngineCapability? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? features = raw['features'];
    final Object? roots = raw['allowedRoots'];
    return TorrentEngineCapability(
      supported: raw['supported'] == true,
      backend: (raw['backend'] ?? '').toString(),
      features: features is List
          ? <String>{for (final Object? f in features) '$f'}
          : const <String>{},
      pauseControlAvailable: _optionalBool(raw['pauseControlAvailable']),
      detailAvailable: _optionalBool(raw['detailAvailable']),
      allowedRoots: roots is List
          ? <String>[for (final Object? r in roots) '$r']
          : const <String>[],
    );
  }

  /// 后端已起、能接命令。false = host 懂本协议但此刻没有可用引擎。
  final bool supported;

  /// host 实际用的引擎（`embedded` / `qbittorrent`）。
  final String backend;

  /// [TorrentEngineFeature] 子集。
  final Set<String> features;

  /// [TorrentPauseBackend.pauseControlAvailable] 的 host 侧取值；null = 未知（host
  /// 的内置引擎还没起，探测不为了回答它去拉起引擎）。
  final bool? pauseControlAvailable;

  /// [TorrentDetailBackend.detailAvailable] 的 host 侧取值；null 同上。
  final bool? detailAvailable;

  /// host 允许远程任务落盘的根目录（host 视角路径）。保存目录与移动目标必须在
  /// 其中之一下面；client 配路径映射时据此提示「对端那一侧的根」。
  final List<String> allowedRoots;

  bool has(String feature) => features.contains(feature);

  Map<String, Object?> toJson() => <String, Object?>{
    'supported': supported,
    'backend': backend,
    'features': features.toList(growable: false)..sort(),
    'pauseControlAvailable': pauseControlAvailable,
    'detailAvailable': detailAvailable,
    'allowedRoots': allowedRoots,
  };
}

bool? _optionalBool(Object? v) => v is bool ? v : null;

/// 全部可选能力（内置引擎代理与 qb 后端都实现全套；引擎未起时 host 按类型报这一组）。
const Set<String> kAllTorrentEngineFeatures = <String>{
  TorrentEngineFeature.removal,
  TorrentEngineFeature.pause,
  TorrentEngineFeature.detail,
  TorrentEngineFeature.metainfo,
  TorrentEngineFeature.pausedMetainfo,
  TorrentEngineFeature.trackers,
  TorrentEngineFeature.bulkPriority,
};

/// 按后端实现的可选接口列出能力（host 侧装配能力位用）。
Set<String> torrentEngineFeaturesOf(TorrentBackend backend) => <String>{
  if (backend is TorrentRemovalBackend) TorrentEngineFeature.removal,
  if (backend is TorrentPauseBackend) TorrentEngineFeature.pause,
  if (backend is TorrentDetailBackend) TorrentEngineFeature.detail,
  if (backend is TorrentMetainfoBackend) TorrentEngineFeature.metainfo,
  if (backend is TorrentPausedMetainfoBackend)
    TorrentEngineFeature.pausedMetainfo,
  if (backend is TorrentTrackerMutationBackend) TorrentEngineFeature.trackers,
  if (backend is TorrentBulkFilePriorityBackend)
    TorrentEngineFeature.bulkPriority,
};

int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;

double _double(Object? v, double fallback) =>
    v is num && v.isFinite ? v.toDouble() : fallback;

String _str(Object? v) => v == null ? '' : '$v';

bool? _boolOrNull(Object? v) => v is bool ? v : null;

Map<String, Object?> torrentSnapshotToWire(TorrentSnapshot s) =>
    <String, Object?>{
      'hash': s.hash,
      'name': s.name,
      'progress': s.progress,
      'state': s.state,
      'savePath': s.savePath,
      'contentPath': s.contentPath,
      'amountLeft': s.amountLeft,
      'totalSize': s.totalSizeBytes,
      'downRate': s.downRateBps,
      'upRate': s.upRateBps,
      'downloaded': s.downloadedBytes,
      'uploaded': s.uploadedBytes,
      'numPeers': s.numPeers,
      'numSeeds': s.numSeeds,
      'numLeechs': s.numLeechs,
      'swarmSeeds': s.swarmSeeds,
      'swarmLeechs': s.swarmLeechs,
      'numConnections': s.numConnections,
      'activeSeconds': s.activeDurationSeconds,
      'seedingSeconds': s.seedingDurationSeconds,
    };

TorrentSnapshot? torrentSnapshotFromWire(Object? raw) {
  if (raw is! Map) return null;
  final String hash = _str(raw['hash']).trim().toLowerCase();
  if (hash.isEmpty) return null;
  return TorrentSnapshot(
    hash: hash,
    name: _str(raw['name']),
    progress: _double(raw['progress'], 0),
    state: _str(raw['state']),
    savePath: _str(raw['savePath']),
    contentPath: _str(raw['contentPath']),
    amountLeft: _int(raw['amountLeft'], -1),
    totalSizeBytes: _int(raw['totalSize'], -1),
    downRateBps: _int(raw['downRate'], 0),
    upRateBps: _int(raw['upRate'], 0),
    downloadedBytes: _int(raw['downloaded'], 0),
    uploadedBytes: _int(raw['uploaded'], 0),
    numPeers: _int(raw['numPeers'], 0),
    numSeeds: _int(raw['numSeeds'], -1),
    numLeechs: _int(raw['numLeechs'], -1),
    swarmSeeds: _int(raw['swarmSeeds'], -1),
    swarmLeechs: _int(raw['swarmLeechs'], -1),
    numConnections: _int(raw['numConnections'], -1),
    activeDurationSeconds: _int(raw['activeSeconds'], -1),
    seedingDurationSeconds: _int(raw['seedingSeconds'], -1),
  );
}

Map<String, Object?> torrentFileEntryToWire(TorrentFileEntry f) =>
    <String, Object?>{
      'name': f.name,
      'size': f.size,
      'progress': f.progress,
      'index': f.index,
    };

TorrentFileEntry? torrentFileEntryFromWire(Object? raw) {
  if (raw is! Map) return null;
  return TorrentFileEntry(
    name: _str(raw['name']),
    size: _int(raw['size'], 0),
    progress: _double(raw['progress'], 0),
    index: _int(raw['index'], -1),
  );
}

Map<String, Object?> torrentStorageResultToWire(TorrentStorageResult r) =>
    <String, Object?>{
      'ok': r.ok,
      if (r.path != null) 'path': r.path,
      if (r.error != null) 'error': r.error,
    };

TorrentStorageResult torrentStorageResultFromWire(Object? raw) {
  if (raw is! Map) {
    return const TorrentStorageResult.failure('malformed host response');
  }
  if (raw['ok'] == true) {
    return TorrentStorageResult(ok: true, path: raw['path']?.toString());
  }
  final String error = _str(raw['error']);
  return TorrentStorageResult.failure(
    error.isEmpty ? 'the host rejected the request' : error,
  );
}

Map<String, Object?> torrentPeerDetailToWire(TorrentPeerDetail p) =>
    <String, Object?>{
      'address': p.address,
      'port': p.port,
      'client': p.client,
      'progress': p.progress,
      'downSpeed': p.downSpeedBps,
      'upSpeed': p.upSpeedBps,
      'downloaded': p.downloadedBytes,
      'uploaded': p.uploadedBytes,
      'flags': p.flags,
    };

TorrentPeerDetail? torrentPeerDetailFromWire(Object? raw) {
  if (raw is! Map) return null;
  return TorrentPeerDetail(
    address: _str(raw['address']),
    port: _int(raw['port'], 0),
    client: _str(raw['client']),
    progress: _double(raw['progress'], 0),
    downSpeedBps: _int(raw['downSpeed'], 0),
    upSpeedBps: _int(raw['upSpeed'], 0),
    downloadedBytes: _int(raw['downloaded'], 0),
    uploadedBytes: _int(raw['uploaded'], 0),
    flags: _str(raw['flags']),
  );
}

Map<String, Object?> torrentTrackerDetailToWire(TorrentTrackerDetail t) =>
    <String, Object?>{
      'url': t.url,
      'tier': t.tier,
      'status': t.status.name,
      'seeds': t.seeds,
      'leeches': t.leeches,
      'downloaded': t.downloaded,
      'message': t.message,
    };

TorrentTrackerDetail? torrentTrackerDetailFromWire(Object? raw) {
  if (raw is! Map) return null;
  return TorrentTrackerDetail(
    url: _str(raw['url']),
    tier: _int(raw['tier'], 0),
    status:
        TorrentTrackerStatus.values.asNameMap()[_str(raw['status'])] ??
        TorrentTrackerStatus.notContacted,
    seeds: _int(raw['seeds'], -1),
    leeches: _int(raw['leeches'], -1),
    downloaded: _int(raw['downloaded'], -1),
    message: _str(raw['message']),
  );
}

/// [TorrentFilePriority] 按名字上线（两端的 libtorrent / qb 数值映射各管各的）。
TorrentFilePriority? torrentFilePriorityFromWire(Object? raw) =>
    TorrentFilePriority.values.asNameMap()[_str(raw)];

Map<String, Object?> torrentSessionStatusToWire(TorrentSessionStatusInfo s) =>
    <String, Object?>{
      if (s.dhtEnabled != null) 'dhtEnabled': s.dhtEnabled,
      'dhtNodes': s.dhtNodes,
      if (s.lsdEnabled != null) 'lsdEnabled': s.lsdEnabled,
      if (s.pexEnabled != null) 'pexEnabled': s.pexEnabled,
      'listenPort': s.listenPort,
      'downRate': s.downRateBps,
      'upRate': s.upRateBps,
      'portMappings': <Map<String, Object?>>[
        for (final TorrentPortMappingInfo m in s.portMappings)
          <String, Object?>{
            'transport': m.transport,
            'protocol': m.protocol,
            'externalPort': m.externalPort,
            'ok': m.ok,
            'error': m.error,
          },
      ],
    };

TorrentSessionStatusInfo? torrentSessionStatusFromWire(Object? raw) {
  if (raw is! Map) return null;
  final Object? mappings = raw['portMappings'];
  return TorrentSessionStatusInfo(
    dhtEnabled: _boolOrNull(raw['dhtEnabled']),
    dhtNodes: _int(raw['dhtNodes'], -1),
    lsdEnabled: _boolOrNull(raw['lsdEnabled']),
    pexEnabled: _boolOrNull(raw['pexEnabled']),
    listenPort: _int(raw['listenPort'], 0),
    downRateBps: _int(raw['downRate'], -1),
    upRateBps: _int(raw['upRate'], -1),
    portMappings: mappings is List
        ? <TorrentPortMappingInfo>[
            for (final Object? m in mappings)
              if (m is Map)
                TorrentPortMappingInfo(
                  transport: _str(m['transport']),
                  protocol: _str(m['protocol']),
                  externalPort: _int(m['externalPort'], 0),
                  ok: m['ok'] == true,
                  error: _str(m['error']),
                ),
          ]
        : const <TorrentPortMappingInfo>[],
  );
}

/// [raw] 是对端 `{"key": [...]}` 里的列表；不是列表 → 空表。
List<T> decodeTorrentWireList<T>(Object? raw, T? Function(Object?) decode) =>
    raw is List
    ? <T>[
        for (final Object? item in raw)
          if (decode(item) case final T value) value,
      ]
    : <T>[];
