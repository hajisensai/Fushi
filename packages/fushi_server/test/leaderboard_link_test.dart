/// 无头服务端当「跟随已配对设备自动登录 Fushi 账户」的 host：真 TLS 的 [HeadlessHost]
/// （生产同一条 `start()` 装配）+ 回环上的假排行榜服务（逐请求验签），管理员经 admin API
/// 标记「我的设备」、开关总闸——与生产同一条链。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/leaderboard/leaderboard_device_link.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_signing.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_leaderboard_link.dart';
import 'package:fushi_engine/sync/interconnect_owner_devices.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/leaderboard_store.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// 假排行榜 Worker：只认 host 账户的设备钥匙；`POST /v1/me/devices` 验签后回新设备视角的账户。
class _FakeLeaderboard {
  _FakeLeaderboard._(this._server, this.hostIdentity);

  static Future<_FakeLeaderboard> start(LeaderboardIdentity host) async {
    final _FakeLeaderboard f = _FakeLeaderboard._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      host,
    );
    f._server.listen(f._handle);
    return f;
  }

  final HttpServer _server;
  final LeaderboardIdentity hostIdentity;

  /// 收到的代绑请求体（已验签通过的）。
  final List<Map<String, Object?>> linked = <Map<String, Object?>>[];

  /// 非 null 时代绑一律回这个状态码 + 错误码。
  (int, String)? forceError;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final Uint8List body = Uint8List.fromList(
      await req.fold<List<int>>(
        <int>[],
        (List<int> a, List<int> b) => a..addAll(b),
      ),
    );
    Future<void> reply(int status, Object? json) async {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(json));
      await req.response.close();
    }

    if ('${req.method} ${req.uri.path}' != 'POST /v1/me/devices') {
      return reply(404, <String, Object?>{'error': 'not_found'});
    }
    // 必须是 host 自己的设备钥匙签的（对端的公钥只在 body 里）。
    final String? sig = req.headers.value('x-fushi-sig');
    final String? time = req.headers.value('x-fushi-time');
    if (req.headers.value('x-fushi-account') != hostIdentity.accountId ||
        sig == null ||
        !LeaderboardIdentity.verify(
          leaderboardBase64UrlDecode(hostIdentity.pubkeyBase64Url),
          leaderboardSigningString(
            req.method,
            req.uri.path,
            int.parse(time ?? '0'),
            body,
          ),
          sig,
        )) {
      return reply(401, <String, Object?>{'error': 'bad_signature'});
    }
    final (int, String)? err = forceError;
    if (err != null) return reply(err.$1, <String, Object?>{'error': err.$2});
    linked.add(
      (jsonDecode(utf8.decode(body)) as Map<Object?, Object?>)
          .cast<String, Object?>(),
    );
    return reply(200, <String, Object?>{
      'id': 'acct0000000000AA',
      'nickname': '猫',
      'discriminator': 42,
      'visibility': 'public',
      'createdAt': 1,
      'emailVerified': true,
      'uploadDevice': false,
    });
  }
}

