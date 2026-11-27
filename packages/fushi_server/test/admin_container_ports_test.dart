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
import 'support/fake_rwkv.dart';

/// 容器里监听端口（port / adminPort）是容器内端口，对外端口由 compose 端口映射决定：
/// 设置接口把 `inContainer` 告诉页面（页面只读），PUT 改端口值一律 409。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late File configFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_zh_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<({AdminApi api, AdminContext ctx, HeadlessHost host})> build(
    Map<String, String> environment,
  ) async {
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok');
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    final HeadlessHost host = HeadlessHost(
      srsRwkvHttpClient: noNetworkHttpClient,
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
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
      environment: environment,
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

  const Map<String, String> container = <String, String>{
    'FUSHI_CONTAINER': '1',
  };

  test('GET settings：容器里 inContainer 为真，否则为假', () async {
    final (:AdminApi api, ctx: _, host: _) = await build(container);
    expect((await call(api, 'GET', 'settings')).json['inContainer'], isTrue);
    final (api: AdminApi plain, ctx: _, host: _) = await build(
      const <String, String>{},
    );
    expect((await call(plain, 'GET', 'settings')).json['inContainer'], isFalse);
  });

  test('容器里 PUT 改 port / adminPort -> 409，不落盘', () async {
    final (:AdminApi api, :AdminContext ctx, host: _) = await build(container);
    final int port = ctx.config.port;
    final int adminPort = ctx.config.adminPort;
    for (final String key in <String>['port', 'adminPort']) {
      final (:int status, :Map<String, dynamic> json) = await call(
        api,
        'PUT',
        'settings',
        <String, Object?>{key: 51234},
      );
      expect(status, 409, reason: '$json');
      expect(json['reason'], 'container_port_locked');
    }
    final ServerConfig saved = await ServerConfig.load(configFile);
    expect(saved.port, port);
    expect(saved.adminPort, adminPort);
  });

  test('容器里整表单原值回传放行，别的项照常保存', () async {
    final (:AdminApi api, :AdminContext ctx, host: _) = await build(container);
    final (
      :int status,
      :Map<String, dynamic> json,
    ) = await call(api, 'PUT', 'settings', <String, Object?>{
      'port': ctx.config.port,
      'adminPort': ctx.config.adminPort,
      'deviceName': 'nas',
    });
    expect(status, 200, reason: '$json');
    expect((await ServerConfig.load(configFile)).deviceName, 'nas');
  });

  test('非容器里仍可改端口', () async {
    final (:AdminApi api, ctx: _, host: _) = await build(
      const <String, String>{},
    );
    final (:int status, json: _) = await call(
      api,
      'PUT',
      'settings',
      <String, Object?>{'port': 51234},
    );
    expect(status, 200);
    expect((await ServerConfig.load(configFile)).port, 51234);
  });
}
