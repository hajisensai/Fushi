import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 无头 `bind` 按配置精确监听（BUG：bind 配成具体地址或 ::1 仍监听全部网卡）。
Future<bool> _hostHasIPv6Loopback() async {
  try {
    final ServerSocket probe = await ServerSocket.bind(
      InternetAddress.loopbackIPv6,
      0,
    );
    await probe.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<void> main() async {
  final bool hasIPv6Loopback = await _hostHasIPv6Loopback();
  late Directory tmp;
  late FushiDatabase db;
  HeadlessHost? host;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_host_bind_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await host?.stop();
    host = null;
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<HeadlessHost> start(String bind, {bool p2p = false}) async {
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(port: 0, bind: bind, tls: false, p2p: p2p);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    final HeadlessHost h = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: await ServerIdentity.loadOrCreate(prefs),
      p2pAvailable: () => true,
    );
    host = h;
    await h.start();
    return h;
  }

  test('bind: localhost → 127.0.0.1 可连（不被解析成只听 ::1）', () async {
    final HeadlessHost h = await start('localhost');
    final Socket s = await Socket.connect(
      InternetAddress.loopbackIPv4,
      h.port,
      timeout: const Duration(seconds: 2),
    );
    s.destroy();
  });

  test('bind: ::1 + p2p → reason 为 loopback_bind，且不听 v4', () async {
    final HeadlessHost h = await start('::1', p2p: true);
    expect(h.p2pStatus()['reason'], 'loopback_bind');
    await expectLater(
      Socket.connect(
        InternetAddress.loopbackIPv4,
        h.port,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<SocketException>()),
    );
  }, skip: hasIPv6Loopback ? false : '本机没有 IPv6 回环，无从验证 ::1 监听');
}
