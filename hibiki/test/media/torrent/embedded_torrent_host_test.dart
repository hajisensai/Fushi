// 阶段2/3：EmbeddedTorrentHost 宿主接线验证——常驻 session 派发短命后端
// 视图（视图 close 不连累会话）、反吸血 sweep 遍历 peer 不抛、libtorrent 版本。
//
// 下载源 LocalSeedRig（127.0.0.1 本地做种，零外网）。缺 DLL 整组 skip。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/embedded_torrent_backend.dart';
import 'package:hibiki/src/media/torrent/embedded_torrent_host.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki_torrent/hibiki_torrent.dart';
import 'package:hibiki_torrent/testing.dart';
import 'package:path/path.dart' as p;

String? _resolveLibPath() {
  final String? env = Platform.environment['HIBIKI_TORRENT_LIB'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  return null;
}

void main() {
  final String? libPath = _resolveLibPath();
  final String? skip =
      libPath == null ? 'hibiki_torrent_ffi native lib not built' : null;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ht_host_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄未释放；留给系统清理。
    }
  });

  test(
    'host opens, hands out shared-session backend views, sweeps peers',
    () async {
      // 用非监听引擎给 rig 做种，另用 host 拿真实下载 session。
      final EmbeddedTorrentEngine rigEngine =
          EmbeddedTorrentEngine.open(libraryPath: libPath!);
      final LocalSeedRig rig = await LocalSeedRig.start(
          engine: rigEngine, workDir: tempDir, contentBytes: 1024 * 1024);
      addTearDown(rig.dispose);

      // host：监听回环（出站连接需要 listen socket），无 DHT（确定性）。
      final EmbeddedTorrentHost? host = EmbeddedTorrentHost.open(
        libraryPath: libPath,
        baseSavePath: p.join(tempDir.path, 'content'),
        listenInterfaces: '127.0.0.1:0',
        enableDht: false,
        clockMs: () => _fakeClock,
      );
      expect(host, isNotNull);
      addTearDown(host!.dispose);

      expect(host.libtorrentVersion, startsWith('2.'));

      // backendView 是 TorrentBackend；其 close 不能销毁常驻 session。
      final TorrentBackend view1 = host.backendView();
      expect(view1, isA<EmbeddedTorrentBackend>());
      expect(await view1.probeConnection(), startsWith('libtorrent 2.'));
      expect(await view1.prepareCategory('hibiki-anime'), isTrue);
      expect(
        await view1.addTorrent(rig.magnetUri,
            category: 'hibiki-anime', sequential: true),
        isTrue,
      );
      view1.close(); // 关视图……

      // ……第二个视图仍能操作同一 session（证明会话没被 view1.close 销毁）。
      final TorrentBackend view2 = host.backendView();
      final List<TorrentSnapshot> listed =
          await view2.listTorrents(category: 'hibiki-anime');
      expect(listed, hasLength(1));
      expect(listed.single.hash, rig.infoHash);

      // 反吸血 sweep：遍历种子（此处 1 个、无已连 peer）→ torrentPeers 空
      // → evaluate 空 → 无新封段。全程不抛，返回 0（无新封禁）。多跑几轮
      // 幂等（不会因重复 applyIpFilter 报错）。
      expect(host.sweepAntiLeech(), 0);
      expect(host.sweepAntiLeech(), 0);
      expect(host.sweepAntiLeech(), 0);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

// 反吸血引擎的判定基准时钟（注入固定值；本测试不依赖时间推进）。
const int _fakeClock = 1000000;
