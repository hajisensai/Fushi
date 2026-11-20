/// app 当互联 host 时把自己的 BT 引擎借给已配对设备（`/api/torrent-engine`），
/// 与无头 fushi_server 的 `ServerPeerTorrentEngine` 同一份路由与契约。
///
/// 借出去的是**本机当前的下载后端**（内置引擎或外接 qB）；本机自己的后端若也是
/// 「互联设备」则不转借（不做多跳链）。租约文件跟内置引擎的 resume 目录同在下载
/// 数据根下，由 AppModel 并进 resume 保留集合；下载中心没起（iOS / 浏览模块关闭）
/// 时租约位置都定不下来，[leases] 交 null，路由回 503。
library;

import 'package:fushi_engine/media/torrent/remote_torrent_wire.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/sync/torrent_engine/host_torrent_engine.dart';

class AppPeerTorrentEngine implements HostTorrentEngine {
  AppPeerTorrentEngine({
    required PeerTorrentLeaseStore? Function() leases,
    required Future<List<String>> Function() roots,
    required TorrentBackend? Function() backend,
    required ({String backend, bool? pause, bool? detail})? Function() traits,
  }) : _leases = leases,
       _roots = roots,
       _backend = backend,
       _traits = traits;

  final PeerTorrentLeaseStore? Function() _leases;
  final Future<List<String>> Function() _roots;

  /// 现建一个本机后端（用完由本类关闭）；没有可借的后端 → null。
  final TorrentBackend? Function() _backend;

  /// 本机后端的只读能力快照（不建 session）；没有可借的后端 → null。
  final ({String backend, bool? pause, bool? detail})? Function() _traits;

  @override
  Future<PeerTorrentLeaseStore?> leases() async => _leases();

  @override
  Future<HostTorrentPathPolicy> paths() async =>
      HostTorrentPathPolicy(await _roots());

  @override
  Future<R?> withBackend<R>(
    Future<R> Function(TorrentBackend backend) action,
  ) async {
    if (_leases() == null) return null;
    final TorrentBackend? backend = _backend();
    if (backend == null) return null;
    try {
      return await action(backend);
    } finally {
      backend.close();
    }
  }

  @override
  Future<TorrentEngineCapability> capability() async {
    final ({String backend, bool? pause, bool? detail})? traits = _traits();
    if (traits == null || _leases() == null) {
      return TorrentEngineCapability(
        supported: false,
        backend: traits?.backend ?? 'none',
      );
    }
    return TorrentEngineCapability(
      supported: true,
      backend: traits.backend,
      // 内置引擎代理与 qb 后端都实现全套可选能力。
      features: kAllTorrentEngineFeatures,
      pauseControlAvailable: traits.pause,
      detailAvailable: traits.detail,
      allowedRoots: (await paths()).roots,
    );
  }
}
