// HBK-AUDIT-020：活跃名额热更新回 0（= libtorrent 默认）必须在同一 session 上
// 真生效。
//
// 事故本体：ht_apply_session_settings 旧实现只在入参 > 0 时写 active_downloads
// / active_seeds，0 与负数都「不写」。无头服务端 / app 把名额从「不限」或自定义
// 正数改回 0 时，保存显示成功，旧名额却一直用到重启。本测试在同一 session 上
// 依次下发 不限 → 0 → 自定义 → 0，每步都读 native 现值核对。
//
// 全本地确定性（不联网）；缺 DLL 整组 skip。

import 'dart:io';

import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:test/test.dart';

String? _resolveLibPath() {
  final String? env = Platform.environment['FUSHI_TORRENT_LIB'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  return null;
}

/// libtorrent 2.0 的出厂默认（与 `lt::default_settings()` 一致）。
const int _libtorrentDefaultActiveDownloads = 3;
const int _libtorrentDefaultActiveSeeds = 5;

void main() {
  final String? explicit = _resolveLibPath();

  EmbeddedTorrentEngine? tryOpen() {
    try {
      return EmbeddedTorrentEngine.open(libraryPath: explicit);
    } on ArgumentError {
      return null;
    }
  }

  final EmbeddedTorrentEngine? engine = tryOpen();
  final String? skip = engine == null
      ? 'fushi_torrent_ffi native lib not built'
      : null;

  ({int? downloads, int? seeds}) applyAndRead(
    EmbeddedTorrentSession session, {
    required int downloads,
    required int seeds,
  }) {
    expect(
      session.applySessionSettings(
        enableDht: false,
        enableLsd: false,
        enableUpnp: false,
        enableNatpmp: false,
        activeDownloads: downloads,
        activeSeeds: seeds,
      ),
      isTrue,
    );
    final FtSessionStatus? status = session.sessionStatus();
    expect(status, isNotNull);
    expect(
      status!.activeDownloads,
      isNotNull,
      reason: '本仓构建的库必须在 ht_session_status 里报 active_downloads',
    );
    return (downloads: status.activeDownloads, seeds: status.activeSeeds);
  }

  test('同一 session：不限 / 自定义 → 0 热切回 libtorrent 默认', () {
    final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
      engine!,
    );
    expect(session, isNotNull);
    addTearDown(session!.close);

    // 初始即默认。
    expect(applyAndRead(session, downloads: 0, seeds: 0), (
      downloads: _libtorrentDefaultActiveDownloads,
      seeds: _libtorrentDefaultActiveSeeds,
    ));

    // 「不限」：Dart 侧下发 int32 最大值（libtorrentActiveLimitArg）。
    expect(applyAndRead(session, downloads: 0x7fffffff, seeds: 0x7fffffff), (
      downloads: 0x7fffffff,
      seeds: 0x7fffffff,
    ));
    // 不限 → 0：必须真恢复默认，而不是继续沿用不限。
    expect(applyAndRead(session, downloads: 0, seeds: 0), (
      downloads: _libtorrentDefaultActiveDownloads,
      seeds: _libtorrentDefaultActiveSeeds,
    ));

    // 自定义正数 → 0。
    expect(applyAndRead(session, downloads: 10, seeds: 12), (
      downloads: 10,
      seeds: 12,
    ));
    expect(applyAndRead(session, downloads: 0, seeds: 0), (
      downloads: _libtorrentDefaultActiveDownloads,
      seeds: _libtorrentDefaultActiveSeeds,
    ));

    // 负数直传 = 不限（libtorrent 的 -1）。
    expect(applyAndRead(session, downloads: -1, seeds: -1), (
      downloads: -1,
      seeds: -1,
    ));
    expect(applyAndRead(session, downloads: 0, seeds: 0), (
      downloads: _libtorrentDefaultActiveDownloads,
      seeds: _libtorrentDefaultActiveSeeds,
    ));
  }, skip: skip);
}