void main() {
  const String peerId = 'phone-1';
  const String peerToken = 'peer-token-phone';

  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late AdminApi admin;
  late HttpClient client;
  late ServerPaths paths;
  late LeaderboardIdentity hostAccount;
  late _FakeLeaderboard leaderboard;

  /// 本机没有账户的新设备（对端），自己生成设备钥匙。
  late LeaderboardIdentity newDevice;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_lb_link_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(port: 0, bind: '127.0.0.1', tls: true, adminToken: 'tok');
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
      dictionaryHost: ServerDictionaryHost(
        db: db,
        dictionaryResourceRoot: paths.dictionaryResources,
        libraryPath: p.join(tmp.path, 'missing', 'libfushidicts_ffi.so'),
      ),
    );
    await host.start();
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
    hostAccount = LeaderboardIdentity.generate();
    newDevice = LeaderboardIdentity.generate();
    leaderboard = await _FakeLeaderboard.start(hostAccount);
  });

  tearDown(() async {
    client.close(force: true);
    await leaderboard.close();
    await host.stop();
    await db.close();
    await tmp.delete(recursive: true);
  });

  /// 当前激活 Profile 的本机排行榜账户（与 `leaderboard login / import` 落同一个文件）。
  Future<void> writeHostAccount() async {
    await ServerLeaderboardStore(
      supportRoot: paths.support,
      profileId: await db.resolveActiveProfileId(),
    ).write(
      ServerLeaderboardAccount(
        recoveryCode: hostAccount.toRecoveryCode(),
        accountId: 'acct0000000000AA',
        serverUrl: leaderboard.url,
      ),
    );
  }

  /// 经生产的落库回调登记一台已配对设备（真实路径上由 `/api/pair/v2/confirm` 触发）。
  Future<void> pair({String? fingerprint = 'fp-phone', bool owner = false}) =>
      host.syncServer!.onPeerPaired!(
        FushiPairedPeerRegistration(
          peerId: peerId,
          token: peerToken,
          deviceName: 'Phone',
          remoteAddress: '127.0.0.1',
          ownerDevice: owner,
          deviceKeyFingerprint: fingerprint,
        ),
      );

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

  Future<({int status, Map<String, dynamic> json})> markOwner(bool on) =>
      adminCall('PUT', 'pairing/peers/$peerId/owner', <String, Object?>{
        'owner': on,
      });

  Future<({int status, Map<String, dynamic>? json})> send(
    String method,
    String path, {
    String token = peerToken,
    Object? body,
  }) async {
    final HttpClientRequest req = await client.openUrl(
      method,
      Uri.parse('https://127.0.0.1:${host.port}$path'),
    );
    req.headers.set(
      'Authorization',
      'Basic ${base64Encode(utf8.encode('fushi:$token'))}',
    );
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final HttpClientResponse res = await req.close();
    final String text = await utf8.decodeStream(res);
    Map<String, dynamic>? json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(text) as Map);
    } on FormatException {
      json = null;
    }
    return (status: res.statusCode, json: json);
  }

  Map<String, dynamic> linkBody() => LeaderboardDeviceLinkRequest.sign(
    newDevice,
    DateTime.now().millisecondsSinceEpoch,
  ).toJson();

  Future<({int status, Map<String, dynamic>? json})> link({
    String token = peerToken,
  }) => send(
    'POST',
    kInterconnectLeaderboardLinkPath,
    token: token,
    body: linkBody(),
  );

  test('TLS 下 capabilities 声明 leaderboardDeviceLinkV1', () async {
    final ({int status, Map<String, dynamic>? json}) caps = await send(
      'GET',
      '/api/capabilities',
      token: host.identity.hostToken,
    );
    expect(caps.status, 200);
    expect(caps.json![kInterconnectLeaderboardLinkCapability], isTrue);
  });

  test('「我的设备」跟随本机账户登录：host 用自己的钥匙代绑对端公钥', () async {
    await writeHostAccount();
    await pair();
    final ({int status, Map<String, dynamic> json}) marked = await markOwner(
      true,
    );
    expect(marked.status, 200);
    expect(marked.json['ownerDevice'], isTrue);

    final ({int status, Map<String, dynamic>? json}) r = await link();
    expect(r.status, 200, reason: '${r.json}');
    final InterconnectLeaderboardLinkResult result =
        InterconnectLeaderboardLinkResult.fromJson(r.json!);
    expect(result.account['id'], 'acct0000000000AA');
    expect(result.serverUrl, leaderboard.url);
    // 服务端收到的是对端自己的公钥 + 持有证明；私钥 / 恢复码不在任何载荷里。
    expect(leaderboard.linked, hasLength(1));
    expect(leaderboard.linked.single['pubkey'], newDevice.pubkeyBase64Url);
    expect(jsonEncode(r.json), isNot(contains('FUSHI1-')));

    // 已配对设备列表如实显示标记。
    final ({int status, Map<String, dynamic> json}) pairing = await adminCall(
      'GET',
      'pairing',
    );
    final Map<String, dynamic> peer = Map<String, dynamic>.from(
      (pairing.json['peers'] as List).single as Map,
    );
    expect(peer['ownerDevice'], isTrue);
    expect(peer['deviceKeyVerified'], isTrue);
    expect((pairing.json['leaderboardLink'] as Map)['reachable'], isTrue);
  });

  test('无头配对从不授予「我的设备」：没标记的已配对设备 403 not_owner_device', () async {
    await writeHostAccount();
    await pair();
    final ({int status, Map<String, dynamic>? json}) r = await link();
    expect(r.status, 403);
    expect(r.json!['error'], InterconnectLeaderboardLinkError.notOwnerDevice);
    expect(leaderboard.linked, isEmpty);
  });

  test('共享 host token 不算已配对设备：403 paired_peer_required', () async {
    await writeHostAccount();
    final ({int status, Map<String, dynamic>? json}) r = await link(
      token: host.identity.hostToken,
    );
    expect(r.status, 403);
    expect(r.json!['error'], 'paired_peer_required');
  });

  test('没证明设备钥匙的 peer 标不上「我的设备」；不存在的 peer 404', () async {
    await pair(fingerprint: null);
    final ({int status, Map<String, dynamic> json}) r = await markOwner(true);
    expect(r.status, 409);
    expect(r.json['reason'], 'device_key_unverified');
    expect(
      await InterconnectOwnerDeviceStore(db).ownerDevicePeerIds(),
      isEmpty,
    );
    final ({int status, Map<String, dynamic> json}) ghost = await adminCall(
      'PUT',
      'pairing/peers/ghost/owner',
      <String, Object?>{'owner': true},
    );
    expect(ghost.status, 404);
  });

  test('总闸 leaderboard_link 现读：WebUI 关掉即 403 disabled', () async {
    await writeHostAccount();
    await pair();
    await markOwner(true);
    final ({int status, Map<String, dynamic> json}) s = await adminCall(
      'PUT',
      'settings',
      <String, Object?>{'leaderboardLink': false},
    );
    expect(s.json['leaderboardLink'], isFalse);
    final ({int status, Map<String, dynamic>? json}) r = await link();
    expect(r.status, 403);
    expect(r.json!['error'], InterconnectLeaderboardLinkError.disabled);
    expect(leaderboard.linked, isEmpty);
  });

  test('本机没有排行榜账户：409 no_account', () async {
    await pair();
    await markOwner(true);
    final ({int status, Map<String, dynamic>? json}) r = await link();
    expect(r.status, 409);
    expect(r.json!['error'], InterconnectLeaderboardLinkError.noAccount);
  });

  test('排行榜服务的拒绝：4xx 透传错误码，404 = 旧版服务端', () async {
    await writeHostAccount();
    await pair();
    await markOwner(true);
    leaderboard.forceError = (409, 'too_many_devices');
    final ({int status, Map<String, dynamic>? json}) full = await link();
    expect(full.status, 409);
    expect(full.json!['error'], 'too_many_devices');

    leaderboard.forceError = (404, 'not_found');
    final ({int status, Map<String, dynamic>? json}) old = await link();
    expect(old.status, 502);
    expect(
      old.json!['error'],
      InterconnectLeaderboardLinkError.serverUnsupported,
    );
  });

  test('重新配对清掉旧标记；吊销清掉标记与指纹', () async {
    await writeHostAccount();
    await pair();
    await markOwner(true);
    // 同一台设备再配一次（这次会话没授予「我的设备」）：不沿用旧标记。
    await pair();
    expect((await link()).json!['error'], 'not_owner_device');

    await markOwner(true);
    final ({int status, Map<String, dynamic> json}) revoked = await adminCall(
      'DELETE',
      'pairing/peers/$peerId',
    );
    expect(revoked.json['ok'], isTrue);
    final InterconnectOwnerDeviceStore store = InterconnectOwnerDeviceStore(db);
    expect(await store.ownerDevicePeerIds(), isEmpty);
    expect(await store.deviceKeyFingerprints(), isEmpty);
  });

  test('配置往返：leaderboard_link 写回 yaml，缺省为 true', () async {
    final ServerConfig defaults = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'd2'),
    );
    expect(defaults.leaderboardLink, isTrue);
    final File f = File(p.join(tmp.path, 'roundtrip.yaml'));
    await defaults.copyWith(leaderboardLink: false).save(f);
    expect(await f.readAsString(), contains('leaderboard_link: false'));
    expect((await ServerConfig.load(f)).leaderboardLink, isFalse);
  });
}
