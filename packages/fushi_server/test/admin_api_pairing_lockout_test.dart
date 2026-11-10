import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
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

/// BUG-4280：无头端没有人工审批，「开会话 → 猜一次」换来源也挡得住——公网类别累计
/// PIN 失败到阈值即暂停；admin API 报出暂停到何时，管理员可一键解除。
///
/// 来源经本机可信代理（`trusted_proxies: [127.0.0.1]`）带 `X-Forwarded-For` 进来，
/// 每次一个不同的公网 IP：按来源的限速器各自只记一次，只有类别预算会锁。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late AdminApi api;
  late HttpClient client;

  setUp(() async {
    client = HttpClient();
    tmp = await Directory.systemTemp.createTemp('fushi_admin_pair_lockout_');
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

  /// 从 [ip] 开一个会话并用错 PIN confirm；返回 confirm 的状态码（建会话被拒时返回
  /// 建会话的状态码）。错 PIN 用非数字串，绝不会撞中随机 PIN。
  Future<int> wrongGuess(String ip) async {
    final String cn = 'cn-$ip';
    final (int code, Map<String, dynamic> start) = await post(
      '/api/pair/v2',
      ip,
      <String, String>{'name': 'Phone', 'clientNonce': cn},
    );
    if (code != 200) return code;
    expect(start['pinRequired'], isTrue);
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

  Future<Map<String, dynamic>> lockout() async {
    final shelf.Response r = await api.handle(
      shelf.Request('GET', Uri.parse('http://localhost/api/admin/pairing')),
    );
    expect(r.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    return Map<String, dynamic>.from(json['lockout'] as Map);
  }

  test('公网类别锁定后 GET pairing 报出 lockout.public，unlock 后清空', () async {
    expect(await lockout(), <String, dynamic>{
      'lan': null,
      'p2p': null,
      'public': null,
    });

    final List<int> codes = <int>[
      for (int i = 1; i <= 10; i++) await wrongGuess('203.0.113.$i'),
    ];
    expect(codes.take(9), everyElement(401));
    expect(codes.last, 429, reason: '第 10 次失败锁住公网类别');
    expect(await wrongGuess('203.0.113.11'), 429, reason: '换来源也被拒');

    final Map<String, dynamic> locked = await lockout();
    expect(locked['public'], isA<String>());
    expect(
      DateTime.parse(locked['public'] as String).isAfter(DateTime.now()),
      isTrue,
    );
    expect(locked['lan'], isNull);
    expect(locked['p2p'], isNull);
    expect(host.pairingLockouts.keys, <FushiPairOriginClass>[
      FushiPairOriginClass.public,
    ]);

    final shelf.Response unlock = await api.handle(
      shelf.Request(
        'POST',
        Uri.parse('http://localhost/api/admin/pairing/unlock'),
      ),
    );
    expect(unlock.statusCode, 204);
    expect((await lockout())['public'], isNull);
    expect(await wrongGuess('203.0.113.12'), 401, reason: '解除后又能尝试');
  });
}
