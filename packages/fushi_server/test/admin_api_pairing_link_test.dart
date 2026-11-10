import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
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

/// BUG-4280（步骤 6）：无头端公网类别被 PIN 爆破锁住时，管理员在 WebUI / admin API
/// 签发一次性配对链接，票据配对不走 PIN 预算，只能从公网接入的用户仍能配上。
///
/// 部署形态照 VPS：`bind: 127.0.0.1` 只听本机，前面是本机反代（可信代理，带
/// `X-Forwarded-For`），对外地址写在 `public_urls`。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late AdminApi api;
  late HttpClient client;
  late ServerConfig config;
  late File configFile;
  late ServerPaths paths;
  late ServerIdentity identity;

  const String publicUrl = 'https://fushi.example.com';

  AdminApi buildApi() => AdminApi(
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

  Future<void> boot({required List<String> publicUrls}) async {
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    config = ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
      adminToken: 'tok',
      port: 0,
      bind: '127.0.0.1',
      tls: false,
      trustedProxies: <String>['127.0.0.1'],
      publicUrls: publicUrls,
    );
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    identity = await ServerIdentity.loadOrCreate(prefs);
    paths = ServerPaths(config.dataDir);
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
    api = buildApi();
  }

  setUp(() async {
    client = HttpClient();
    tmp = await Directory.systemTemp.createTemp('fushi_admin_pair_link_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    client.close(force: true);
    await host.stop();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> post(
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
    return (
      resp.statusCode,
      decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    );
  }

  /// 从 [ip] 用错 PIN 猜一次；返回 confirm（或被拒的建会话）的状态码。
  Future<int> wrongGuess(String ip) async {
    final String cn = 'cn-$ip';
    final (int code, Map<String, dynamic> start) = await post(
      '/api/pair/v2',
      ip,
      <String, String>{'name': 'Phone', 'clientNonce': cn},
    );
    if (code != 200) return code;
    final (
      int confirmCode,
      _,
    ) = await post('/api/pair/v2/confirm', ip, <String, String>{
      'sessionId': start['sessionId'] as String,
      'pinProof': FushiPairingProtocol.computePinProof(
        pin: 'wrong',
        clientNonce: cn,
        hostNonce: start['hostNonce'] as String,
      ),
    });
    return confirmCode;
  }

  Future<shelf.Response> createLink() => api.handle(
    shelf.Request('POST', Uri.parse('http://localhost/api/admin/pairing/link')),
  );

  test('公网类别锁定时，管理员签发的配对链接仍能从公网来源配上', () async {
    await boot(publicUrls: <String>[publicUrl]);

    for (int i = 1; i <= 10; i++) {
      await wrongGuess('203.0.113.$i');
    }
    expect(
      await wrongGuess('203.0.113.50'),
      429,
      reason: '前置：公网类别已被锁定，PIN 配对走不通',
    );

    final shelf.Response r = await createLink();
    expect(r.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    final int ttl = json['expiresInSeconds'] as int;
    expect(ttl, inInclusiveRange(290, 300));

    final FushiPairLink? link = FushiPairLink.tryParse(json['uri'] as String);
    expect(link, isNotNull, reason: 'app 的「粘贴配对链接」要能解析');
    expect(link!.hostId, identity.deviceId);
    expect(link.hasTicket, isTrue);
    expect(
      link.addresses.map((InterconnectHostAddress a) => a.url),
      contains(publicUrl),
      reason: '只听本机的反代部署也要把 public_urls 带进链接',
    );

    // 用票据从公网来源配对：不受公网类别锁定影响。
    const String ip = '198.51.100.9';
    const String cn = 'cn-ticket';
    final (int startCode, Map<String, dynamic> start) = await post(
      '/api/pair/v2',
      ip,
      <String, String>{
        'name': 'Laptop',
        'clientNonce': cn,
        'ticket': link.ticketId!,
      },
    );
    expect(startCode, 200);
    final (
      int confirmCode,
      Map<String, dynamic> confirmed,
    ) = await post('/api/pair/v2/confirm', ip, <String, String>{
      'sessionId': start['sessionId'] as String,
      'pinProof': FushiPairingProtocol.computePinProof(
        pin: link.ticketSecret!,
        clientNonce: cn,
        hostNonce: start['hostNonce'] as String,
      ),
    });
    expect(confirmCode, 200);
    expect(confirmed['token'], isA<String>());
    expect(
      host.pairingLockouts.keys,
      contains(FushiPairOriginClass.public),
      reason: '票据配对不动 PIN 预算，锁定照旧',
    );
  });

  test('再签一张作废上一张', () async {
    await boot(publicUrls: <String>[publicUrl]);
    final Map<String, dynamic> first =
        jsonDecode(await (await createLink()).readAsString())
            as Map<String, dynamic>;
    await createLink();
    final FushiPairLink old = FushiPairLink.tryParse(first['uri'] as String)!;
    final (int code, Map<String, dynamic> body) = await post(
      '/api/pair/v2',
      '198.51.100.10',
      <String, String>{
        'name': 'Laptop',
        'clientNonce': 'cn-old',
        'ticket': old.ticketId!,
      },
    );
    expect(code, isNot(200));
    expect(body['reason'], 'expired');
  });

  test('没有任何可公布地址时回 409 no_reachable_address，不发废链接', () async {
    await boot(publicUrls: const <String>[]);
    final shelf.Response r = await createLink();
    expect(r.statusCode, 409);
    final Map<String, dynamic> json =
        jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    expect(json['reason'], 'no_reachable_address');
  });

  test('host 没在跑时回 409 not_running', () async {
    await boot(publicUrls: <String>[publicUrl]);
    await host.stop();
    final shelf.Response r = await createLink();
    expect(r.statusCode, 409);
    final Map<String, dynamic> json =
        jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    expect(json['reason'], 'not_running');
  });
}
