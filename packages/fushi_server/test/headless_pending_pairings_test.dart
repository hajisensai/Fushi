import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// 无头端待输入 PIN 按会话持有：两台设备先后发起要 PIN 的配对，第一台的 PIN 不被
/// 第二台覆盖；某个会话 confirm 后只收起它自己那条（修复前是全局单槽，后来者覆盖、
/// 任一会话 confirm 都清空）。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late AdminApi api;
  late HttpClient client;

  setUp(() async {
    client = HttpClient();
    tmp = await Directory.systemTemp.createTemp('fushi_pending_pairings_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final ServerConfig config =
        ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
          adminToken: 'tok',
          port: 0,
          bind: '127.0.0.1',
          tls: false,
          trustedProxies: <String>['127.0.0.1'],
        );
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    await host.start();
    api = AdminApi(
      AdminContext(
        config: config,
        configFile: configFile,
        paths: paths,
        log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
        db: db,
        identity: identity,
        host: host,
        startedAt: DateTime.now(),
      ),
    );
  });

  tearDown(() async {
    client.close(force: true);
    await host.stop();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> post(
    String path,
    String forwardedFor,
    Map<String, String> body,
  ) async {
    final HttpClientRequest req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${host.port}$path'),
    );
    req.headers.contentType = ContentType.json;
    req.headers.set('x-forwarded-for', forwardedFor);
    req.write(jsonEncode(body));
    final HttpClientResponse resp = await req.close();
    final String text = await resp.transform(utf8.decoder).join();
    final Object? decoded = text.isEmpty ? null : jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Future<String> startPinSession(String ip, String name) async {
    final Map<String, dynamic> start = await post(
      '/api/pair/v2',
      ip,
      <String, String>{'name': name, 'clientNonce': 'cn-$ip'},
    );
    expect(start['pinRequired'], isTrue);
    return start['sessionId'] as String;
  }

  test('两次要 PIN 的配对各留一条；confirm 第一条后只剩第二条', () async {
    final String s1 = await startPinSession('203.0.113.1', 'Phone A');
    final String firstPin = host.pendingPairings.single.pin;
    await startPinSession('203.0.113.2', 'Phone B');

    final List<PendingPairing> both = host.pendingPairings;
    expect(both.length, 2, reason: '第二台设备的 PIN 不得覆盖第一台');
    expect(both.first.pin, firstPin);
    expect(both.first.deviceName, 'Phone A');
    expect(both.last.deviceName, 'Phone B');
    expect(host.pendingPairing?.deviceName, 'Phone B', reason: '兼容字段给最新一条');

    final shelf.Response r = await api.handle(
      shelf.Request('GET', Uri.parse('http://localhost/api/admin/pairing')),
    );
    expect(r.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    final List<dynamic> list = json['pendingList'] as List<dynamic>;
    expect(list.length, 2);
    expect((list.first as Map<String, dynamic>)['pin'], firstPin);
    expect(
      (list.first as Map<String, dynamic>).containsKey('sessionId'),
      isFalse,
      reason: '会话 id 不下发给 WebUI',
    );

    // 第一台提交 confirm（PIN 错也算 PIN 已被读走、会话消费）→ 只收起它那条。
    await post('/api/pair/v2/confirm', '203.0.113.1', <String, String>{
      'sessionId': s1,
      'pinProof': 'not-a-proof',
    });
    final List<PendingPairing> left = host.pendingPairings;
    expect(left.length, 1);
    expect(left.single.deviceName, 'Phone B');
  });
}
