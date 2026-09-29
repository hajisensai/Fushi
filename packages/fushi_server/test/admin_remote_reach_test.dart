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

/// admin API 的「远程可达」三项（公网地址 / P2P 开关 / 自建中继）：
/// 读写往返、非法 URL 400 且不落半截、写回 yaml、原生库不可用时的 409，
/// 以及改完推进 host（公网地址 provider 读的是 host 的实时配置）。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late File configFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_rr_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<({AdminApi api, AdminContext ctx, HeadlessHost host})> build({
    required bool p2pAvailable,
    ServerConfig Function(ServerConfig)? tweak,
  }) async {
    ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok');
    if (tweak != null) config = tweak(config);
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    final HeadlessHost host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => p2pAvailable,
    );
    final AdminContext ctx = AdminContext(
      config: config,
      configFile: configFile,
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
      db: db,
      identity: identity,
      host: host,
      startedAt: DateTime.now(),
    );
    return (api: AdminApi(ctx), ctx: ctx, host: host);
  }

  Future<({int status, Map<String, dynamic> json})> call(
    AdminApi api,
    String method,
    String path, [
    Object? body,
  ]) async {
    final shelf.Response r = await api.handle(
      shelf.Request(
        method,
        Uri.parse('http://localhost/api/admin/$path'),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final Object? decoded = jsonDecode(await r.readAsString());
    return (
      status: r.statusCode,
      json: Map<String, dynamic>.from(decoded! as Map),
    );
  }

  test('GET settings 默认值：三项为空 / 关，P2P 状态如实报不可用', () async {
    final (:AdminApi api, ctx: _, host: _) = await build(p2pAvailable: false);
    final (:int status, :Map<String, dynamic> json) = await call(
      api,
      'GET',
      'settings',
    );
    expect(status, 200);
    expect(json['publicUrls'], isEmpty);
    expect(json['p2p'], isFalse);
    expect(json['p2pRelays'], isEmpty);
    final Map<String, dynamic> st = Map<String, dynamic>.from(
      json['p2pStatus'] as Map,
    );
    expect(st['available'], isFalse);
    expect(st['active'], isFalse);
    expect(st['reason'], 'unavailable');
    expect(
      (json['restartRequiredKeys'] as List).contains('p2p'),
      isFalse,
      reason: '三项保存即生效，不该出现在「需重启」清单里',
    );
  });

  test('PUT 公网地址与中继：去空白 / 空行 / 重复后写回 yaml，并推进 host 的实时配置', () async {
    final (:AdminApi api, :AdminContext ctx, :HeadlessHost host) = await build(
      p2pAvailable: false,
    );
    final (:int status, :Map<String, dynamic> json) = await call(
      api,
      'PUT',
      'settings',
      <String, Object?>{
        'publicUrls': <String>[
          ' https://nas.example.com:38765 ',
          '',
          'http://1.2.3.4:38765',
          'https://nas.example.com:38765',
        ],
        'p2pRelays': <String>['https://relay.example.com'],
      },
    );
    expect(status, 200, reason: '$json');
    expect(json['publicUrls'], <String>[
      'https://nas.example.com:38765',
      'http://1.2.3.4:38765',
    ]);
    expect(json['p2pRelays'], <String>['https://relay.example.com']);

    final ServerConfig onDisk = await ServerConfig.load(configFile);
    expect(onDisk.publicUrls, <String>[
      'https://nas.example.com:38765',
      'http://1.2.3.4:38765',
    ]);
    expect(onDisk.p2pRelays, <String>['https://relay.example.com']);
    expect(onDisk.adminToken, 'tok', reason: '只改三项，别的配置原样保留');
    expect(ctx.config.publicUrls, onDisk.publicUrls);
    expect(
      host.config.publicUrls,
      onDisk.publicUrls,
      reason: 'publicUrlsProvider 读 host.config；没推进去就要重启才生效',
    );

    // 缺省 = 不改；显式空数组 = 清空。
    await call(api, 'PUT', 'settings', <String, Object?>{'deviceName': 'nas'});
    expect((await ServerConfig.load(configFile)).publicUrls, hasLength(2));
    await call(api, 'PUT', 'settings', <String, Object?>{
      'publicUrls': <String>[],
    });
    expect((await ServerConfig.load(configFile)).publicUrls, isEmpty);
  });

  test('非法 URL 一律 400，且整个请求不落盘（不留半截）', () async {
    final (:AdminApi api, :AdminContext ctx, host: _) = await build(
      p2pAvailable: false,
    );
    final String before = await configFile.readAsString();
    final List<Map<String, Object?>> bad = <Map<String, Object?>>[
      <String, Object?>{
        'publicUrls': <String>['ftp://nas.example.com'],
      },
      <String, Object?>{
        'publicUrls': <String>['nas.example.com:38765'],
      },
      <String, Object?>{
        'publicUrls': <String>['https://'],
      },
      <String, Object?>{'publicUrls': 'https://nas.example.com'},
      <String, Object?>{
        'publicUrls': <Object?>[42],
      },
      <String, Object?>{
        'p2pRelays': <String>['relay.example.com'],
      },
      <String, Object?>{
        'p2pRelays': <String>['quic://relay.example.com'],
      },
      <String, Object?>{'p2p': 'yes'},
      // 合法项 + 非法项混在一起：合法的也不能先写进去。
      <String, Object?>{
        'deviceName': 'renamed',
        'publicUrls': <String>['https://ok.example.com'],
        'p2pRelays': <String>['not a url'],
      },
    ];
    for (final Map<String, Object?> body in bad) {
      final (:int status, :Map<String, dynamic> json) = await call(
        api,
        'PUT',
        'settings',
        body,
      );
      expect(status, 400, reason: '$body → $json');
      expect(json['error'], isA<String>());
    }
    expect(await configFile.readAsString(), before);
    expect(ctx.config.deviceName, isNot('renamed'));
    expect(ctx.config.publicUrls, isEmpty);
  });

  test('原生库不可用时开 P2P → 409 p2p_unavailable，不落盘', () async {
    final (:AdminApi api, :AdminContext ctx, host: _) = await build(
      p2pAvailable: false,
    );
    final String before = await configFile.readAsString();
    final (:int status, :Map<String, dynamic> json) = await call(
      api,
      'PUT',
      'settings',
      <String, Object?>{'p2p': true},
    );
    expect(status, 409);
    expect(json['reason'], 'p2p_unavailable');
    expect(json['error'], contains('libfushi_p2p'));
    expect(ctx.config.p2p, isFalse);
    expect(await configFile.readAsString(), before);

    final ({int status, Map<String, dynamic> json}) st = await call(
      api,
      'GET',
      'p2p',
    );
    expect(st.status, 200);
    expect(st.json['available'], isFalse);
    expect(st.json['reason'], 'unavailable');
  });

  test('yaml 里本就 p2p: true 而库不可用：照常能保存别的项、也能关掉（只拦从关到开）', () async {
    final (:AdminApi api, :AdminContext ctx, host: _) = await build(
      p2pAvailable: false,
      tweak: (ServerConfig c) => c.copyWith(p2p: true),
    );
    final ({int status, Map<String, dynamic> json}) keep = await call(
      api,
      'PUT',
      'settings',
      <String, Object?>{
        'p2p': true,
        'publicUrls': <String>['https://nas.example.com'],
      },
    );
    expect(keep.status, 200, reason: '${keep.json}');
    final ({int status, Map<String, dynamic> json}) off = await call(
      api,
      'PUT',
      'settings',
      <String, Object?>{'p2p': false},
    );
    expect(off.status, 200);
    expect(ctx.config.p2p, isFalse);
    expect((await ServerConfig.load(configFile)).p2p, isFalse);
  });

  test('库可用、host 未运行：开关照常写回，状态报 host_stopped；关回去报 disabled', () async {
    final (:AdminApi api, :AdminContext ctx, :HeadlessHost host) = await build(
      p2pAvailable: true,
    );
    final ({int status, Map<String, dynamic> json}) on = await call(
      api,
      'PUT',
      'settings',
      <String, Object?>{'p2p': true},
    );
    expect(on.status, 200, reason: '${on.json}');
    expect(on.json['p2p'], isTrue);
    expect((await ServerConfig.load(configFile)).p2p, isTrue);
    expect(host.config.p2p, isTrue);
    final Map<String, dynamic> st = Map<String, dynamic>.from(
      on.json['p2pStatus'] as Map,
    );
    expect(st['available'], isTrue);
    expect(st['enabled'], isTrue);
    expect(st['active'], isFalse);
    expect(st['reason'], 'host_stopped');

    await call(api, 'PUT', 'settings', <String, Object?>{'p2p': false});
    expect(ctx.config.p2p, isFalse);
    expect((await call(api, 'GET', 'p2p')).json['reason'], 'disabled');
  });

  test('remoteUrlProblem：scheme 与主机名是最低要求', () {
    expect(ServerConfig.remoteUrlProblem('https://relay.example.com'), isNull);
    expect(ServerConfig.remoteUrlProblem('http://[2001:db8::1]:38765'), isNull);
    expect(
      ServerConfig.remoteUrlProblem('https://nas.example.com/fushi'),
      isNull,
    );
    expect(ServerConfig.remoteUrlProblem('ws://relay.example.com'), isNotNull);
    expect(ServerConfig.remoteUrlProblem('relay.example.com'), isNotNull);
    expect(ServerConfig.remoteUrlProblem('https:///path'), isNotNull);
    expect(ServerConfig.remoteUrlProblem('not a url'), isNotNull);
  });
}
