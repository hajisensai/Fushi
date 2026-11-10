import 'dart:convert';
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

/// BUG-4279：无头端经本机回环进来的配对请求（本机反代 / frp / cloudflared 的典型形态）
/// 不算局域网。升级场景：存量配置 `lan_requires_pin: false` + 已写 `public_urls`，
/// 不加任何新键，起来后从 127.0.0.1 发 `pair/v2` 必须要 PIN。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late HttpClient client;

  setUp(() async {
    client = HttpClient();
    tmp = await Directory.systemTemp.createTemp('fushi_host_loopback_origin_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final ServerConfig config =
        ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
          port: 0,
          bind: '127.0.0.1',
          tls: false,
          lanRequiresPin: false,
          publicUrls: <String>['https://nas.example.com'],
        );
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: await ServerIdentity.loadOrCreate(prefs),
      p2pAvailable: () => false,
    );
    await host.start();
  });

  tearDown(() async {
    client.close(force: true);
    await host.stop();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> pairV2({Map<String, String>? headers}) async {
    final HttpClientRequest req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${host.port}/api/pair/v2'),
    );
    req.headers.contentType = ContentType.json;
    headers?.forEach(req.headers.set);
    req.write(
      jsonEncode(<String, String>{'name': 'Phone', 'clientNonce': 'cn-lo'}),
    );
    final HttpClientResponse resp = await req.close();
    final String text = await resp.transform(utf8.decoder).join();
    expect(resp.statusCode, 200, reason: text);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  test('回环对端：lan_requires_pin=false 也要 PIN', () async {
    expect((await pairV2())['pinRequired'], isTrue);
  });

  test('回环对端带转发头：要 PIN', () async {
    expect(
      (await pairV2(
        headers: <String, String>{'x-forwarded-for': '203.0.113.9'},
      ))['pinRequired'],
      isTrue,
    );
  });
}
