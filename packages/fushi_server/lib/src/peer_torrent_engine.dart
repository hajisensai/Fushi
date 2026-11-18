/// 无头服务端把自己的 BT 引擎借给已配对设备（`/api/torrent-engine`）。
///
/// 典型用法：本机网络对 BT 不友好（走代理 / 被丢包），在一台直连的 VM 上跑
/// fushi_server，桌面 app 把「下载后端」选成这台 VM——BT 在 VM 上跑，任务、整理、
/// 入库仍在桌面 app 上。VM 把桌面媒体库的共享目录挂进来并写进
/// `torrent.peer_roots`，桌面端配一条路径映射，下载就直接落进桌面的库。
library;

import 'package:fushi_engine/media/torrent/remote_torrent_wire.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/sync/torrent_engine/host_torrent_engine.dart';
import 'package:fushi_server/src/download_host.dart';

class ServerPeerTorrentEngine implements HostTorrentEngine {
  ServerPeerTorrentEngine(this._downloads);

  final ServerDownloadHost _downloads;

  @override
  PeerTorrentLeaseStore get leases => _downloads.peerTorrentLeases;

  @override
  HostTorrentPathPolicy get paths => _downloads.peerTorrentPathPolicy();

  @override
  Future<R?> withBackend<R>(
    Future<R> Function(TorrentBackend backend) action,
  ) => _downloads.withPeerBackend<R>(action);

  @override
  Future<TorrentEngineCapability> capability() async {
    final String? backend = _downloads.resolvedBackend;
    if (backend == null) {
      return const TorrentEngineCapability(supported: false, backend: 'none');
    }
    // 能力位按真实后端类型报（建视图不建 session：内置引擎的视图懒开，这里只看类型；
    // 运行时能力位读宿主探测结果，DLL 过旧时如实报 false）。
    final ({Set<String> features, bool pause, bool detail})? probed =
        await _downloads.withPeerBackend(
          (TorrentBackend b) async => (
            features: torrentEngineFeaturesOf(b),
            pause: b is TorrentPauseBackend && b.pauseControlAvailable,
            detail: b is TorrentDetailBackend && b.detailAvailable,
          ),
        );
    return TorrentEngineCapability(
      supported: probed != null,
      backend: backend,
      features: probed?.features ?? const <String>{},
      pauseControlAvailable: probed?.pause ?? false,
      detailAvailable: probed?.detail ?? false,
      allowedRoots: paths.roots,
    );
  }
}
