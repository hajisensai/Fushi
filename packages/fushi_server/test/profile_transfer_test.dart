import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/profile/profile_document.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_profile_transfer.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
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

/// 无头服务端的互联「配置文件」（Profile）搬运：对端 PUT 寄存、GET 拉走。
///
/// 端点跑在真 TLS 的 [FushiSyncServer] 上，库服务用服务端自己的装配
/// （[HeadlessHost.buildLibraryService]），开关走 admin API——与生产同一条链。
void main() {
  const String peerToken = 'peer-token-1';

  late Directory tmp;
  late FushiDatabase db;
  late File configFile;
  late HeadlessHost host;
  late AdminApi admin;
  FushiSyncServer? server;
  late HttpClient client;

  Future<void> startServer({required bool tls}) async {
    SecurityContext? ctx;
    if (tls) {
      final ({String certificatePem, String privateKeyPem}) id =
          FushiSelfSignedCertGenerator.generate(
            commonName: 'fushi-test',
            sanIpAddresses: <String>['127.0.0.1'],
          );
      ctx = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(id.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(id.privateKeyPem));
    }
    final FushiSyncServer started = FushiSyncServer(
      syncDataDir: p.join(tmp.path, 'sync'),
      port: 0,
      token: 'host-token',
      allowLan: false,
      libraryService: host.buildLibraryService(),
      securityContext: ctx,
    )..pairedPeerTokensProvider = (() async => <String>{peerToken});
    await started.start();
    server = started;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_profile_xfer_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok');
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    admin = AdminApi(
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
    client = HttpClient()
      ..badCertificateCallback = (X509Certificate _, String _, int _) => true;
  });

  tearDown(() async {
    client.close(force: true);
    await server?.stop();
    server = null;
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<({int status, Map<String, dynamic> json})> adminCall(
    String method,
    String path, [
    Object? body,
  ]) async {
    final shelf.Response r = await admin.handle(
      shelf.Request(
        method,
        Uri.parse('http://localhost/api/admin/$path'),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return (
      status: r.statusCode,
      json: Map<String, dynamic>.from(
        jsonDecode(await r.readAsString()) as Map,
      ),
    );
  }

  Future<void> setEnabled(bool on) async {
    final ({int status, Map<String, dynamic> json}) r = await adminCall(
      'PUT',
      'settings',
      <String, Object?>{'profileTransfer': on},
    );
    expect(r.status, 200);
    expect(r.json['profileTransfer'], on);
  }

  Future<({int status, String body})> wire(
    String method, {
    String? body,
    String token = peerToken,
    String scheme = 'https',
  }) async {
    final HttpClientRequest req = await client.openUrl(
      method,
      Uri.parse('$scheme://127.0.0.1:${server!.port}$kInterconnectProfilePath'),
    );
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    );
    if (body != null) req.add(utf8.encode(body));
    final HttpClientResponse res = await req.close();
    return (status: res.statusCode, body: await utf8.decodeStream(res));
  }

  String profileJson(String name, Map<String, String> prefs) =>
      encodeProfileDocument(
        profileName: name,
        schemaVersion: 114,
        settings: <ProfileSettingEntry>[
          for (final MapEntry<String, String> e in prefs.entries)
            ProfileSettingEntry(category: 'pref', key: e.key, value: e.value),
        ],
      );

  Map<String, String> prefsOf(String json) => <String, String>{
    for (final ProfileSettingEntry e in parseProfileDocument(json).settings)
      e.key: e.value,
  };

  test('配置默认关：admin 报 false，端点 403（能力位照报 true，好让 client 区分「关着」）', () async {
    final ({int status, Map<String, dynamic> json}) s = await adminCall(
      'GET',
      'settings',
    );
    expect(s.json['profileTransfer'], isFalse);
    await startServer(tls: true);

    final ({int status, String body}) get = await wire('GET');
    expect(get.status, 403);
    expect(get.body, contains('disabled'));
    final ({int status, String body}) put = await wire(
      'PUT',
      body: profileJson('A', <String, String>{'k': '1'}),
    );
    expect(put.status, 403);
    expect(
      Directory(
        p.join(tmp.path, 'data', 'support', 'interconnect_profiles'),
      ).existsSync(),
      isFalse,
      reason: '关着时一个字节都不许落盘',
    );

    final HttpClientRequest capReq = await client.getUrl(
      Uri.parse('https://127.0.0.1:${server!.port}/api/capabilities'),
    );
    capReq.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('hibiki:$peerToken'))}',
    );
    final Map<String, dynamic> caps =
        jsonDecode(await utf8.decodeStream(await capReq.close()))
            as Map<String, dynamic>;
    expect((caps['liveLibrary'] as Map)['profileTransfer'], isTrue);
  });

  test('推 → 拉往返；重名加后缀；拉的是最近收到的；不碰 profiles 表', () async {
    await startServer(tls: true);
    await setEnabled(true);

    final ({int status, String body}) empty = await wire('GET');
    expect(empty.status, 409, reason: '还没人推过：懂端点、开着，只是没东西——不是 404 也不是 500');

    final ({int status, String body}) put1 = await wire(
      'PUT',
      body: profileJson('Phone', <String, String>{
        'reader_font_size': '22',
        kObsoleteGalgameUpscalingModePrefKey: 'x',
      }),
    );
    expect(put1.status, 200);
    expect(jsonDecode(put1.body)['name'], 'Phone');

    final ({int status, String body}) get1 = await wire('GET');
    expect(get1.status, 200);
    expect(prefsOf(get1.body), <String, String>{
      'reader_font_size': '22',
    }, reason: '入站准入判据与 app 同一份：v63 废弃键不寄存');
    expect(parseProfileDocument(get1.body).profileName, 'Phone');

    final ({int status, String body}) put2 = await wire(
      'PUT',
      body: profileJson('Phone', <String, String>{'reader_font_size': '30'}),
    );
    expect(jsonDecode(put2.body)['name'], 'Phone (2)');
    final ({int status, String body}) get2 = await wire('GET');
    expect(parseProfileDocument(get2.body).profileName, 'Phone (2)');
    expect(prefsOf(get2.body)['reader_font_size'], '30');

    expect(
      await db.getAllProfiles(),
      isEmpty,
      reason: '寄存物不能进 profiles 表：会让服务端统计分区键从 0 漂到寄存的 Profile',
    );
  });

  test('WebUI 指定分发 / 删除：GET 跟着走，删掉指定的回到最近收到', () async {
    await startServer(tls: true);
    await setEnabled(true);
    await wire('PUT', body: profileJson('Old', <String, String>{'a': '1'}));
    await wire('PUT', body: profileJson('New', <String, String>{'a': '2'}));

    final ({int status, Map<String, dynamic> json}) listed = await adminCall(
      'GET',
      'profiles',
    );
    expect(listed.json['enabled'], isTrue);
    expect(listed.json['reachable'], isTrue);
    final List<Map<String, dynamic>> rows = (listed.json['profiles'] as List)
        .map((Object? e) => Map<String, dynamic>.from(e! as Map))
        .toList();
    expect(rows.map((Map<String, dynamic> r) => r['name']), <String>[
      'New',
      'Old',
    ]);
    expect(rows.first['shared'], isTrue);
    final int oldId = rows.last['id'] as int;

    expect((await adminCall('POST', 'profiles/$oldId/share')).status, 200);
    expect(parseProfileDocument((await wire('GET')).body).profileName, 'Old');

    expect((await adminCall('DELETE', 'profiles/$oldId')).status, 200);
    expect(parseProfileDocument((await wire('GET')).body).profileName, 'New');
    expect((await adminCall('DELETE', 'profiles/$oldId')).status, 404);
    expect((await adminCall('POST', 'profiles/nope/share')).status, 400);
  });

  test('坏载荷 400 且零落盘；未配对 token 401；明文 host 403', () async {
    await startServer(tls: true);
    await setEnabled(true);
    final ({int status, String body}) bad = await wire(
      'PUT',
      body: '{"type":"something-else"}',
    );
    expect(bad.status, 400);
    final ({int status, String body}) stranger = await wire(
      'GET',
      token: 'nope',
    );
    expect(stranger.status, 401, reason: '未配对 token 在全局鉴权就被挡下');
    expect((await adminCall('GET', 'profiles')).json['profiles'], isEmpty);

    await server!.stop();
    await startServer(tls: false);
    final ({int status, String body}) plain = await wire('GET', scheme: 'http');
    expect(plain.status, 403);
    expect(plain.body, contains('HTTPS required'));
  });

  test('配置往返：profile_transfer 写回 yaml，缺省为 false', () async {
    final ServerConfig defaults = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'd'),
    );
    expect(defaults.profileTransfer, isFalse);
    await setEnabled(true);
    final ServerConfig reread = await ServerConfig.load(configFile);
    expect(reread.profileTransfer, isTrue);
  });
}
