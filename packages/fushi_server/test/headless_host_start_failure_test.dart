import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// BUG-2959：互联端口被占时 `start()` 抛 [SyncServerPortInUseException]，但在它之前
/// 已经起来的下载管线（含订阅检查）没人收回；CLI 随即关库，在途的订阅事务撞上已关
/// 的连接，以一条无关的 `Bad state: No element` 崩掉进程，把「端口被占用」吞掉。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerSocket squatter;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_host_start_fail_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await squatter.close();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('BUG-2959 端口被占：抛出端口异常，并收回已起的下载管线', () async {
    // qBittorrent 配了地址即起管线（起管线不连它），这样订阅检查一定在跑。
    final ServerConfig config =
        ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
          port: squatter.port,
          bind: '127.0.0.1',
          tls: false,
          torrentEngine: ServerConfig.torrentEngineQbittorrent,
          qbittorrentUrl: 'http://127.0.0.1:9',
        );
    final ServerPrefs prefs = ServerPrefs(db);
    final HeadlessHost host = HeadlessHost(
      config: config,
      paths: ServerPaths(config.dataDir),
      db: db,
      prefs: prefs,
      identity: await ServerIdentity.loadOrCreate(prefs),
    );

    await expectLater(
      host.start(),
      throwsA(isA<SyncServerPortInUseException>()),
    );
    expect(host.isRunning, isFalse);
    // 管线与订阅检查都已停下（停机会等在途的一轮落地），调用方此后关库是安全的。
    expect(host.downloads, isNull);
    expect(host.subscriptions, isNull);
    expect(host.videoScrape, isNull);
  });
}
